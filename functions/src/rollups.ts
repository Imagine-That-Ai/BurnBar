/**
 * @fileoverview Usage rollup computation.
 *
 * Maintains compact daily usage counters, computes per-window aggregates, and
 * writes `usage_rollups/{windowKey}` documents. The scheduled path reads only
 * counter documents; raw usage scans are reserved for explicit repair/backfill.
 */

import { createHash, randomUUID } from "node:crypto";
import { FieldPath, FieldValue, type DocumentData, type Firestore } from "firebase-admin/firestore";
import type {
  UsageEventDoc,
  UsageRollupDoc,
  ProviderSummary,
  ProviderAccountSummary,
  ModelSummary,
  DeviceSummary,
} from "./types.js";
import {
  errorMessage,
  isRecord,
  isTimestampWithToDate,
  isTimestampWithToMillis,
  isProviderAccountStorageScope,
  parseProvider,
  parseRollupJobDoc,
  parseUsageEventDoc,
  recordOrUndefined,
  stripUndefinedObject,
} from "./guards.js";
import { getConfig } from "./config.js";
import { logInfo } from "./logging.js";
import { LEGACY_KIMI_WIRE_MODEL, LEGACY_KIMI_WIRE_PRICING } from "./pricing.js";

const ROLLUP_SCHEMA_VERSION = 3;
const COUNTER_SCHEMA_VERSION = 1;

/** Window keys in ascending granularity order. */
const WINDOW_KEYS = ["today", "7d", "30d", "90d", "all_time"] as const;
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

function isUsageCounterCandidate(value: unknown): value is UsageCounterCandidate {
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

function coerceDate(value: unknown): Date | undefined {
  if (value == null) return undefined;
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? undefined : value;
  }
  if (typeof value === "string" || typeof value === "number") {
    const d = new Date(value);
    return Number.isNaN(d.getTime()) ? undefined : d;
  }

  if (isTimestampWithToDate(value)) {
    const d = value.toDate();
    return Number.isNaN(d.getTime()) ? undefined : d;
  }
  if (isTimestampWithToMillis(value)) {
    const d = new Date(value.toMillis());
    return Number.isNaN(d.getTime()) ? undefined : d;
  }
  if (isRecord(value)) {
    const seconds = typeof value.seconds === "number" ? value.seconds : value._seconds;
    const nanos = typeof value.nanoseconds === "number" ? value.nanoseconds : (value._nanoseconds ?? 0);
    if (typeof seconds === "number") {
      const d = new Date(seconds * 1000 + Math.floor(Number(nanos) / 1_000_000));
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
  cacheReadTokens: number,
): number {
  const rates = LEGACY_KIMI_WIRE_PRICING;
  return (
    (inputTokens / 1_000_000) * rates.inputPerMToken +
    (outputTokens / 1_000_000) * rates.outputPerMToken +
    (cacheCreationTokens / 1_000_000) * rates.cacheCreationPerMToken +
    (cacheReadTokens / 1_000_000) * rates.cacheReadPerMToken
  );
}

function eventModel(ev: UsageEventDoc): string | undefined {
  return isLegacyKimiWireEvent(ev) ? LEGACY_KIMI_WIRE_MODEL : ev.model;
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

function stripUndefinedDocument(value: object): DocumentData {
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

function requireWindowRollups(partial: Partial<Record<WindowKey, UsageRollupDoc>>): Record<WindowKey, UsageRollupDoc> {
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

function usageContribution(ev: UsageEventDoc | undefined, candidateKey = ""): UsageCounterCandidate | undefined {
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
}

function addContribution(
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

function selectCounterWinner(candidates: Record<string, UsageCounterCandidate>): UsageCounterCandidate | undefined {
  let winner: UsageCounterCandidate | undefined;
  for (const candidate of Object.values(candidates)) {
    if (!winner || betterCounterCandidate(candidate, winner)) {
      winner = candidate;
    }
  }
  return winner;
}

function sameCounterCandidate(a: UsageCounterCandidate | undefined, b: UsageCounterCandidate | undefined): boolean {
  return (
    a?.candidateKey === b?.candidateKey &&
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
    a?.modelRank === b?.modelRank
  );
}

export async function applyUsageCounterDelta(
  db: Firestore,
  uid: string,
  usageDoc: string,
  before: UsageEventDoc | undefined,
  after: UsageEventDoc | undefined,
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

// ---------------------------------------------------------------------------
// Pending-delta queue (crosscut-011)
//
// `onUsageWritten` used to apply counter deltas synchronously: every usage
// event ran a transaction of up to 11-21 sets that write-locked the SAME
// day/all_time bucket docs (and their provider/account/model/device subdocs)
// for the user. Session-end sync bursts land up to 400 events near-
// simultaneously, so those transactions serialized on ~10 shared docs,
// exhausted admin-SDK retries, recorded `lastErrorCode`, and forced the next
// scheduled pass into a destructive full rebuild.
//
// The queue model makes the trigger contention-free: each event appends ONE
// immutable `users/{uid}/pending_counter_deltas/{id}` doc (its own doc — no
// shared locks) carrying full winner-resolution candidate data for the
// before/after states. The 5-minute worker (and the refresh callable) drains
// the queue in pages: one transaction per page replays the transitions
// against the `usage_counter_keys` winner state and applies COALESCED bucket
// increments — one set per bucket doc per page instead of per event. Client-
// visible freshness is unchanged (clients read `usage_rollups`, written on
// the same 5-minute cadence), and exactly-once accounting is preserved by
// the same candidates/winner state machine: replaying an already-applied
// transition leaves the winner unchanged and emits zero increments.
//
// `applyUsageCounterDelta` above remains the single-event reference
// implementation of the transition semantics (and the repair-path building
// block); the planner below MUST stay behaviorally equivalent to running it
// once per delta in enqueue order.
// ---------------------------------------------------------------------------

/** Queue doc payload. `before`/`after` carry full winner-resolution data. */
export type PendingCounterDelta = {
  usageDoc: string;
  candidateKey: string;
  before?: UsageCounterCandidate;
  after?: UsageCounterCandidate;
  enqueuedAt: string;
  schemaVersion: number;
};

export function isPendingCounterDelta(value: unknown): value is PendingCounterDelta {
  if (!isRecord(value)) return false;
  if (typeof value.usageDoc !== "string" || typeof value.candidateKey !== "string") return false;
  if (typeof value.enqueuedAt !== "string") return false;
  if (value.before !== undefined && !isUsageCounterCandidate(value.before)) return false;
  if (value.after !== undefined && !isUsageCounterCandidate(value.after)) return false;
  return value.before !== undefined || value.after !== undefined;
}

/**
 * Builds the queue payload for one usage-doc write, or undefined when neither
 * side contributes (mirrors `applyUsageCounterDelta`'s early return).
 */
export function buildPendingCounterDelta(
  usageDoc: string,
  before: UsageEventDoc | undefined,
  after: UsageEventDoc | undefined,
  enqueuedAt: string,
): PendingCounterDelta | undefined {
  const candidateKey = stableCounterKey(usageDoc);
  const beforeContribution = usageContribution(before, candidateKey);
  const afterContribution = usageContribution(after, candidateKey);
  if (!beforeContribution && !afterContribution) return undefined;
  return {
    usageDoc,
    candidateKey,
    before: beforeContribution,
    after: afterContribution,
    enqueuedAt,
    schemaVersion: COUNTER_SCHEMA_VERSION,
  };
}

/**
 * Time-prefixed doc ID: the queue is drained in implicit `__name__` order, so
 * a fixed-width ISO-8601 prefix makes lexicographic order chronological. A
 * per-instance sequence keeps same-millisecond sequential enqueues ordered
 * before the random suffix makes IDs collision-free. (Monotonic-ID hotspotting
 * only matters at sustained >500 writes/s — far above session-end burst rates.
 * Cross-instance trigger delivery can still be out-of-order; the dirty/full
 * rebuild path self-heals that rarer case.)
 */
let lastPendingCounterDeltaEnqueuedAt = "";
let lastPendingCounterDeltaSequence = 0;

export function pendingCounterDeltaDocID(enqueuedAt: string): string {
  if (enqueuedAt === lastPendingCounterDeltaEnqueuedAt) {
    lastPendingCounterDeltaSequence += 1;
  } else {
    lastPendingCounterDeltaEnqueuedAt = enqueuedAt;
    lastPendingCounterDeltaSequence = 0;
  }

  const sequence = lastPendingCounterDeltaSequence.toString(36).padStart(8, "0");
  return `${enqueuedAt}_${sequence}_${randomUUID()}`;
}

/**
 * Trigger-side enqueue: exactly one set on a per-event doc, zero shared
 * locks. Returns false when the write carried nothing countable.
 */
export async function enqueueUsageCounterDelta(
  db: Firestore,
  uid: string,
  usageDoc: string,
  before: UsageEventDoc | undefined,
  after: UsageEventDoc | undefined,
): Promise<boolean> {
  const enqueuedAt = new Date().toISOString();
  const delta = buildPendingCounterDelta(usageDoc, before, after, enqueuedAt);
  if (!delta) return false;
  const ref = db.collection(`users/${uid}/pending_counter_deltas`).doc(pendingCounterDeltaDocID(enqueuedAt));
  await ref.set(stripUndefinedDocument(delta), { merge: false });
  return true;
}

export type PendingDeltaKeyWrite = {
  logicalKey: string;
  candidates: Record<string, UsageCounterCandidate>;
  winner?: UsageCounterCandidate;
};

export type PendingDeltaDrainPlan = {
  /** Final candidates/winner state per touched logical key. */
  keyWrites: PendingDeltaKeyWrite[];
  /** Merged signed increments: apply each once with direction +1. */
  bucketContributions: UsageCounterContribution[];
};

/** Identity tuple addContribution routes/labels bucket docs by. */
function bucketIdentityKey(contribution: UsageCounterContribution): string {
  return JSON.stringify([
    contribution.day,
    contribution.provider,
    contribution.providerID,
    contribution.accountKey,
    contribution.accountID ?? "",
    contribution.accountLabel,
    contribution.storageScope ?? "",
    contribution.model ?? "",
    contribution.deviceId ?? "",
  ]);
}

function mergeSignedContributions(
  entries: ReadonlyArray<{ contribution: UsageCounterContribution; direction: 1 | -1 }>,
): UsageCounterContribution[] {
  const merged = new Map<string, UsageCounterContribution>();
  for (const { contribution, direction } of entries) {
    const key = bucketIdentityKey(contribution);
    const existing = merged.get(key);
    if (existing) {
      existing.requests += direction * contribution.requests;
      existing.tokens += direction * contribution.tokens;
      existing.costUsd += direction * contribution.costUsd;
    } else {
      merged.set(key, {
        logicalKey: contribution.logicalKey,
        day: contribution.day,
        provider: contribution.provider,
        providerID: contribution.providerID,
        accountKey: contribution.accountKey,
        accountID: contribution.accountID,
        accountLabel: contribution.accountLabel,
        storageScope: contribution.storageScope,
        model: contribution.model,
        deviceId: contribution.deviceId,
        requests: direction * contribution.requests,
        tokens: direction * contribution.tokens,
        costUsd: direction * contribution.costUsd,
      });
    }
  }
  // Net-zero groups (e.g. a winner flip between identical bucket tuples) are
  // pure no-ops — skip the writes entirely.
  return [...merged.values()].filter(
    (contribution) => contribution.requests !== 0 || contribution.tokens !== 0 || contribution.costUsd !== 0,
  );
}

/**
 * Pure drain planner. Replays `deltas` IN ORDER against the supplied
 * `usage_counter_keys` candidate state, exactly like sequential
 * `applyUsageCounterDelta` transactions would (remove the before-candidate
 * from its logical key, install the after-candidate in its logical key), then
 * emits ONE winner flip per logical key — initial winner vs final winner —
 * with all increments coalesced per bucket identity. Intermediate winner
 * states never produce writes, which is what collapses a 400-event burst into
 * a handful of bucket sets.
 */
export function planPendingDeltaDrain(
  deltas: readonly PendingCounterDelta[],
  existingKeyStates: ReadonlyMap<string, Record<string, UsageCounterCandidate>>,
): PendingDeltaDrainPlan {
  const states = new Map<string, Record<string, UsageCounterCandidate>>();
  const initialWinners = new Map<string, UsageCounterCandidate | undefined>();
  const touchedKeys: string[] = [];

  const stateFor = (logicalKey: string): Record<string, UsageCounterCandidate> => {
    const existing = states.get(logicalKey);
    if (existing) return existing;
    const seeded = { ...(existingKeyStates.get(logicalKey) ?? {}) };
    states.set(logicalKey, seeded);
    initialWinners.set(logicalKey, selectCounterWinner(seeded));
    touchedKeys.push(logicalKey);
    return seeded;
  };

  for (const delta of deltas) {
    if (delta.before) {
      delete stateFor(delta.before.logicalKey)[delta.candidateKey];
    }
    if (delta.after) {
      stateFor(delta.after.logicalKey)[delta.candidateKey] = delta.after;
    }
  }

  const signed: Array<{ contribution: UsageCounterContribution; direction: 1 | -1 }> = [];
  const keyWrites: PendingDeltaKeyWrite[] = [];
  for (const logicalKey of touchedKeys) {
    const candidates = states.get(logicalKey) ?? {};
    const previousWinner = initialWinners.get(logicalKey);
    const nextWinner = selectCounterWinner(candidates);
    if (!sameCounterCandidate(previousWinner, nextWinner)) {
      if (previousWinner) signed.push({ contribution: previousWinner, direction: -1 });
      if (nextWinner) signed.push({ contribution: nextWinner, direction: 1 });
    }
    keyWrites.push({ logicalKey, candidates, winner: nextWinner });
  }

  return { keyWrites, bucketContributions: mergeSignedContributions(signed) };
}

/** Writes per page stay safely under the 500-op transaction ceiling:
 * <= 100 queue deletes + <= 200 key sets + the coalesced bucket sets. */
const PENDING_DELTA_DRAIN_PAGE_SIZE = 100;

/**
 * Default per-invocation page ceiling (P0-7): 20 pages = 2,000 queue docs.
 * Without a cap, a pathological backlog turns the page loop into an unbounded
 * stall for the scheduled worker AND the dashboard callable. Callers pass the
 * `rollupPendingDeltaDrainMaxPages` config knob; this default covers direct
 * invocations (scripts, tests).
 */
const DEFAULT_PENDING_DELTA_DRAIN_MAX_PAGES = 20;

export type DrainPendingCounterDeltasResult = {
  drainedDocs: number;
  pages: number;
  /** True when the page cap stopped the drain with queue docs likely remaining. */
  capped: boolean;
};

/**
 * Drains the user's pending-delta queue into the counter docs. Each page runs
 * in one transaction: key states are read transactionally, so a concurrent
 * drain (overlapping worker runs, or worker + callable) retries and replays
 * idempotently — already-applied transitions leave winners unchanged and emit
 * no increments. Unparseable queue docs are deleted with their page so they
 * cannot wedge the queue.
 *
 * The drain stops after `maxPages` pages and reports `capped: true`; callers
 * must then keep the rollup job dirty (writeUserRollups `keepDirty`) so the
 * next 5-minute tick resumes the queue instead of orphaning it.
 */
export async function drainPendingCounterDeltas(
  db: Firestore,
  uid: string,
  options: { maxPages?: number } = {},
): Promise<DrainPendingCounterDeltasResult> {
  const queuePath = `users/${uid}/pending_counter_deltas`;
  const maxPages = Math.max(1, Math.floor(options.maxPages ?? DEFAULT_PENDING_DELTA_DRAIN_MAX_PAGES));
  let drainedDocs = 0;
  let pages = 0;
  let capped = false;

  for (;;) {
    // No orderBy: implicit __name__ ordering plus time-prefixed doc IDs (see
    // pendingCounterDeltaDocID) yields oldest-first with no index needs.
    const page = await db.collection(queuePath).limit(PENDING_DELTA_DRAIN_PAGE_SIZE).get();
    if (page.docs.length === 0) break;
    pages += 1;

    const deltas: PendingCounterDelta[] = [];
    for (const doc of page.docs) {
      const data = doc.data();
      if (isPendingCounterDelta(data)) deltas.push(data);
    }

    const logicalKeys: string[] = [];
    const seenKeys = new Set<string>();
    for (const delta of deltas) {
      for (const logicalKey of [delta.before?.logicalKey, delta.after?.logicalKey]) {
        if (logicalKey !== undefined && !seenKeys.has(logicalKey)) {
          seenKeys.add(logicalKey);
          logicalKeys.push(logicalKey);
        }
      }
    }

    const now = new Date().toISOString();
    await db.runTransaction(async (transaction) => {
      const keyRefs = logicalKeys.map((logicalKey) =>
        db.doc(`users/${uid}/usage_counter_keys/${stableCounterKey(logicalKey)}`),
      );
      const keySnaps = keyRefs.length > 0 ? await transaction.getAll(...keyRefs) : [];
      const states = new Map<string, Record<string, UsageCounterCandidate>>();
      keySnaps.forEach((snap, index) => {
        const existing = snap.exists ? (snap.data() ?? {}) : {};
        const candidates = Object.fromEntries(
          Object.entries(recordOrUndefined(existing.candidates) ?? {}).filter(
            (entry): entry is [string, UsageCounterCandidate] => isUsageCounterCandidate(entry[1]),
          ),
        );
        states.set(logicalKeys[index], candidates);
      });

      const plan = planPendingDeltaDrain(deltas, states);
      for (const contribution of plan.bucketContributions) {
        addContribution(transaction, db, uid, contribution, 1, now);
      }
      for (const write of plan.keyWrites) {
        const keyRef = db.doc(`users/${uid}/usage_counter_keys/${stableCounterKey(write.logicalKey)}`);
        transaction.set(
          keyRef,
          stripUndefinedDocument({
            logicalKey: write.logicalKey,
            candidates: write.candidates,
            winner: write.winner,
            updatedAt: now,
            schemaVersion: COUNTER_SCHEMA_VERSION,
          }),
          { merge: false },
        );
      }
      for (const doc of page.docs) {
        transaction.delete(doc.ref);
      }
    });

    drainedDocs += page.docs.length;
    if (page.docs.length < PENDING_DELTA_DRAIN_PAGE_SIZE) break;
    if (pages >= maxPages) {
      capped = true;
      // Stable jsonPayload.event key — GCP log metrics/alerts are wired to
      // exactly this string. Do not rename.
      logInfo({
        event: "rollup.delta_drain_capped",
        uid,
        pages,
        drained_docs: drainedDocs,
        max_pages: maxPages,
      });
      break;
    }
  }

  return { drainedDocs, pages, capped };
}

async function queryCounterDocs(
  db: Firestore,
  collection: string,
  bucketPaths: string[],
): Promise<FirebaseFirestore.DocumentData[]> {
  const snapshots = await Promise.all(bucketPaths.map((path) => db.collection(`${path}/${collection}`).get()));
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
  uid: string,
  options: { repairPageSize?: number } = {},
): Promise<Record<WindowKey, UsageRollupDoc>> {
  await rebuildUserRollupCounters(db, uid, { pageSize: options.repairPageSize });
  return computeUserRollupsFromCounters(db, uid);
}

type CounterBucketDocs = {
  providers: DocumentData[];
  accounts: DocumentData[];
  models: DocumentData[];
  devices: DocumentData[];
};

async function fetchCounterBucketDocs(db: Firestore, bucketPaths: string[]): Promise<CounterBucketDocs> {
  const [providers, accounts, models, devices] = await Promise.all([
    queryCounterDocs(db, "providers", bucketPaths),
    queryCounterDocs(db, "accounts", bucketPaths),
    queryCounterDocs(db, "models", bucketPaths),
    queryCounterDocs(db, "devices", bucketPaths),
  ]);
  return { providers, accounts, models, devices };
}

/**
 * Returns the `[day, tokens]` series backing the all_time `dailyPoints` map.
 *
 * `addContribution` maintains a rolling `dailyTokens` map on the all_time
 * totals doc so this read is O(1) instead of an unbounded scan of
 * `usage_counter_days` (day docs are never deleted, so that scan grows with
 * account age forever). Totals docs written before the map existed fall back
 * to one legacy scan, and the derived map is persisted so the next compute
 * reads it incrementally. The persist is skipped when `updatedAt` moved
 * between the caller's totals read and the transaction — a counter write
 * landed mid-scan and an absolute write could overwrite its increment; the
 * next worker pass retries the backfill.
 */
async function allTimeDailyTokenEntries(
  db: Firestore,
  uid: string,
  allTimeData: DocumentData | undefined,
): Promise<(readonly [string, number])[]> {
  const dailyTokens = recordOrUndefined(allTimeData?.dailyTokens);
  if (dailyTokens) {
    return Object.entries(dailyTokens)
      .map(([day, tokens]) => [day, sumNumber(tokens)] as const)
      .sort(([dayA], [dayB]) => (dayA < dayB ? -1 : dayA > dayB ? 1 : 0));
  }

  const scannedDays = (await db.collection(`users/${uid}/usage_counter_days`).get()).docs.map(
    (doc) => doc.data() ?? {},
  );
  const entries = scannedDays.map((doc) => [String(doc.day), sumNumber(doc.tokens)] as const);

  if (allTimeData) {
    const observedUpdatedAt = allTimeData.updatedAt;
    const allTimeRef = db.doc(`users/${uid}/usage_counter_totals/all_time`);
    await db.runTransaction(async (transaction) => {
      const snap = await transaction.get(allTimeRef);
      const data = snap.exists ? (snap.data() ?? {}) : undefined;
      if (!data || recordOrUndefined(data.dailyTokens) || data.updatedAt !== observedUpdatedAt) return;
      transaction.set(allTimeRef, { dailyTokens: Object.fromEntries(entries) }, { merge: true });
    });
  }

  return entries;
}

export async function computeUserRollupsFromCounters(
  db: Firestore,
  uid: string,
): Promise<Record<WindowKey, UsageRollupDoc>> {
  const now = new Date();
  const results: Partial<Record<WindowKey, UsageRollupDoc>> = {};

  // The day-keyed windows nest (today ⊂ 7d ⊂ 30d ⊂ 90d), so fetch the 90-day
  // union once — one documentId range query instead of per-window point gets
  // (which also bills nothing for days with no usage) — and read each day
  // bucket's subcollections once, then aggregate every window in memory.
  const daysPath = `users/${uid}/usage_counter_days`;
  const unionDays = windowDays("90d", now) ?? [];
  const unionDaySet = new Set(unionDays);
  const daySnapshot = await db
    .collection(daysPath)
    .where(FieldPath.documentId(), ">=", unionDays[unionDays.length - 1])
    .where(FieldPath.documentId(), "<=", unionDays[0])
    .get();
  const dayDataById = new Map<string, DocumentData>();
  for (const doc of daySnapshot.docs) {
    if (unionDaySet.has(doc.id)) dayDataById.set(doc.id, doc.data() ?? {});
  }

  // unionDays is newest-first and each window's day list is a prefix of it,
  // so filtering preserves the per-window iteration order of the old per-day
  // point gets (and therefore the emitted aggregation order).
  const dayBuckets = await Promise.all(
    unionDays
      .filter((id) => dayDataById.has(id))
      .map(async (id) => {
        const data = dayDataById.get(id) ?? {};
        const day = typeof data.day === "string" ? data.day : "";
        const docs = await fetchCounterBucketDocs(db, day ? [`${daysPath}/${day}`] : []);
        return { id, data, ...docs };
      }),
  );

  const allTimePath = `users/${uid}/usage_counter_totals/all_time`;
  const allTimeSnap = await db.doc(allTimePath).get();
  const allTimeData = allTimeSnap.exists ? (allTimeSnap.data() ?? {}) : undefined;
  const allTimeDocs = await fetchCounterBucketDocs(db, allTimeData ? [allTimePath] : []);
  const allTimeDailyEntries = await allTimeDailyTokenEntries(db, uid, allTimeData);

  for (const key of WINDOW_KEYS) {
    let bucketDocs: DocumentData[];
    let counterDocs: CounterBucketDocs;
    let dailyPointEntries: (readonly [string, number])[];
    if (key === "all_time") {
      bucketDocs = allTimeData ? [allTimeData] : [];
      counterDocs = allTimeDocs;
      dailyPointEntries = allTimeDailyEntries;
    } else {
      const windowSet = new Set(windowDays(key, now) ?? []);
      const windowBuckets = dayBuckets.filter((bucket) => windowSet.has(bucket.id));
      bucketDocs = windowBuckets.map((bucket) => bucket.data);
      counterDocs = {
        providers: windowBuckets.flatMap((bucket) => bucket.providers),
        accounts: windowBuckets.flatMap((bucket) => bucket.accounts),
        models: windowBuckets.flatMap((bucket) => bucket.models),
        devices: windowBuckets.flatMap((bucket) => bucket.devices),
      };
      dailyPointEntries = bucketDocs.map((doc) => [String(doc.day), sumNumber(doc.tokens)] as const);
    }
    const { providers, accounts, models, devices } = counterDocs;

    const totals = bucketDocs.reduce(
      (acc, doc) => {
        acc.requests += sumNumber(doc.requests);
        acc.tokens += sumNumber(doc.tokens);
        acc.costUsd += sumNumber(doc.costUsd);
        return acc;
      },
      { requests: 0, tokens: 0, costUsd: 0 },
    );

    const dailyPoints = Object.fromEntries(dailyPointEntries.filter(([day, tokens]) => day && tokens !== 0));

    const providerMap = new Map<string, ProviderSummary>();
    for (const doc of providers) {
      const providerName = typeof doc.provider === "string" ? doc.provider : "unknown";
      const provider = parseProvider(providerName);
      if (!provider) continue;
      const existing = providerMap.get(provider);
      if (existing) {
        existing.totalRequests += sumNumber(doc.requests);
        existing.totalTokens += sumNumber(doc.tokens);
        existing.totalCost = (existing.totalCost ?? 0) + sumNumber(doc.costUsd);
      } else {
        providerMap.set(provider, {
          provider,
          providerID: typeof doc.providerID === "string" ? doc.providerID : undefined,
          totalRequests: sumNumber(doc.requests),
          totalTokens: sumNumber(doc.tokens),
          totalCost: sumNumber(doc.costUsd),
        });
      }
    }

    const accountMap = new Map<string, ProviderAccountSummary>();
    for (const doc of accounts) {
      const providerIDRaw = typeof doc.providerID === "string" ? doc.providerID : "unknown";
      const providerID = parseProvider(providerIDRaw) ?? providerIDRaw;
      const id = typeof doc.accountID === "string" ? doc.accountID : `${providerID}:unattributed`;
      const storageScopeRaw = doc.storageScope;
      const storageScope =
        typeof storageScopeRaw === "string" && isProviderAccountStorageScope(storageScopeRaw)
          ? storageScopeRaw
          : undefined;
      const existing = accountMap.get(id);
      if (existing) {
        existing.totalRequests += sumNumber(doc.requests);
        existing.totalTokens += sumNumber(doc.tokens);
        existing.totalCost = (existing.totalCost ?? 0) + sumNumber(doc.costUsd);
      } else {
        accountMap.set(id, {
          id,
          providerID,
          accountID: typeof doc.accountID === "string" ? doc.accountID : undefined,
          accountLabel: typeof doc.accountLabel === "string" ? doc.accountLabel : "Usage not linked to an account yet",
          storageScope,
          totalRequests: sumNumber(doc.requests),
          totalTokens: sumNumber(doc.tokens),
          totalCost: sumNumber(doc.costUsd),
        });
      }
    }

    const modelMap = new Map<string, ModelSummary>();
    for (const doc of models) {
      const providerName = typeof doc.provider === "string" ? doc.provider : "unknown";
      const provider = parseProvider(providerName);
      if (!provider) continue;
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
          provider,
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
      providerSummaries: Array.from(providerMap.values()).filter(
        (entry) => entry.totalRequests !== 0 || entry.totalTokens !== 0 || (entry.totalCost ?? 0) !== 0,
      ),
      accountSummaries: Array.from(accountMap.values()).filter(
        (entry) => entry.totalRequests !== 0 || entry.totalTokens !== 0 || (entry.totalCost ?? 0) !== 0,
      ),
      modelSummaries: Array.from(modelMap.values()).filter(
        (entry) => entry.requests !== 0 || entry.tokens !== 0 || (entry.cost ?? 0) !== 0,
      ),
      deviceSummaries: Array.from(deviceMap.values()).filter((entry) => entry.requests !== 0 || entry.tokens !== 0),
      dailyPoints,
      computedAt: now.toISOString(),
      schemaVersion: ROLLUP_SCHEMA_VERSION,
    };
  }

  return requireWindowRollups(results);
}

export type RebuildUserRollupCountersResult = {
  usageDocsScanned: number;
  pages: number;
  winnersWritten: number;
};

export async function rebuildUserRollupCounters(
  db: Firestore,
  uid: string,
  options: { pageSize?: number } = {},
): Promise<RebuildUserRollupCountersResult> {
  // The pending-delta queue is purged BEFORE the raw usage scan: everything
  // enqueued so far is superseded by the scan itself, while deltas enqueued
  // mid-scan survive the purge and replay idempotently on the next drain.
  await Promise.all([
    db.recursiveDelete(db.collection(`users/${uid}/usage_counter_days`)),
    db.recursiveDelete(db.collection(`users/${uid}/usage_counter_totals`)),
    db.recursiveDelete(db.collection(`users/${uid}/usage_counter_keys`)),
    db.recursiveDelete(db.collection(`users/${uid}/pending_counter_deltas`)),
  ]);

  const candidatesByLogicalKey = new Map<string, Record<string, UsageCounterCandidate>>();
  const usageRef = db.collection(`users/${uid}/usage`);
  const pageSize = Math.max(1, Math.floor(options.pageSize ?? Number(process.env.ROLLUP_REPAIR_PAGE_SIZE ?? 500)));
  let usageDocsScanned = 0;
  let pages = 0;
  let lastDoc: FirebaseFirestore.QueryDocumentSnapshot | undefined;

  for (;;) {
    let query: FirebaseFirestore.Query = usageRef.orderBy(FieldPath.documentId()).limit(pageSize);
    if (lastDoc) query = query.startAfter(lastDoc);
    const snapshot = await query.get();
    if (snapshot.empty) break;
    pages += 1;

    for (const doc of snapshot.docs) {
      usageDocsScanned += 1;
      const event = parseUsageEventDoc(doc.data());
      if (!event) continue;
      const contribution = usageContribution(event, stableCounterKey(doc.id));
      if (!contribution) continue;
      const candidates = candidatesByLogicalKey.get(contribution.logicalKey) ?? {};
      candidates[contribution.candidateKey] = contribution;
      candidatesByLogicalKey.set(contribution.logicalKey, candidates);
    }

    lastDoc = snapshot.docs.at(-1);
    if (snapshot.docs.length < pageSize || !lastDoc) break;
  }

  const winners = [...candidatesByLogicalKey.entries()]
    .map(([logicalKey, candidates]) => ({
      logicalKey,
      candidates,
      winner: selectCounterWinner(candidates),
    }))
    .filter(
      (
        entry,
      ): entry is {
        logicalKey: string;
        candidates: Record<string, UsageCounterCandidate>;
        winner: UsageCounterCandidate;
      } => entry.winner != null,
    );

  const repairBatchSize = 50;
  for (let i = 0; i < winners.length; i += repairBatchSize) {
    const batch = db.batch();
    const now = new Date().toISOString();
    for (const entry of winners.slice(i, i + repairBatchSize)) {
      addContribution(batch, db, uid, entry.winner, 1, now);
      const keyRef = db.doc(`users/${uid}/usage_counter_keys/${stableCounterKey(entry.logicalKey)}`);
      batch.set(
        keyRef,
        stripUndefinedDocument({
          logicalKey: entry.logicalKey,
          candidates: entry.candidates,
          winner: entry.winner,
          updatedAt: now,
          schemaVersion: COUNTER_SCHEMA_VERSION,
        }),
        { merge: false },
      );
    }
    await batch.commit();
  }

  return {
    usageDocsScanned,
    pages,
    winnersWritten: winners.length,
  };
}

/**
 * Reads the rollup job's current `dirtiedAt` marker.
 *
 * Callers capture this BEFORE computing rollups and pass it to
 * {@link writeUserRollups}, which only clears the dirty flag when the marker
 * is unchanged — i.e. no usage event landed while the compute was running.
 */
export async function readRollupJobDirtiedAt(db: Firestore, uid: string): Promise<string | undefined> {
  const snap = await db.doc(`users/${uid}/rollup_jobs/current`).get();
  const job = snap.exists ? parseRollupJobDoc(snap.data()) : undefined;
  return job?.dirtiedAt;
}

// ---------------------------------------------------------------------------
// Full-rebuild attempt gate (P0-7)
//
// The destructive repair path (recursiveDelete of four counter collections +
// a full raw-usage rescan) used to account for failures only in an in-process
// catch handler, so a timeout/OOM-killed invocation never advanced the
// circuit breaker: the worker re-deleted and re-died every 5 minutes forever.
// The gate below persists an attempt marker transactionally BEFORE the
// expensive work begins.
//
// Invariant: every full-rebuild attempt is preceded by a marker write, and
// the marker is cleared only by the success path (writeUserRollups with
// `clearFullRebuildAttempt`) or the in-process failure path
// (recordRollupRebuildFailure). A killed invocation therefore leaves the
// marker behind; once it is stale the next pass counts it as a consecutive
// failure — the breaker advances even when no catch handler ever ran. A
// still-fresh marker doubles as an in-flight dedupe: no second destructive
// rebuild starts while one may still be running.
// ---------------------------------------------------------------------------

/**
 * An in-flight marker older than this is a killed attempt. Must exceed
 * rebuildRollups' timeoutSeconds (540 s, scheduled.ts) plus scheduler slack so
 * an attempt still inside its own invocation window is never miscounted.
 */
export const FULL_REBUILD_ATTEMPT_STALE_MS = 12 * 60 * 1000;

/** lastErrorCode recorded when a stale marker is counted: the killed attempt
 * may have deleted the counters before dying mid-scan, so they must stay
 * marked untrusted and route the next pass through the repair path. */
const FULL_REBUILD_KILLED_ERROR_CODE = "full_rebuild_attempt_killed";

export type FullRebuildGateOptions = {
  maxConsecutiveFullRebuildFailures: number;
  circuitBreakerMinutes: number;
  /** Defaults to {@link FULL_REBUILD_ATTEMPT_STALE_MS}. */
  staleAttemptMillis?: number;
  /** Set for client `force` rebuilds: enforces the per-user cooldown. */
  forceMinIntervalMillis?: number;
};

export type FullRebuildAttemptGate =
  | { status: "started"; countedStaleAttempt: boolean }
  | { status: "circuit_open"; openUntil: string }
  | { status: "in_flight"; attemptStartedAt: string }
  | { status: "force_cooldown"; retryAt: string };

/** Thrown by {@link refreshUserRollups} when the gate refuses a full rebuild;
 * the callable maps `reason` onto a typed HttpsError. */
export class RollupRebuildUnavailableError extends Error {
  constructor(
    readonly reason: "circuit_open" | "in_flight" | "force_cooldown",
    readonly retryAt?: string,
  ) {
    super(
      reason === "circuit_open"
        ? `Usage counter repair is paused${retryAt ? ` until ${retryAt}` : ""} after repeated failures.`
        : reason === "in_flight"
          ? "A usage counter rebuild is already running for this user."
          : `Forced rebuilds are rate limited; retry${retryAt ? ` after ${retryAt}` : " later"}.`,
    );
    this.name = "RollupRebuildUnavailableError";
  }
}

/**
 * Transactionally claims the right to run a full counter rebuild for `uid`.
 * See the section comment above for the marker/breaker invariant.
 */
export async function beginFullRebuildAttempt(
  db: Firestore,
  uid: string,
  options: FullRebuildGateOptions,
): Promise<FullRebuildAttemptGate> {
  const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
  const staleAttemptMillis = options.staleAttemptMillis ?? FULL_REBUILD_ATTEMPT_STALE_MS;

  return db.runTransaction(async (transaction) => {
    const snap = await transaction.get(jobRef);
    const job = snap.exists ? parseRollupJobDoc(snap.data()) : undefined;
    const nowMillis = Date.now();

    // parseRollupJobDoc rejects docs without a boolean `dirty`, so every gate
    // write must keep one: without this, a gate-created doc for a brand-new
    // user (or a corrupt doc) parses to undefined on the NEXT pass and its
    // attempt marker turns invisible — no in-flight dedupe, and a killed
    // attempt never advances the breaker.
    const ensureParseable = { dirty: job?.dirty ?? false };

    const attemptStartedAt = job?.fullRebuildAttemptInFlightAt;
    const attemptStartedAtMillis = attemptStartedAt != null ? Date.parse(attemptStartedAt) : Number.NaN;
    if (attemptStartedAt != null && Number.isFinite(attemptStartedAtMillis)) {
      if (nowMillis - attemptStartedAtMillis < staleAttemptMillis) {
        return { status: "in_flight", attemptStartedAt };
      }
    }
    const countedStaleAttempt = Number.isFinite(attemptStartedAtMillis);

    const failures = (job?.consecutiveFullRebuildFailures ?? 0) + (countedStaleAttempt ? 1 : 0);
    const stalePatch = countedStaleAttempt
      ? {
          consecutiveFullRebuildFailures: failures,
          lastErrorCode: job?.lastErrorCode ?? FULL_REBUILD_KILLED_ERROR_CODE,
          fullRebuildAttemptInFlightAt: FieldValue.delete(),
        }
      : {};

    const openUntil = job?.fullRebuildCircuitOpenUntil;
    const openUntilMillis = openUntil != null ? Date.parse(openUntil) : Number.NaN;
    if (openUntil != null && Number.isFinite(openUntilMillis) && openUntilMillis > nowMillis) {
      if (countedStaleAttempt) {
        transaction.set(jobRef, { ...ensureParseable, ...stalePatch }, { merge: true });
      }
      return { status: "circuit_open", openUntil };
    }

    if (countedStaleAttempt && failures >= options.maxConsecutiveFullRebuildFailures) {
      const reopenedUntil = new Date(nowMillis + options.circuitBreakerMinutes * 60 * 1000).toISOString();
      transaction.set(
        jobRef,
        { ...ensureParseable, ...stalePatch, fullRebuildCircuitOpenUntil: reopenedUntil },
        { merge: true },
      );
      return { status: "circuit_open", openUntil: reopenedUntil };
    }

    if (typeof options.forceMinIntervalMillis === "number") {
      const lastForceAtMillis = job?.lastForceRebuildAt != null ? Date.parse(job.lastForceRebuildAt) : Number.NaN;
      if (Number.isFinite(lastForceAtMillis) && nowMillis - lastForceAtMillis < options.forceMinIntervalMillis) {
        if (countedStaleAttempt) {
          transaction.set(jobRef, { ...ensureParseable, ...stalePatch }, { merge: true });
        }
        return {
          status: "force_cooldown",
          retryAt: new Date(lastForceAtMillis + options.forceMinIntervalMillis).toISOString(),
        };
      }
    }

    const startPatch: DocumentData = {
      ...ensureParseable,
      ...stalePatch,
      fullRebuildAttemptInFlightAt: new Date(nowMillis).toISOString(),
    };
    if (typeof options.forceMinIntervalMillis === "number") {
      startPatch.lastForceRebuildAt = new Date(nowMillis).toISOString();
    }
    transaction.set(jobRef, startPatch, { merge: true });
    return { status: "started", countedStaleAttempt };
  });
}

/**
 * Failure-path bookkeeping shared by the scheduled worker and the refresh
 * callable. Only failures of the full-rebuild repair path advance the
 * consecutive counter (a first cheap-path failure merely records
 * `lastErrorCode` to route the NEXT pass to repair — the worker's original
 * rule), and the breaker opens once the counter reaches the configured
 * maximum. When the caller's failed attempt went through the gate
 * (`clearAttemptMarker`, the default), its in-flight marker is cleared here
 * because this failure is being counted now; leaving it would double-count
 * the attempt as a stale kill on the next pass. Callers whose failure came
 * from the CHEAP path pass `clearAttemptMarker: false` — they never wrote a
 * marker, and clearing one would hide a concurrent full rebuild's kill from
 * the breaker.
 */
export async function recordRollupRebuildFailure(
  db: Firestore,
  uid: string,
  errorCode: string,
  options: {
    maxConsecutiveFullRebuildFailures: number;
    circuitBreakerMinutes: number;
    clearAttemptMarker?: boolean;
  },
): Promise<{ breakerOpened: boolean }> {
  const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
  return db.runTransaction(async (transaction) => {
    const snap = await transaction.get(jobRef);
    const job = snap.exists ? parseRollupJobDoc(snap.data()) : undefined;
    const wasFullRebuildFailure = job?.lastErrorCode != null;
    const consecutiveFullRebuildFailures = wasFullRebuildFailure
      ? (job?.consecutiveFullRebuildFailures ?? 0) + 1
      : FieldValue.delete();
    const breakerShouldOpen =
      typeof consecutiveFullRebuildFailures === "number" &&
      consecutiveFullRebuildFailures >= options.maxConsecutiveFullRebuildFailures;
    const attemptPatch =
      options.clearAttemptMarker === false ? {} : { fullRebuildAttemptInFlightAt: FieldValue.delete() };
    transaction.set(
      jobRef,
      {
        // Keep the doc parseable for the gate (see beginFullRebuildAttempt).
        dirty: job?.dirty ?? false,
        lastErrorCode: errorCode,
        consecutiveFullRebuildFailures,
        fullRebuildCircuitOpenUntil: breakerShouldOpen
          ? new Date(Date.now() + options.circuitBreakerMinutes * 60 * 1000).toISOString()
          : FieldValue.delete(),
        ...attemptPatch,
      },
      { merge: true },
    );
    return { breakerOpened: breakerShouldOpen };
  });
}

function fullRebuildGateOptionsFromConfig(): FullRebuildGateOptions {
  const cfg = getConfig();
  return {
    maxConsecutiveFullRebuildFailures: cfg.rollupMaxConsecutiveFullRebuildFailures,
    circuitBreakerMinutes: cfg.rollupFullRebuildCircuitBreakerMinutes,
  };
}

export type RefreshUserRollupsResult = {
  rollups: Record<WindowKey, UsageRollupDoc>;
  rebuiltCounters: boolean;
};

/**
 * Serves a client-initiated rollup refresh (the `rebuildUsageRollups`
 * callable) without unconditionally paying for a full counter rebuild.
 *
 * The full path ({@link computeUserRollups}) recursively deletes all three
 * counter collections and rescans the user's entire usage history, so it only
 * runs when the counters cannot be trusted: an explicit `force` (the clients'
 * repair entry point), a missing/unparseable job doc, or a recorded
 * incremental-delta failure (`lastErrorCode`) — the same fallback rule as the
 * scheduled `rebuildRollups` worker. Otherwise the incrementally maintained
 * counters already include every usage event (dirty merely means the rollup
 * docs lag the counters), so a counters-only recompute is sufficient.
 *
 * The recomputed rollups are ALWAYS written, even when nothing changed:
 * clients treat a stale `computedAt` as a rebuild signal, so serving without
 * refreshing it would put an open dashboard into a callable polling loop.
 */
export async function refreshUserRollups(
  db: Firestore,
  uid: string,
  options: { force?: boolean; gate?: Partial<FullRebuildGateOptions>; drainMaxPages?: number } = {},
): Promise<RefreshUserRollupsResult> {
  const jobSnap = await db.doc(`users/${uid}/rollup_jobs/current`).get();
  const job = jobSnap.exists ? parseRollupJobDoc(jobSnap.data()) : undefined;
  const rebuiltCounters = options.force === true || job == null || job.lastErrorCode != null;
  let rollups: Record<WindowKey, UsageRollupDoc>;
  if (rebuiltCounters) {
    // Every full-rebuild entry point — explicit `force` repair included —
    // goes through the attempt gate: it enforces the circuit breaker the
    // scheduled worker honors (the callable used to bypass it entirely),
    // dedupes concurrent rebuilds via the in-flight marker, and rate-limits
    // force repairs per user. A rebuild killed mid-flight here is counted by
    // the next pass through the stale marker, exactly like the worker's.
    const cfg = getConfig();
    const gateOptions = {
      ...fullRebuildGateOptionsFromConfig(),
      forceMinIntervalMillis: options.force === true ? cfg.rollupForceRebuildMinIntervalMinutes * 60 * 1000 : undefined,
      ...options.gate,
    };
    const gate = await beginFullRebuildAttempt(db, uid, gateOptions);
    if (gate.status === "circuit_open") {
      throw new RollupRebuildUnavailableError("circuit_open", gate.openUntil);
    }
    if (gate.status === "in_flight") {
      throw new RollupRebuildUnavailableError("in_flight");
    }
    if (gate.status === "force_cooldown") {
      throw new RollupRebuildUnavailableError("force_cooldown", gate.retryAt);
    }
    try {
      rollups = await computeUserRollups(db, uid);
      await writeUserRollups(db, uid, rollups, job?.dirtiedAt, { clearFullRebuildAttempt: true });
    } catch (err) {
      // In-process failure bookkeeping, mirroring the scheduled worker's
      // catch: record the failure (advancing the consecutive counter /
      // breaker) and clear this attempt's in-flight marker NOW. Without
      // this, the marker dangles until it goes stale — every retry inside
      // that window is refused as "in_flight" with nothing running, and the
      // failure itself goes uncounted until the stale-marker pass.
      await recordRollupRebuildFailure(db, uid, errorMessage(err), gateOptions).catch(() => undefined);
      throw err;
    }
  } else {
    // Fold queued trigger deltas into the counters first so the served
    // rollups include every event enqueued up to this point. A drain failure
    // propagates: the dirty flag survives and the scheduled worker (whose
    // catch records `lastErrorCode`) repairs via the full-rebuild path.
    const drain = await drainPendingCounterDeltas(db, uid, {
      maxPages: options.drainMaxPages ?? getConfig().rollupPendingDeltaDrainMaxPages,
    });
    rollups = await computeUserRollupsFromCounters(db, uid);
    await writeUserRollups(db, uid, rollups, job?.dirtiedAt, { keepDirty: drain.capped });
  }
  return { rollups, rebuiltCounters };
}

export async function writeUserRollups(
  db: Firestore,
  uid: string,
  rollups: Record<WindowKey, UsageRollupDoc>,
  observedDirtiedAt: string | undefined,
  options: { keepDirty?: boolean; clearFullRebuildAttempt?: boolean } = {},
): Promise<void> {
  const batch = db.batch();

  for (const key of WINDOW_KEYS) {
    const ref = db.doc(`users/${uid}/usage_rollups/${key}`);
    batch.set(ref, stripUndefinedDocument(rollups[key]), { merge: true });
  }

  await batch.commit();

  // Clear the dirty flag transactionally, and only when `dirtiedAt` still
  // matches the value the caller observed at compute start. Every usage event
  // refreshes `dirtiedAt` (see onUsageWritten), so a mismatch means an event
  // landed mid-compute and the rollups just written may not include it: leave
  // the job dirty so the next worker pass recomputes instead of silently
  // dropping the event. Error/breaker state is cleared only when this same
  // dirty epoch was covered; a newer dirty epoch may have recorded its own
  // failure and must survive so the next worker pass takes the repair path.
  //
  // `keepDirty`: a capped delta drain left queue docs behind — clearing dirty
  // would orphan them until the next usage event, so the job stays dirty for
  // the next tick. `clearFullRebuildAttempt`: only the caller that ran the
  // full rebuild clears its own in-flight marker; clearing unconditionally
  // would let a racing cheap-path write erase another invocation's marker and
  // hide its kill from the breaker (see beginFullRebuildAttempt).
  const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
  await db.runTransaction(async (transaction) => {
    const snap = await transaction.get(jobRef);
    const job = snap.exists ? parseRollupJobDoc(snap.data()) : undefined;
    const lastComputedAt = new Date().toISOString();
    const attemptPatch = options.clearFullRebuildAttempt ? { fullRebuildAttemptInFlightAt: FieldValue.delete() } : {};
    const successPatch = {
      lastComputedAt,
      lastErrorCode: FieldValue.delete(),
      consecutiveFullRebuildFailures: FieldValue.delete(),
      fullRebuildCircuitOpenUntil: FieldValue.delete(),
    };
    if (!options.keepDirty && job?.dirtiedAt === observedDirtiedAt) {
      transaction.set(jobRef, { dirty: false, ...successPatch, ...attemptPatch }, { merge: true });
    } else {
      transaction.set(jobRef, { lastComputedAt, ...attemptPatch }, { merge: true });
    }
  });
}
