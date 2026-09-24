/**
 * @fileoverview Day-bucket retention sweeper (Wave 2.6).
 *
 * `usage_counter_days/{day}` docs accumulate one per active day per user
 * forever; rollup compute only ever reads the trailing 90-day union, so
 * everything older than `COUNTER_DAY_RETENTION_DAYS` is dead weight. This
 * daily job pages the `usage_counter_days` collection group for expired day
 * docs and `recursiveDelete`s each one — recursion matters because the
 * per-day `providers`/`accounts`/`models`/… subcollections would otherwise
 * survive as orphans (Firestore TTL deletes only the doc shell, which is why
 * TTL on `expireAt` is the backstop here, not the primary).
 *
 * Bounded per tick (batch × maxBatches × timeout); the next tick resumes.
 * Deleting a day doc never disturbs computed state: lifetime scalars live on
 * `all_time`, the daily series lives in the monthly shards, and windows
 * older than the union are served from `usage_rollups` snapshots.
 */
import { onSchedule } from "firebase-functions/v2/scheduler";
import type { DocumentData, Firestore, Query, QueryDocumentSnapshot } from "firebase-admin/firestore";

import { db } from "../adminRuntime.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { logInfo } from "../logging.js";
import { COUNTER_DAY_RETENTION_DAYS, toUtcDate } from "../rollupCounters.js";

const DAY_MS = 24 * 60 * 60 * 1000;
const DEFAULT_BATCH_SIZE = 100;
const DEFAULT_MAX_BATCHES = 10;
const DEFAULT_TIMEOUT_MS = 50_000;

export interface CounterDayReapOptions {
  nowMs?: number;
  batchSize?: number;
  maxBatches?: number;
  timeoutMs?: number;
}

export interface CounterDayReapResult {
  reaped: number;
  hasMore: boolean;
}

interface LoopBudget {
  batchSize: number;
  maxBatches: number;
  timeoutMs: number;
  startTime: number;
}

/** Day-key cutoff: docs with `day` strictly below this are expired. */
export function counterDayCutoff(nowMs: number): string {
  return toUtcDate(new Date(nowMs - COUNTER_DAY_RETENTION_DAYS * DAY_MS));
}

async function fetchExpiredDayPage(
  db: Firestore,
  cutoffDay: string,
  lastDoc: QueryDocumentSnapshot<DocumentData> | undefined,
  batchSize: number,
): Promise<QueryDocumentSnapshot<DocumentData>[]> {
  let query: Query<DocumentData> = db
    .collectionGroup("usage_counter_days")
    .where("day", "<", cutoffDay) as Query<DocumentData>;
  if (lastDoc) query = query.startAfter(lastDoc);
  const snapshot = await query.limit(batchSize).get();
  return snapshot.docs as QueryDocumentSnapshot<DocumentData>[];
}

export async function reapExpiredCounterDays(
  firestore: Firestore,
  options: CounterDayReapOptions = {},
): Promise<CounterDayReapResult> {
  const nowMs = options.nowMs ?? Date.now();
  const budget: LoopBudget = {
    batchSize: Math.max(1, options.batchSize ?? DEFAULT_BATCH_SIZE),
    maxBatches: Math.max(1, options.maxBatches ?? DEFAULT_MAX_BATCHES),
    timeoutMs: Math.max(1, options.timeoutMs ?? DEFAULT_TIMEOUT_MS),
    startTime: Date.now(),
  };
  const cutoffDay = counterDayCutoff(nowMs);

  let reaped = 0;
  let lastDoc: QueryDocumentSnapshot<DocumentData> | undefined;
  let exhausted = false;
  for (let batch = 0; batch < budget.maxBatches; batch++) {
    if (Date.now() - budget.startTime >= budget.timeoutMs) break;
    const docs = await fetchExpiredDayPage(firestore, cutoffDay, lastDoc, budget.batchSize);
    if (docs.length === 0) {
      exhausted = true;
      break;
    }
    for (const doc of docs) {
      // recursiveDelete removes the day doc AND its per-day subcollections
      // (providers/accounts/models/devices/…). A plain delete would orphan
      // the subcollections exactly like the TTL backstop does.
      await firestore.recursiveDelete(doc.ref);
      reaped += 1;
    }
    lastDoc = docs[docs.length - 1];
    if (docs.length < budget.batchSize) {
      exhausted = true;
      break;
    }
  }

  const hasMore = !exhausted;
  logInfo({ event: "counter_days_reaped", reaped, cutoffDay, hasMore });
  return { reaped, hasMore };
}

export const reapExpiredCounterDayBuckets = onSchedule(
  { schedule: "every 24 hours", region: FUNCTIONS_REGION, timeoutSeconds: 300, memory: "512MiB" },
  async () => {
    await reapExpiredCounterDays(db);
  },
);
