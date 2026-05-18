/**
 * @fileoverview Usage rollup computation.
 *
 * Maintains compact daily usage counters, computes per-window aggregates, and
 * writes `usage_rollups/{windowKey}` documents. The scheduled path reads only
 * counter documents; raw usage scans are reserved for explicit repair/backfill.
 */

import { createHash } from "node:crypto";
import {
  FieldValue,
  type Firestore,
} from "firebase-admin/firestore";
import type {
  UsageEventDoc,
  UsageRollupDoc,
  ProviderSummary,
  ProviderAccountSummary,
  ModelSummary,
  DeviceSummary,
  RollupJobDoc,
} from "./types.js";

const ROLLUP_SCHEMA_VERSION = 3;
const COUNTER_SCHEMA_VERSION = 1;

/** Window keys in ascending granularity order. */
const WINDOW_KEYS = ["today", "7d", "30d", "90d", "all_time"] as const;
export type WindowKey = (typeof WINDOW_KEYS)[number];

type TimestampLike = {
  toDate?: () => Date;
  toMillis?: () => number;
  seconds?: number;
  nanoseconds?: number;
  _seconds?: number;
  _nanoseconds?: number;
};

type RollupEvent = {
  event: UsageEventDoc;
  date: Date;
  tokens: number;
  cost?: number;
  model?: string;
};

type UsageCounterContribution = {
  logicalKey: string;
  day: string;
  provider: string;
  providerID: string;
  accountKey: string;
  accountID?: string;
  accountLabel: string;
  storageScope?: string;
  model?: string;
  deviceId?: string;
  requests: number;
  tokens: number;
  costUsd: number;
};

type UsageCounterCandidate = UsageCounterContribution & {
  candidateKey: string;
  provenanceRank: number;
  updatedMillis: number;
  modelRank: number;
};

type CounterWriter = {
  set(
    ref: FirebaseFirestore.DocumentReference,
    data: FirebaseFirestore.DocumentData,
    options: FirebaseFirestore.SetOptions
  ): unknown;
};

function coerceDate(value: unknown): Date | undefined {
  if (value == null) return undefined;
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? undefined : value;
  }
  if (typeof value === "string" || typeof value === "number") {
    const d = new Date(value);
    return Number.isNaN(d.getTime()) ? undefined : d;
  }

  if (typeof value === "object") {
    const ts = value as TimestampLike;
    if (typeof ts.toDate === "function") {
      const d = ts.toDate();
      return Number.isNaN(d.getTime()) ? undefined : d;
    }
    if (typeof ts.toMillis === "function") {
      const d = new Date(ts.toMillis());
      return Number.isNaN(d.getTime()) ? undefined : d;
    }
    const seconds = ts.seconds ?? ts._seconds;
    const nanos = ts.nanoseconds ?? ts._nanoseconds ?? 0;
    if (typeof seconds === "number") {
      const d = new Date(seconds * 1000 + Math.floor(nanos / 1_000_000));
      return Number.isNaN(d.getTime()) ? undefined : d;
    }
  }

  return undefined;
}

function eventDate(ev: UsageEventDoc): Date | undefined {
  return (
    coerceDate(ev.timestamp) ??
    coerceDate(ev.startTime) ??
    coerceDate(ev.endTime) ??
    coerceDate(ev.createdAt) ??
    coerceDate(ev.updatedAt)
  );
}

function toUtcDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function finiteNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function eventTokens(ev: UsageEventDoc): number {
  if (typeof ev.totalTokens === "number" && Number.isFinite(ev.totalTokens)) {
    return ev.totalTokens;
  }
  return (
    finiteNumber(ev.inputTokens) +
    finiteNumber(ev.outputTokens) +
    finiteNumber(ev.cacheCreationTokens) +
    finiteNumber(ev.cacheReadTokens) +
    finiteNumber(ev.reasoningTokens)
  );
}

function eventCost(ev: UsageEventDoc): number | undefined {
  const v = ev.costUsd ?? ev.cost;
  if (typeof v === "number" && Number.isFinite(v)) return v;
  return undefined;
}

function isLegacyKimiWireEvent(ev: UsageEventDoc): boolean {
  const provider = String(ev.providerID ?? ev.provider ?? "").toLowerCase();
  const model = String(ev.model ?? "");
  return provider === "kimi" && model.startsWith("chatcmpl-");
}

function kimiCost(
  inputTokens: number,
  outputTokens: number,
  cacheCreationTokens: number,
  cacheReadTokens: number
): number {
  return (
    (inputTokens / 1_000_000) * 0.6 +
    (outputTokens / 1_000_000) * 2.5 +
    (cacheCreationTokens / 1_000_000) * 0.6 +
    (cacheReadTokens / 1_000_000) * 0.15
  );
}

function eventModel(ev: UsageEventDoc): string | undefined {
  return isLegacyKimiWireEvent(ev) ? "kimi-for-coding" : ev.model;
}

function eventMetrics(ev: UsageEventDoc): { tokens: number; cost?: number } {
  if (!isLegacyKimiWireEvent(ev)) {
    return { tokens: eventTokens(ev), cost: eventCost(ev) };
  }

  const rawInput = finiteNumber(ev.inputTokens);
  const output = finiteNumber(ev.outputTokens);
  const cacheCreation = finiteNumber(ev.cacheCreationTokens);
  const cacheRead = finiteNumber(ev.cacheReadTokens);
  const input = Math.max(rawInput - cacheCreation - cacheRead, 0);

  return {
    tokens: input + output + cacheCreation + cacheRead,
    cost: kimiCost(input, output, cacheCreation, cacheRead),
  };
}

function provenanceRank(ev: UsageEventDoc): number {
  switch (ev.provenanceConfidence) {
    case "exact":
      return 4;
    case "derived_exact":
      return 3;
    case "high_confidence_estimate":
      return 2;
    case "low_confidence_estimate":
      return 1;
    default:
      return 0;
  }
}

function modelRank(model: string | undefined): number {
  if (!model) return 0;
  const normalized = model.toLowerCase();
  if (normalized === "unknown" || normalized.startsWith("chatcmpl-")) return 0;
  return 1;
}

function eventUpdatedMillis(ev: UsageEventDoc): number {
  return (
    coerceDate(ev.updatedAt)?.getTime() ??
    coerceDate(ev.createdAt)?.getTime() ??
    coerceDate(ev.endTime)?.getTime() ??
    coerceDate(ev.startTime)?.getTime() ??
    0
  );
}

function tokenBucketKey(ev: UsageEventDoc, metrics: { tokens: number; cost?: number }): string {
  const provider = eventProviderID(ev).toLowerCase();
  if (provider === "codex") {
    return String(metrics.tokens);
  }

  return [
    finiteNumber(ev.inputTokens),
    finiteNumber(ev.outputTokens),
    finiteNumber(ev.cacheCreationTokens),
    finiteNumber(ev.cacheReadTokens),
    finiteNumber(ev.reasoningTokens),
    metrics.tokens,
  ].join(":");
}

function logicalUsageKey(ev: UsageEventDoc, date: Date, metrics: { tokens: number; cost?: number }): string {
  const provider = eventProviderID(ev);
  const sessionId = ev.sessionId ?? "";
  const deviceId = ev.deviceId ?? ev.sourceDeviceId ?? "";
  const accountId = ev.providerAccountID ?? "";
  const startedAt = date.toISOString();

  return [
    provider,
    sessionId,
    deviceId,
    accountId,
    startedAt,
    tokenBucketKey(ev, metrics),
  ].join("|");
}

function preferRollupEvent(candidate: RollupEvent, existing: RollupEvent): boolean {
  const candidateProvenance = provenanceRank(candidate.event);
  const existingProvenance = provenanceRank(existing.event);
  if (candidateProvenance !== existingProvenance) {
    return candidateProvenance > existingProvenance;
  }

  const candidateUpdatedAt = eventUpdatedMillis(candidate.event);
  const existingUpdatedAt = eventUpdatedMillis(existing.event);
  if (candidateUpdatedAt !== existingUpdatedAt) {
    return candidateUpdatedAt > existingUpdatedAt;
  }

  const candidateModel = modelRank(candidate.model);
  const existingModel = modelRank(existing.model);
  if (candidateModel !== existingModel) {
    return candidateModel > existingModel;
  }

  const candidateCost = candidate.cost ?? 0;
  const existingCost = existing.cost ?? 0;
  if (candidateCost !== existingCost) {
    return candidateCost < existingCost;
  }

  return true;
}

function dedupeUsageEvents(events: RollupEvent[]): RollupEvent[] {
  const deduped = new Map<string, RollupEvent>();

  for (const entry of events) {
    const key = logicalUsageKey(entry.event, entry.date, {
      tokens: entry.tokens,
      cost: entry.cost,
    });
    const existing = deduped.get(key);
    if (!existing || preferRollupEvent(entry, existing)) {
      deduped.set(key, entry);
    }
  }

  return Array.from(deduped.values());
}

function stripUndefined<T>(value: T): T {
  if (Array.isArray(value)) {
    return value.map((item) => stripUndefined(item)) as T;
  }
  if (value && typeof value === "object") {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      return value;
    }
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .filter(([, entryValue]) => entryValue !== undefined)
        .map(([key, entryValue]) => [key, stripUndefined(entryValue)])
    ) as T;
  }
  return value;
}

function safeCounterSegment(value: string): string {
  const normalized = value.trim().toLowerCase().replace(/[^a-z0-9_.-]+/g, "_");
  return (normalized || "unknown").slice(0, 140);
}

function stableCounterKey(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function counterDocID(value: string): string {
  const prefix = safeCounterSegment(value).slice(0, 80);
  const digest = stableCounterKey(value).slice(0, 16);
  return `${prefix}_${digest}`;
}

function eventProviderID(ev: UsageEventDoc): string {
  return ev.providerID ?? ev.provider;
}

function accountSummaryKey(ev: UsageEventDoc): string {
  return ev.providerAccountID ?? `${eventProviderID(ev)}:unattributed`;
}

function windowPredicate(key: WindowKey, now: Date): (date: Date) => boolean {
  const nowTs = now.getTime();
  switch (key) {
    case "today": {
      const today = toUtcDate(now);
      return (date: Date) => toUtcDate(date) === today;
    }
    case "7d": {
      const cutoff7 = nowTs - 7 * 24 * 60 * 60 * 1000;
      return (date: Date) => date.getTime() >= cutoff7;
    }
    case "30d": {
      const cutoff30 = nowTs - 30 * 24 * 60 * 60 * 1000;
      return (date: Date) => date.getTime() >= cutoff30;
    }
    case "90d": {
      const cutoff90 = nowTs - 90 * 24 * 60 * 60 * 1000;
      return (date: Date) => date.getTime() >= cutoff90;
    }
    case "all_time":
      return () => true;
  }
}

function usageContribution(
  ev: UsageEventDoc | undefined,
  candidateKey = ""
): UsageCounterCandidate | undefined {
  if (!ev) return undefined;
  const date = eventDate(ev);
  if (!date) return undefined;
  const metrics = eventMetrics(ev);
  const providerID = eventProviderID(ev);
  const accountKey = accountSummaryKey(ev);
  const model = eventModel(ev);
  return {
    logicalKey: logicalUsageKey(ev, date, metrics),
    candidateKey,
    day: toUtcDate(date),
    provider: ev.provider,
    providerID,
    accountKey,
    accountID: ev.providerAccountID,
    accountLabel: ev.providerAccountLabel ?? "Usage not linked to an account yet",
    storageScope: ev.providerAccountSource,
    model,
    deviceId: ev.deviceId ?? ev.sourceDeviceId,
    requests: 1,
    tokens: metrics.tokens,
    costUsd: metrics.cost ?? 0,
    provenanceRank: provenanceRank(ev),
    updatedMillis: eventUpdatedMillis(ev),
    modelRank: modelRank(model),
  };
}

function addContributionToBucket(
  writer: CounterWriter,
  bucketRef: FirebaseFirestore.DocumentReference,
  contribution: UsageCounterContribution,
  direction: 1 | -1,
  now: string,
  bucketFields: Record<string, string>
): void {
  const deltaRequests = direction * contribution.requests;
  const deltaTokens = direction * contribution.tokens;
  const deltaCost = direction * contribution.costUsd;

  writer.set(
    bucketRef,
    stripUndefined({
      ...bucketFields,
      requests: FieldValue.increment(deltaRequests),
      tokens: FieldValue.increment(deltaTokens),
      costUsd: FieldValue.increment(deltaCost),
      updatedAt: now,
      schemaVersion: COUNTER_SCHEMA_VERSION,
    }),
    { merge: true }
  );

  const providerRef = bucketRef.collection("providers").doc(counterDocID(contribution.provider));
  writer.set(
    providerRef,
    stripUndefined({
      provider: contribution.provider,
      providerID: contribution.providerID,
      requests: FieldValue.increment(deltaRequests),
      tokens: FieldValue.increment(deltaTokens),
      costUsd: FieldValue.increment(deltaCost),
      updatedAt: now,
      schemaVersion: COUNTER_SCHEMA_VERSION,
    }),
    { merge: true }
  );

  const accountRef = bucketRef.collection("accounts").doc(counterDocID(contribution.accountKey));
  writer.set(
    accountRef,
    stripUndefined({
      provider: contribution.provider,
      providerID: contribution.providerID,
      accountID: contribution.accountID,
      accountLabel: contribution.accountLabel,
      storageScope: contribution.storageScope,
      requests: FieldValue.increment(deltaRequests),
      tokens: FieldValue.increment(deltaTokens),
      costUsd: FieldValue.increment(deltaCost),
      updatedAt: now,
      schemaVersion: COUNTER_SCHEMA_VERSION,
    }),
    { merge: true }
  );

  if (contribution.model) {
    const modelRef = bucketRef
      .collection("models")
      .doc(counterDocID(`${contribution.provider}:${contribution.model}`));
    writer.set(
      modelRef,
      stripUndefined({
        provider: contribution.provider,
        model: contribution.model,
        requests: FieldValue.increment(deltaRequests),
        tokens: FieldValue.increment(deltaTokens),
        costUsd: FieldValue.increment(deltaCost),
        updatedAt: now,
        schemaVersion: COUNTER_SCHEMA_VERSION,
      }),
      { merge: true }
    );
  }

  if (contribution.deviceId) {
    const deviceRef = bucketRef.collection("devices").doc(counterDocID(contribution.deviceId));
    writer.set(
      deviceRef,
      stripUndefined({
        deviceId: contribution.deviceId,
        requests: FieldValue.increment(deltaRequests),
        tokens: FieldValue.increment(deltaTokens),
        updatedAt: now,
        schemaVersion: COUNTER_SCHEMA_VERSION,
      }),
      { merge: true }
    );
  }
}

function addContribution(
  writer: CounterWriter,
  db: Firestore,
  uid: string,
  contribution: UsageCounterContribution,
  direction: 1 | -1,
  now: string
): void {
  const dayRef = db.doc(`users/${uid}/usage_counter_days/${contribution.day}`);
  addContributionToBucket(writer, dayRef, contribution, direction, now, {
    day: contribution.day,
  });

  const allTimeRef = db.doc(`users/${uid}/usage_counter_totals/all_time`);
  addContributionToBucket(writer, allTimeRef, contribution, direction, now, {
    windowKey: "all_time",
  });
}

function betterCounterCandidate(
  candidate: UsageCounterCandidate,
  existing: UsageCounterCandidate
): boolean {
  if (candidate.provenanceRank !== existing.provenanceRank) {
    return candidate.provenanceRank > existing.provenanceRank;
  }
  if (candidate.updatedMillis !== existing.updatedMillis) {
    return candidate.updatedMillis > existing.updatedMillis;
  }
  if (candidate.modelRank !== existing.modelRank) {
    return candidate.modelRank > existing.modelRank;
  }
  if (candidate.costUsd !== existing.costUsd) {
    return candidate.costUsd < existing.costUsd;
  }
  return candidate.candidateKey >= existing.candidateKey;
}

function selectCounterWinner(
  candidates: Record<string, UsageCounterCandidate>
): UsageCounterCandidate | undefined {
  let winner: UsageCounterCandidate | undefined;
  for (const candidate of Object.values(candidates)) {
    if (!winner || betterCounterCandidate(candidate, winner)) {
      winner = candidate;
    }
  }
  return winner;
}

function sameCounterCandidate(
  a: UsageCounterCandidate | undefined,
  b: UsageCounterCandidate | undefined
): boolean {
  return a?.candidateKey === b?.candidateKey &&
    a?.logicalKey === b?.logicalKey &&
    a?.day === b?.day &&
    a?.provider === b?.provider &&
    a?.providerID === b?.providerID &&
    a?.accountKey === b?.accountKey &&
    a?.accountID === b?.accountID &&
    a?.accountLabel === b?.accountLabel &&
    a?.storageScope === b?.storageScope &&
    a?.model === b?.model &&
    a?.deviceId === b?.deviceId &&
    a?.requests === b?.requests &&
    a?.tokens === b?.tokens &&
    a?.costUsd === b?.costUsd &&
    a?.provenanceRank === b?.provenanceRank &&
    a?.updatedMillis === b?.updatedMillis &&
    a?.modelRank === b?.modelRank;
}

export async function applyUsageCounterDelta(
  db: Firestore,
  uid: string,
  usageDoc: string,
  before: UsageEventDoc | undefined,
  after: UsageEventDoc | undefined
): Promise<void> {
  const candidateKey = stableCounterKey(usageDoc);
  const oldContribution = usageContribution(before, candidateKey);
  const newContribution = usageContribution(after, candidateKey);
  const affectedKeys = new Set<string>();
  if (oldContribution) affectedKeys.add(oldContribution.logicalKey);
  if (newContribution) affectedKeys.add(newContribution.logicalKey);
  if (affectedKeys.size === 0) return;

  const now = new Date().toISOString();

  await db.runTransaction(async (transaction) => {
    const entries = await Promise.all(
      Array.from(affectedKeys).map(async (logicalKey) => {
        const keyRef = db.doc(`users/${uid}/usage_counter_keys/${stableCounterKey(logicalKey)}`);
        const snap = await transaction.get(keyRef);
        return { logicalKey, keyRef, snap };
      })
    );

    for (const { logicalKey, keyRef, snap } of entries) {
      const existing = snap.exists ? snap.data() ?? {} : {};
      const candidates = {
        ...((existing.candidates as Record<string, UsageCounterCandidate> | undefined) ?? {}),
      };
      const previousWinner = selectCounterWinner(candidates);

      if (oldContribution?.logicalKey === logicalKey) {
        delete candidates[candidateKey];
      }
      if (newContribution?.logicalKey === logicalKey) {
        candidates[candidateKey] = newContribution;
      }

      const nextWinner = selectCounterWinner(candidates);
      if (!sameCounterCandidate(previousWinner, nextWinner)) {
        if (previousWinner) {
          addContribution(transaction, db, uid, previousWinner, -1, now);
        }
        if (nextWinner) {
          addContribution(transaction, db, uid, nextWinner, 1, now);
        }
      }

      transaction.set(
        keyRef,
        stripUndefined({
          logicalKey,
          candidates,
          winner: nextWinner,
          updatedAt: now,
          schemaVersion: COUNTER_SCHEMA_VERSION,
        }),
        { merge: false }
      );
    }
  });
}

async function queryCounterDocs(
  db: Firestore,
  collection: string,
  bucketPaths: string[]
): Promise<FirebaseFirestore.DocumentData[]> {
  const snapshots = await Promise.all(
    bucketPaths.map((path) => db.collection(`${path}/${collection}`).get())
  );
  return snapshots.flatMap((snapshot) => snapshot.docs.map((doc) => doc.data()));
}

function sumNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function windowDays(key: WindowKey, now: Date): string[] | undefined {
  if (key === "all_time") return undefined;
  const count = key === "today" ? 1 : key === "7d" ? 7 : key === "30d" ? 30 : 90;
  const days: string[] = [];
  const cursor = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  for (let i = 0; i < count; i += 1) {
    days.push(toUtcDate(cursor));
    cursor.setUTCDate(cursor.getUTCDate() - 1);
  }
  return days;
}

export async function computeUserRollups(
  db: Firestore,
  uid: string
): Promise<Record<WindowKey, UsageRollupDoc>> {
  await rebuildUserRollupCounters(db, uid);
  return computeUserRollupsFromCounters(db, uid);
}

export async function computeUserRollupsFromCounters(
  db: Firestore,
  uid: string
): Promise<Record<WindowKey, UsageRollupDoc>> {
  const now = new Date();
  const results = {} as Record<WindowKey, UsageRollupDoc>;

  for (const key of WINDOW_KEYS) {
    const days = windowDays(key, now);
    const allTimePath = `users/${uid}/usage_counter_totals/all_time`;
    const bucketPaths: string[] = [];
    const bucketDocs = key === "all_time"
      ? await db.doc(allTimePath).get().then((snap) => {
          if (!snap.exists) return [];
          bucketPaths.push(allTimePath);
          return [snap.data() ?? {}];
        })
      : await Promise.all(days!.map((day) => db.doc(`users/${uid}/usage_counter_days/${day}`).get()))
          .then((snapshots) => snapshots
          .filter((snap): snap is FirebaseFirestore.DocumentSnapshot<FirebaseFirestore.DocumentData> => "exists" in snap && snap.exists)
          .map((snap) => {
            const data = snap.data() ?? {};
            const day = typeof data.day === "string" ? data.day : "";
            if (day) bucketPaths.push(`users/${uid}/usage_counter_days/${day}`);
            return data;
          }));

    const [providers, accounts, models, devices] = await Promise.all([
      queryCounterDocs(db, "providers", bucketPaths),
      queryCounterDocs(db, "accounts", bucketPaths),
      queryCounterDocs(db, "models", bucketPaths),
      queryCounterDocs(db, "devices", bucketPaths),
    ]);

    const totals = bucketDocs.reduce(
      (acc, doc) => {
        acc.requests += sumNumber(doc.requests);
        acc.tokens += sumNumber(doc.tokens);
        acc.costUsd += sumNumber(doc.costUsd);
        return acc;
      },
      { requests: 0, tokens: 0, costUsd: 0 }
    );

    const dailyPointDocs = key === "all_time"
      ? (await db.collection(`users/${uid}/usage_counter_days`).get()).docs.map((doc) => doc.data())
      : bucketDocs;
    const dailyPoints = Object.fromEntries(
      dailyPointDocs
        .map((doc) => [String(doc.day), sumNumber(doc.tokens)] as const)
        .filter(([day, tokens]) => day && tokens !== 0)
    );

    const providerMap = new Map<string, ProviderSummary>();
    for (const doc of providers) {
      const provider = typeof doc.provider === "string" ? doc.provider : "unknown";
      const existing = providerMap.get(provider);
      if (existing) {
        existing.totalRequests += sumNumber(doc.requests);
        existing.totalTokens += sumNumber(doc.tokens);
        existing.totalCost = (existing.totalCost ?? 0) + sumNumber(doc.costUsd);
      } else {
        providerMap.set(provider, {
          provider: provider as ProviderSummary["provider"],
          providerID: typeof doc.providerID === "string" ? doc.providerID : undefined,
          totalRequests: sumNumber(doc.requests),
          totalTokens: sumNumber(doc.tokens),
          totalCost: sumNumber(doc.costUsd),
        });
      }
    }

    const accountMap = new Map<string, ProviderAccountSummary>();
    for (const doc of accounts) {
      const providerID = typeof doc.providerID === "string" ? doc.providerID : "unknown";
      const id = typeof doc.accountID === "string" ? doc.accountID : `${providerID}:unattributed`;
      const existing = accountMap.get(id);
      if (existing) {
        existing.totalRequests += sumNumber(doc.requests);
        existing.totalTokens += sumNumber(doc.tokens);
        existing.totalCost = (existing.totalCost ?? 0) + sumNumber(doc.costUsd);
      } else {
        accountMap.set(id, {
          id,
          providerID: providerID as ProviderAccountSummary["providerID"],
          accountID: typeof doc.accountID === "string" ? doc.accountID : undefined,
          accountLabel:
            typeof doc.accountLabel === "string"
              ? doc.accountLabel
              : "Usage not linked to an account yet",
          storageScope: typeof doc.storageScope === "string" ? doc.storageScope as ProviderAccountSummary["storageScope"] : undefined,
          totalRequests: sumNumber(doc.requests),
          totalTokens: sumNumber(doc.tokens),
          totalCost: sumNumber(doc.costUsd),
        });
      }
    }

    const modelMap = new Map<string, ModelSummary>();
    for (const doc of models) {
      const provider = typeof doc.provider === "string" ? doc.provider : "unknown";
      const model = typeof doc.model === "string" ? doc.model : "";
      if (!model) continue;
      const id = `${provider}:${model}`;
      const existing = modelMap.get(id);
      if (existing) {
        existing.requests += sumNumber(doc.requests);
        existing.tokens += sumNumber(doc.tokens);
        existing.cost = (existing.cost ?? 0) + sumNumber(doc.costUsd);
      } else {
        modelMap.set(id, {
          provider: provider as ModelSummary["provider"],
          model,
          requests: sumNumber(doc.requests),
          tokens: sumNumber(doc.tokens),
          cost: sumNumber(doc.costUsd),
        });
      }
    }

    const deviceMap = new Map<string, DeviceSummary>();
    for (const doc of devices) {
      const deviceId = typeof doc.deviceId === "string" ? doc.deviceId : "";
      if (!deviceId) continue;
      const existing = deviceMap.get(deviceId);
      if (existing) {
        existing.requests += sumNumber(doc.requests);
        existing.tokens += sumNumber(doc.tokens);
      } else {
        deviceMap.set(deviceId, {
          deviceId,
          requests: sumNumber(doc.requests),
          tokens: sumNumber(doc.tokens),
        });
      }
    }

    results[key] = {
      today: key === "today" ? totals.tokens : 0,
      "7d": key === "7d" ? totals.tokens : 0,
      "30d": key === "30d" ? totals.tokens : 0,
      "90d": key === "90d" ? totals.tokens : 0,
      all_time: key === "all_time" ? totals.tokens : 0,
      totals: {
        requests: totals.requests,
        tokens: totals.tokens,
        costUsd: Math.round(totals.costUsd * 1e6) / 1e6,
      },
      providerSummaries: Array.from(providerMap.values()).filter((entry) =>
        entry.totalRequests !== 0 || entry.totalTokens !== 0 || (entry.totalCost ?? 0) !== 0
      ),
      accountSummaries: Array.from(accountMap.values()).filter((entry) =>
        entry.totalRequests !== 0 || entry.totalTokens !== 0 || (entry.totalCost ?? 0) !== 0
      ),
      modelSummaries: Array.from(modelMap.values()).filter((entry) =>
        entry.requests !== 0 || entry.tokens !== 0 || (entry.cost ?? 0) !== 0
      ),
      deviceSummaries: Array.from(deviceMap.values()).filter((entry) =>
        entry.requests !== 0 || entry.tokens !== 0
      ),
      dailyPoints,
      computedAt: now.toISOString(),
      schemaVersion: ROLLUP_SCHEMA_VERSION,
    };
  }

  return results;
}

export async function rebuildUserRollupCounters(
  db: Firestore,
  uid: string
): Promise<void> {
  await Promise.all([
    db.recursiveDelete(db.collection(`users/${uid}/usage_counter_days`)),
    db.recursiveDelete(db.collection(`users/${uid}/usage_counter_totals`)),
    db.recursiveDelete(db.collection(`users/${uid}/usage_counter_keys`)),
  ]);

  const usageRef = db.collection(`users/${uid}/usage`);
  const snapshot = await usageRef.get();
  const candidatesByLogicalKey = new Map<string, Record<string, UsageCounterCandidate>>();

  for (const doc of snapshot.docs) {
    const event = doc.data() as UsageEventDoc;
    const contribution = usageContribution(event, stableCounterKey(doc.id));
    if (!contribution) continue;
    const candidates = candidatesByLogicalKey.get(contribution.logicalKey) ?? {};
    candidates[contribution.candidateKey] = contribution;
    candidatesByLogicalKey.set(contribution.logicalKey, candidates);
  }

  const winners = [...candidatesByLogicalKey.entries()]
    .map(([logicalKey, candidates]) => ({
      logicalKey,
      candidates,
      winner: selectCounterWinner(candidates),
    }))
    .filter((entry): entry is {
      logicalKey: string;
      candidates: Record<string, UsageCounterCandidate>;
      winner: UsageCounterCandidate;
    } => entry.winner != null);

  const repairBatchSize = 50;
  for (let i = 0; i < winners.length; i += repairBatchSize) {
    const batch = db.batch();
    const now = new Date().toISOString();
    for (const entry of winners.slice(i, i + repairBatchSize)) {
      addContribution(batch, db, uid, entry.winner, 1, now);
      const keyRef = db.doc(`users/${uid}/usage_counter_keys/${stableCounterKey(entry.logicalKey)}`);
      batch.set(
        keyRef,
        stripUndefined({
          logicalKey: entry.logicalKey,
          candidates: entry.candidates,
          winner: entry.winner,
          updatedAt: now,
          schemaVersion: COUNTER_SCHEMA_VERSION,
        }),
        { merge: false }
      );
    }
    await batch.commit();
  }
}

export async function writeUserRollups(
  db: Firestore,
  uid: string,
  rollups: Record<WindowKey, UsageRollupDoc>
): Promise<void> {
  const batch = db.batch();

  for (const key of WINDOW_KEYS) {
    const ref = db.doc(`users/${uid}/usage_rollups/${key}`);
    batch.set(ref, stripUndefined(rollups[key]), { merge: true });
  }

  const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
  batch.set(
    jobRef,
    {
      dirty: false,
      lastComputedAt: new Date().toISOString(),
      lastErrorCode: FieldValue.delete(),
    },
    { merge: true }
  );

  await batch.commit();
}
