/**
 * @fileoverview Pending-delta queue for the usage counter pipeline (crosscut-011).
 *
 * `onUsageWritten` used to apply counter deltas synchronously: every usage
 * event ran a transaction of up to 11-21 sets that write-locked the SAME
 * day/all_time bucket docs (and their provider/account/model/device subdocs)
 * for the user. Session-end sync bursts land up to 400 events near-
 * simultaneously, so those transactions serialized on ~10 shared docs,
 * exhausted admin-SDK retries, recorded `lastErrorCode`, and forced the next
 * scheduled pass into a destructive full rebuild.
 *
 * The queue model makes the trigger contention-free: each event appends ONE
 * immutable `users/{uid}/pending_counter_deltas/{id}` doc (its own doc — no
 * shared locks) carrying full winner-resolution candidate data for the
 * before/after states. The 5-minute worker (and the refresh callable) drains
 * the queue in pages: one transaction per page replays the transitions
 * against the `usage_counter_keys` winner state and applies COALESCED bucket
 * increments — one set per bucket doc per page instead of per event. Client-
 * visible freshness is unchanged (clients read `usage_rollups`, written on
 * the same 5-minute cadence), and exactly-once accounting is preserved by
 * the same candidates/winner state machine: replaying an already-applied
 * transition leaves the winner unchanged and emits zero increments.
 *
 * `applyUsageCounterDelta` (rollupCounters.ts) remains the single-event
 * reference implementation of the transition semantics (and the repair-path
 * building block); the planner below MUST stay behaviorally equivalent to
 * running it once per delta in enqueue order.
 */

import { randomUUID } from "node:crypto";
import { type Firestore } from "firebase-admin/firestore";
import type { UsageEventDoc } from "./types.js";
import { isRecord, recordOrUndefined } from "./guards.js";
import { logInfo } from "./logging.js";
import { flushDomainCorePricingShadowEvidence } from "./pricing.js";
import {
  COUNTER_SCHEMA_VERSION,
  addContribution,
  isUsageCounterCandidate,
  sameCounterCandidate,
  selectCounterWinner,
  stableCounterKey,
  stripUndefinedDocument,
  usageContribution,
  type UsageCounterCandidate,
  type UsageCounterContribution,
} from "./rollupCounters.js";

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
 * Sort key used by both the immutable queue doc ID and the pure drain planner.
 * A usage document's update chain must be replayed by semantic candidate
 * version, not by whichever Cloud Function instance happened to enqueue first.
 * Deletes are ordered after creates/updates at the same semantic version so a
 * final delete cannot be undone by its own preceding state.
 */
let lastPendingCounterDeltaEnqueuedAt = "";
let lastPendingCounterDeltaSequence = 0;

function pendingCounterDeltaSortTuple(delta: PendingCounterDelta): readonly [string, number, number] {
  const transitionMillis = Math.max(
    delta.before?.updatedMillis ?? Number.NEGATIVE_INFINITY,
    delta.after?.updatedMillis ?? Number.NEGATIVE_INFINITY,
  );
  return [
    delta.candidateKey,
    Number.isFinite(transitionMillis) ? transitionMillis : Date.parse(delta.enqueuedAt) || 0,
    delta.after === undefined ? 1 : 0,
  ];
}

function comparePendingCounterDeltas(lhs: PendingCounterDelta, rhs: PendingCounterDelta): number {
  const [leftCandidateKey, leftTransitionMillis, leftTransitionPhase] = pendingCounterDeltaSortTuple(lhs);
  const [rightCandidateKey, rightTransitionMillis, rightTransitionPhase] = pendingCounterDeltaSortTuple(rhs);
  if (leftCandidateKey !== rightCandidateKey) return leftCandidateKey < rightCandidateKey ? -1 : 1;
  if (leftTransitionMillis !== rightTransitionMillis) return leftTransitionMillis - rightTransitionMillis;
  if (leftTransitionPhase !== rightTransitionPhase) return leftTransitionPhase - rightTransitionPhase;
  if (lhs.enqueuedAt !== rhs.enqueuedAt) return lhs.enqueuedAt < rhs.enqueuedAt ? -1 : 1;
  if (lhs.usageDoc !== rhs.usageDoc) return lhs.usageDoc < rhs.usageDoc ? -1 : 1;
  return 0;
}

function orderedPendingCounterDeltas(deltas: readonly PendingCounterDelta[]): PendingCounterDelta[] {
  return [...deltas].sort(comparePendingCounterDeltas);
}

/**
 * Semantic-order doc ID: the queue is drained in implicit `__name__` order, so
 * the prefix mirrors `comparePendingCounterDeltas`. This keeps a single usage
 * document's update chain ordered even when different trigger instances enqueue
 * transitions in a different wall-clock order. A per-instance sequence plus
 * random suffix keeps IDs collision-free within identical enqueue timestamps.
 */
export function pendingCounterDeltaDocID(enqueuedAt: string, delta?: PendingCounterDelta): string {
  if (enqueuedAt === lastPendingCounterDeltaEnqueuedAt) {
    lastPendingCounterDeltaSequence += 1;
  } else {
    lastPendingCounterDeltaEnqueuedAt = enqueuedAt;
    lastPendingCounterDeltaSequence = 0;
  }

  const sequence = lastPendingCounterDeltaSequence.toString(36).padStart(8, "0");
  if (!delta) {
    return `${enqueuedAt}_${sequence}_${randomUUID()}`;
  }

  const [candidateKey, transitionMillis, transitionPhase] = pendingCounterDeltaSortTuple(delta);
  const semanticMillis = transitionMillis.toString().padStart(13, "0");
  return `v1_${candidateKey}_${semanticMillis}_${transitionPhase}_${enqueuedAt}_${sequence}_${randomUUID()}`;
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
  let delta: PendingCounterDelta | undefined;
  try {
    delta = buildPendingCounterDelta(usageDoc, before, after, enqueuedAt);
  } finally {
    await flushDomainCorePricingShadowEvidence();
  }
  if (!delta) return false;
  const ref = db.collection(`users/${uid}/pending_counter_deltas`).doc(pendingCounterDeltaDocID(enqueuedAt, delta));
  await ref.set(stripUndefinedDocument(delta), { merge: false });
  return true;
}

type PendingDeltaKeyWrite = {
  logicalKey: string;
  candidates: Record<string, UsageCounterCandidate>;
  winner?: UsageCounterCandidate;
};

type PendingDeltaDrainPlan = {
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
    contribution.executionSourceId ?? "",
    contribution.executionSourceName ?? "",
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
        executionSourceId: contribution.executionSourceId,
        executionSourceName: contribution.executionSourceName,
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

  for (const delta of orderedPendingCounterDeltas(deltas)) {
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

type DrainPendingCounterDeltasResult = {
  drainedDocs: number;
  pages: number;
  /** True when the page cap stopped the drain with queue docs likely remaining. */
  capped: boolean;
};

/** Collects the distinct logical keys touched by a page of deltas, in order. */
function pageLogicalKeys(deltas: readonly PendingCounterDelta[]): string[] {
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
  return logicalKeys;
}

/** Reads the transactional candidate state for each logical key on a page. */
async function readPageKeyStates(
  db: Firestore,
  uid: string,
  logicalKeys: readonly string[],
  transaction: FirebaseFirestore.Transaction,
): Promise<Map<string, Record<string, UsageCounterCandidate>>> {
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
  return states;
}

/** Applies a page's plan: coalesced bucket increments, key-state writes, and
 * queue-doc deletes — exactly the per-page transaction body. */
function commitPagePlan(
  db: Firestore,
  uid: string,
  transaction: FirebaseFirestore.Transaction,
  deltas: readonly PendingCounterDelta[],
  states: Map<string, Record<string, UsageCounterCandidate>>,
  pageDocs: ReadonlyArray<{ ref: FirebaseFirestore.DocumentReference }>,
  now: string,
): void {
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
  for (const doc of pageDocs) {
    transaction.delete(doc.ref);
  }
}

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
    // No orderBy: implicit __name__ ordering plus semantic doc IDs (see
    // pendingCounterDeltaDocID) keeps same-usage-doc transitions ordered with
    // no composite index needs.
    const page = await db.collection(queuePath).limit(PENDING_DELTA_DRAIN_PAGE_SIZE).get();
    if (page.docs.length === 0) break;
    pages += 1;

    const deltas: PendingCounterDelta[] = [];
    for (const doc of page.docs) {
      const data = doc.data();
      if (isPendingCounterDelta(data)) deltas.push(data);
    }

    const logicalKeys = pageLogicalKeys(deltas);

    const now = new Date().toISOString();
    await db.runTransaction(async (transaction) => {
      const states = await readPageKeyStates(db, uid, logicalKeys, transaction);
      commitPagePlan(db, uid, transaction, deltas, states, page.docs, now);
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
