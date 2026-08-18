/**
 * @fileoverview Usage counter primitives.
 *
 * Foundation for the rollup pipeline: per-event contribution shaping, the
 * candidates/winner state machine that gives exactly-once accounting, the
 * bucket-doc writers, and the single-event reference transition
 * (`applyUsageCounterDelta`). The pending-delta queue, the counters->rollup
 * compute, and the job/gate layer all build on these.
 */

import { createHash } from "node:crypto";
import { FieldValue, type DocumentData, type Firestore } from "firebase-admin/firestore";
import type { UsageEventDoc, UsageRollupDoc } from "./types.js";
import { coerceFirestoreDate, isRecord, recordOrUndefined, stripUndefinedObject } from "./guards.js";
import { flushDomainCorePricingShadowEvidence, priceLegacyKimiEvent } from "./pricing.js";

export const ROLLUP_SCHEMA_VERSION = 3;
export const COUNTER_SCHEMA_VERSION = 3;

/** Window keys in ascending granularity order. */
export const WINDOW_KEYS = ["today", "7d", "30d", "90d", "all_time"] as const;
export type WindowKey = (typeof WINDOW_KEYS)[number];

export type UsageCounterContribution = {
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
  executionSourceId?: string;
  executionSourceName?: string;
  requests: number;
  tokens: number;
  costUsd: number;
};

export type UsageCounterCandidate = UsageCounterContribution & {
  candidateKey: string;
  provenanceRank: number;
  updatedMillis: number;
  modelRank: number;
};

export function isUsageCounterCandidate(value: unknown): value is UsageCounterCandidate {
  if (!isRecord(value)) return false;
  return (
    typeof value.logicalKey === "string" &&
    typeof value.day === "string" &&
    typeof value.provider === "string" &&
    typeof value.providerID === "string" &&
    typeof value.accountKey === "string" &&
    typeof value.requests === "number" &&
    typeof value.tokens === "number" &&
    typeof value.costUsd === "number" &&
    typeof value.candidateKey === "string" &&
    typeof value.provenanceRank === "number" &&
    typeof value.updatedMillis === "number" &&
    typeof value.modelRank === "number"
  );
}

type CounterWriter = {
  set(
    ref: FirebaseFirestore.DocumentReference,
    data: FirebaseFirestore.DocumentData,
    options: FirebaseFirestore.SetOptions,
  ): unknown;
};

function eventDate(ev: UsageEventDoc): Date | undefined {
  return (
    coerceFirestoreDate(ev.recordedAt) ??
    coerceFirestoreDate(ev.timestamp) ??
    coerceFirestoreDate(ev.startTime) ??
    coerceFirestoreDate(ev.endTime) ??
    coerceFirestoreDate(ev.createdAt) ??
    coerceFirestoreDate(ev.updatedAt)
  );
}

export function toUtcDate(d: Date): string {
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

function eventMetrics(ev: UsageEventDoc): { tokens: number; cost?: number; model?: string } {
  const rawInput = finiteNumber(ev.inputTokens);
  const output = finiteNumber(ev.outputTokens);
  const cacheCreation = finiteNumber(ev.cacheCreationTokens);
  const cacheRead = finiteNumber(ev.cacheReadTokens);
  const priced = priceLegacyKimiEvent(String(ev.providerID ?? ev.provider ?? ""), String(ev.model ?? ""), {
    inputTokens: rawInput,
    outputTokens: output,
    cacheCreationTokens: cacheCreation,
    cacheReadTokens: cacheRead,
  });

  if (!priced.isLegacy) {
    return { tokens: eventTokens(ev), cost: eventCost(ev), model: ev.model };
  }

  return {
    tokens: priced.totalTokens ?? 0,
    cost: priced.costUsd,
    model: priced.model,
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
    coerceFirestoreDate(ev.updatedAt)?.getTime() ??
    coerceFirestoreDate(ev.createdAt)?.getTime() ??
    coerceFirestoreDate(ev.endTime)?.getTime() ??
    coerceFirestoreDate(ev.startTime)?.getTime() ??
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

  return [provider, sessionId, deviceId, accountId, startedAt, tokenBucketKey(ev, metrics)].join("|");
}

function stripUndefined(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => stripUndefined(item));
  }
  if (isRecord(value)) {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      return value;
    }
    return Object.fromEntries(
      Object.entries(value)
        .filter(([, entryValue]) => entryValue !== undefined)
        .map(([key, entryValue]) => [key, stripUndefined(entryValue)]),
    );
  }
  return value;
}

export function stripUndefinedDocument(value: object): DocumentData {
  const stripped = stripUndefined(value);
  if (isRecord(stripped)) {
    const out: DocumentData = {};
    for (const [key, item] of Object.entries(stripped)) {
      if (item !== undefined) out[key] = item;
    }
    return out;
  }
  return stripUndefinedObject(value);
}

export function requireWindowRollups(
  partial: Partial<Record<WindowKey, UsageRollupDoc>>,
): Record<WindowKey, UsageRollupDoc> {
  const today = partial.today;
  const sevenDay = partial["7d"];
  const thirtyDay = partial["30d"];
  const ninetyDay = partial["90d"];
  const allTime = partial.all_time;
  if (!today || !sevenDay || !thirtyDay || !ninetyDay || !allTime) {
    throw new Error("Usage rollup computation did not populate every window.");
  }
  return {
    today,
    "7d": sevenDay,
    "30d": thirtyDay,
    "90d": ninetyDay,
    all_time: allTime,
  };
}

function safeCounterSegment(value: string): string {
  const normalized = value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_.-]+/g, "_");
  return (normalized || "unknown").slice(0, 140);
}

export function stableCounterKey(value: string): string {
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

export function usageContribution(ev: UsageEventDoc | undefined, candidateKey = ""): UsageCounterCandidate | undefined {
  if (!ev) return undefined;
  const date = eventDate(ev);
  if (!date) return undefined;
  const metrics = eventMetrics(ev);
  const providerID = eventProviderID(ev);
  const accountKey = accountSummaryKey(ev);
  const model = metrics.model;
  const executionSourceId =
    ev.executionSourceID ?? (ev.executionSourceName ? safeCounterSegment(ev.executionSourceName) : undefined);
  const executionSourceName = ev.executionSourceName ?? ev.executionSourceID;
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
    executionSourceId,
    executionSourceName,
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
  bucketFields: DocumentData,
): void {
  const deltaRequests = direction * contribution.requests;
  const deltaTokens = direction * contribution.tokens;
  const deltaCost = direction * contribution.costUsd;

  writer.set(
    bucketRef,
    stripUndefinedDocument({
      ...bucketFields,
      requests: FieldValue.increment(deltaRequests),
      tokens: FieldValue.increment(deltaTokens),
      costUsd: FieldValue.increment(deltaCost),
      updatedAt: now,
      schemaVersion: COUNTER_SCHEMA_VERSION,
    }),
    { merge: true },
  );

  const providerRef = bucketRef.collection("providers").doc(counterDocID(contribution.provider));
  writer.set(
    providerRef,
    stripUndefinedDocument({
      provider: contribution.provider,
      providerID: contribution.providerID,
      requests: FieldValue.increment(deltaRequests),
      tokens: FieldValue.increment(deltaTokens),
      costUsd: FieldValue.increment(deltaCost),
      updatedAt: now,
      schemaVersion: COUNTER_SCHEMA_VERSION,
    }),
    { merge: true },
  );

  const accountRef = bucketRef.collection("accounts").doc(counterDocID(contribution.accountKey));
  writer.set(
    accountRef,
    stripUndefinedDocument({
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
    { merge: true },
  );

  if (contribution.model) {
    const modelRef = bucketRef.collection("models").doc(counterDocID(`${contribution.provider}:${contribution.model}`));
    writer.set(
      modelRef,
      stripUndefinedDocument({
        provider: contribution.provider,
        model: contribution.model,
        requests: FieldValue.increment(deltaRequests),
        tokens: FieldValue.increment(deltaTokens),
        costUsd: FieldValue.increment(deltaCost),
        updatedAt: now,
        schemaVersion: COUNTER_SCHEMA_VERSION,
      }),
      { merge: true },
    );
  }

  if (contribution.deviceId) {
    const deviceRef = bucketRef.collection("devices").doc(counterDocID(contribution.deviceId));
    writer.set(
      deviceRef,
      stripUndefinedDocument({
        deviceId: contribution.deviceId,
        requests: FieldValue.increment(deltaRequests),
        tokens: FieldValue.increment(deltaTokens),
        updatedAt: now,
        schemaVersion: COUNTER_SCHEMA_VERSION,
      }),
      { merge: true },
    );
  }

  if (contribution.executionSourceId) {
    const executionSourceRef = bucketRef
      .collection("executionSources")
      .doc(counterDocID(contribution.executionSourceId));
    writer.set(
      executionSourceRef,
      stripUndefinedDocument({
        executionSourceId: contribution.executionSourceId,
        executionSourceName: contribution.executionSourceName,
        requests: FieldValue.increment(deltaRequests),
        tokens: FieldValue.increment(deltaTokens),
        costUsd: FieldValue.increment(deltaCost),
        updatedAt: now,
        schemaVersion: COUNTER_SCHEMA_VERSION,
      }),
      { merge: true },
    );
  }

  if (contribution.executionSourceId && contribution.model) {
    const comboRef = bucketRef
      .collection("combos")
      .doc(counterDocID(`${contribution.executionSourceId}:${contribution.provider}:${contribution.model}`));
    writer.set(
      comboRef,
      stripUndefinedDocument({
        executionSourceId: contribution.executionSourceId,
        executionSourceName: contribution.executionSourceName,
        provider: contribution.provider,
        model: contribution.model,
        requests: FieldValue.increment(deltaRequests),
        tokens: FieldValue.increment(deltaTokens),
        costUsd: FieldValue.increment(deltaCost),
        updatedAt: now,
        schemaVersion: COUNTER_SCHEMA_VERSION,
      }),
      { merge: true },
    );
  }
}

export function addContribution(
  writer: CounterWriter,
  db: Firestore,
  uid: string,
  contribution: UsageCounterContribution,
  direction: 1 | -1,
  now: string,
): void {
  const dayRef = db.doc(`users/${uid}/usage_counter_days/${contribution.day}`);
  addContributionToBucket(writer, dayRef, contribution, direction, now, {
    day: contribution.day,
  });

  const allTimeRef = db.doc(`users/${uid}/usage_counter_totals/all_time`);
  addContributionToBucket(writer, allTimeRef, contribution, direction, now, {
    windowKey: "all_time",
    // Rolling per-day token series: lets rollup reads derive the all_time
    // dailyPoints map without scanning every usage_counter_days doc.
    dailyTokens: { [contribution.day]: FieldValue.increment(direction * contribution.tokens) },
    // Rolling per-day per-provider token map: same trick as dailyTokens, one
    // level deeper, backing the all_time dailyProviderTokens heatmap split.
    dailyProviderTokens: {
      [contribution.day]: { [contribution.providerID]: FieldValue.increment(direction * contribution.tokens) },
    },
  });
}

function betterCounterCandidate(candidate: UsageCounterCandidate, existing: UsageCounterCandidate): boolean {
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

export function selectCounterWinner(
  candidates: Record<string, UsageCounterCandidate>,
): UsageCounterCandidate | undefined {
  let winner: UsageCounterCandidate | undefined;
  for (const candidate of Object.values(candidates)) {
    if (!winner || betterCounterCandidate(candidate, winner)) {
      winner = candidate;
    }
  }
  return winner;
}

/**
 * Projects a candidate (or `undefined`) onto the ordered tuple of fields that
 * `sameCounterCandidate` compares. An `undefined` candidate projects to a
 * tuple of `undefined`s, preserving the original optional-chaining semantics:
 * two undefined candidates compare equal, while undefined vs defined differs
 * on every defined field.
 */
function counterCandidateComparable(candidate: UsageCounterCandidate | undefined): readonly unknown[] {
  return [
    candidate?.candidateKey,
    candidate?.logicalKey,
    candidate?.day,
    candidate?.provider,
    candidate?.providerID,
    candidate?.accountKey,
    candidate?.accountID,
    candidate?.accountLabel,
    candidate?.storageScope,
    candidate?.model,
    candidate?.deviceId,
    candidate?.executionSourceId,
    candidate?.executionSourceName,
    candidate?.requests,
    candidate?.tokens,
    candidate?.costUsd,
    candidate?.provenanceRank,
    candidate?.updatedMillis,
    candidate?.modelRank,
  ];
}

export function sameCounterCandidate(
  a: UsageCounterCandidate | undefined,
  b: UsageCounterCandidate | undefined,
): boolean {
  const left = counterCandidateComparable(a);
  const right = counterCandidateComparable(b);
  return left.every((value, index) => value === right[index]);
}

export async function applyUsageCounterDelta(
  db: Firestore,
  uid: string,
  usageDoc: string,
  before: UsageEventDoc | undefined,
  after: UsageEventDoc | undefined,
): Promise<void> {
  const candidateKey = stableCounterKey(usageDoc);
  let oldContribution: UsageCounterCandidate | undefined;
  let newContribution: UsageCounterCandidate | undefined;
  try {
    oldContribution = usageContribution(before, candidateKey);
    newContribution = usageContribution(after, candidateKey);
  } finally {
    await flushDomainCorePricingShadowEvidence();
  }
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
      }),
    );

    for (const { logicalKey, keyRef, snap } of entries) {
      const existing = snap.exists ? (snap.data() ?? {}) : {};
      const candidates = Object.fromEntries(
        Object.entries(recordOrUndefined(existing.candidates) ?? {}).filter(
          (entry): entry is [string, UsageCounterCandidate] => isUsageCounterCandidate(entry[1]),
        ),
      );
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
        stripUndefinedDocument({
          logicalKey,
          candidates,
          winner: nextWinner,
          updatedAt: now,
          schemaVersion: COUNTER_SCHEMA_VERSION,
        }),
        { merge: false },
      );
    }
  });
}
