/**
 * @fileoverview Counters -> usage_rollups computation and the destructive
 * full-rebuild repair path.
 *
 * The scheduled path reads only counter documents; raw usage scans are
 * reserved for explicit repair/backfill (`rebuildUserRollupCounters`). The
 * day-keyed windows nest (today ⊂ 7d ⊂ 30d ⊂ 90d), so the 90-day union is
 * fetched once and every window aggregated in memory.
 */

import { FieldPath, type DocumentData, type Firestore } from "firebase-admin/firestore";
import type { UsageRollupDoc } from "@openburnbar/functions-shared/types.js";
import { recordOrUndefined } from "@openburnbar/functions-shared/guards.js";
import {
  aggregateAccountSummaries,
  aggregateComboSummaries,
  aggregateDeviceSummaries,
  aggregateExecutionSourceSummaries,
  aggregateModelSummaries,
  aggregateProviderSummaries,
  sumNumber,
} from "./rollupAggregates.js";
import { parseUsageEventDoc } from "./usageEventParse.js";
import { logError, logInfo } from "@openburnbar/functions-shared/logging.js";
import { flushDomainCorePricingShadowEvidence } from "@openburnbar/functions-shared/pricing.js";
import {
  ALL_TIME_DAILY_SHARD_PREFIX,
  COUNTER_SCHEMA_VERSION,
  ROLLUP_SCHEMA_VERSION,
  WINDOW_KEYS,
  addContribution,
  allTimeDailyShardID,
  counterShardMonth,
  requireWindowRollups,
  selectCounterWinner,
  stableCounterKey,
  stripUndefinedDocument,
  toUtcDate,
  usageContribution,
  type UsageCounterCandidate,
  type WindowKey,
} from "./rollupCounters.js";

async function queryCounterDocs(
  db: Firestore,
  collection: string,
  bucketPaths: string[],
): Promise<FirebaseFirestore.DocumentData[]> {
  const snapshots = await Promise.all(bucketPaths.map((path) => db.collection(`${path}/${collection}`).get()));
  return snapshots.flatMap((snapshot) => snapshot.docs.map((doc) => doc.data()));
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
  executionSources: DocumentData[];
  combos: DocumentData[];
};

async function fetchCounterBucketDocs(db: Firestore, bucketPaths: string[]): Promise<CounterBucketDocs> {
  const [providers, accounts, models, devices, executionSources, combos] = await Promise.all([
    queryCounterDocs(db, "providers", bucketPaths),
    queryCounterDocs(db, "accounts", bucketPaths),
    queryCounterDocs(db, "models", bucketPaths),
    queryCounterDocs(db, "devices", bucketPaths),
    queryCounterDocs(db, "executionSources", bucketPaths),
    queryCounterDocs(db, "combos", bucketPaths),
  ]);
  return { providers, accounts, models, devices, executionSources, combos };
}

/**
 * Monthly all_time daily-map shards for one user (Wave 2.6), oldest first.
 * One doc per active month — bounded by account age in months, a trivially
 * small collection scan next to the per-day scans it replaces.
 */
async function fetchAllTimeDailyShards(db: Firestore, uid: string): Promise<DocumentData[]> {
  const snap = await db.collection(`users/${uid}/usage_counter_totals`).get();
  return snap.docs
    .filter((doc) => doc.id.startsWith(ALL_TIME_DAILY_SHARD_PREFIX))
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
    .map((doc) => doc.data() ?? {});
}

/**
 * Returns the `[day, tokens]` series backing the all_time `dailyPoints` map.
 *
 * `addContribution` maintains the rolling `dailyTokens` map in monthly
 * `all_time_daily_YYYY-MM` shards so this read stays O(months) instead of an
 * unbounded scan of `usage_counter_days` (day docs past retention are reaped,
 * so that scan is bounded too — but it no longer carries full history). The
 * map frozen on the pre-shard `all_time` doc is merged as legacy: a day can
 * appear on BOTH sides (legacy partial + later shard increments), so overlap
 * SUMS rather than overwriting.
 *
 * Totals docs written before any map existed fall back to one legacy day-doc
 * scan, and the derived entries are persisted into the monthly shards (never
 * the base doc) so the next compute reads incrementally. The persist is
 * skipped when `updatedAt` moved between the caller's totals read and the
 * transaction — a counter write landed mid-scan and an absolute write could
 * overwrite its increment; the next worker pass retries the backfill. Only
 * days absent from the target shard are filled, so live increments already
 * in a shard are never disturbed.
 */
async function allTimeDailyTokenEntries(
  db: Firestore,
  uid: string,
  allTimeData: DocumentData | undefined,
): Promise<(readonly [string, number])[]> {
  const shards = await fetchAllTimeDailyShards(db, uid);
  const merged = new Map<string, number>();
  const legacy = recordOrUndefined(allTimeData?.dailyTokens);
  if (legacy) {
    for (const [day, tokens] of Object.entries(legacy)) merged.set(day, sumNumber(tokens));
  }
  for (const shard of shards) {
    const map = recordOrUndefined(shard.dailyTokens);
    if (!map) continue;
    for (const [day, tokens] of Object.entries(map)) merged.set(day, (merged.get(day) ?? 0) + sumNumber(tokens));
  }
  if (merged.size > 0 || !allTimeData) {
    return [...merged.entries()]
      .map(([day, tokens]) => [day, tokens] as const)
      .sort(([dayA], [dayB]) => (dayA < dayB ? -1 : dayA > dayB ? 1 : 0));
  }

  const scannedDays = (await db.collection(`users/${uid}/usage_counter_days`).get()).docs.map(
    (doc) => doc.data() ?? {},
  );
  const entries = scannedDays.map((doc) => [String(doc.day), sumNumber(doc.tokens)] as const);

  // No map anywhere (pre-map totals doc): backfill the monthly shards. Note
  // the scan only sees day docs inside retention now — history older than
  // the counter TTL is intentionally truncated to the retained window.
  await backfillDailyTokenShards(db, uid, entries, allTimeData.updatedAt);

  return entries;
}

/**
 * Persists scanned `[day, tokens]` entries into their monthly shards,
 * filling only days absent from each shard. Best-effort: any concurrent
 * counter write (observed via the base doc's `updatedAt`) aborts the persist
 * and the next worker pass retries. Chunked so no transaction exceeds the
 * Firestore write limit no matter the account age.
 */
async function backfillDailyTokenShards(
  db: Firestore,
  uid: string,
  entries: (readonly [string, number])[],
  observedUpdatedAt: unknown,
): Promise<void> {
  const byMonth = new Map<string, (readonly [string, number])[]>();
  for (const entry of entries) {
    const month = counterShardMonth(entry[0]);
    const group = byMonth.get(month) ?? [];
    group.push(entry);
    byMonth.set(month, group);
  }
  const months = [...byMonth.keys()].sort();
  const allTimeRef = db.doc(`users/${uid}/usage_counter_totals/all_time`);
  for (let offset = 0; offset < months.length; offset += 100) {
    const page = months.slice(offset, offset + 100);
    await db.runTransaction(async (transaction) => {
      const baseSnap = await transaction.get(allTimeRef);
      const baseData = baseSnap.exists ? (baseSnap.data() ?? {}) : undefined;
      // A counter write landed mid-scan, or a racing pass already built a
      // map: abort this page; the next worker pass retries the remainder.
      if (!baseData || baseData.updatedAt !== observedUpdatedAt) return;
      if (recordOrUndefined(baseData.dailyTokens)) return;
      const shardSnaps = await Promise.all(
        page.map((month) => transaction.get(db.doc(`users/${uid}/usage_counter_totals/${allTimeDailyShardID(month)}`))),
      );
      for (let i = 0; i < page.length; i++) {
        const month = page[i];
        const existing = recordOrUndefined(shardSnaps[i].exists ? (shardSnaps[i].data() ?? {}) : undefined);
        const existingMap = recordOrUndefined(existing?.dailyTokens) ?? {};
        const fill: Record<string, number> = {};
        for (const [day, tokens] of byMonth.get(month) ?? []) {
          if (!(day in existingMap)) fill[day] = tokens;
        }
        if (Object.keys(fill).length === 0) continue;
        transaction.set(
          db.doc(`users/${uid}/usage_counter_totals/${allTimeDailyShardID(month)}`),
          {
            windowKey: "all_time",
            shardMonth: month,
            dailyTokens: fill,
            updatedAt: new Date().toISOString(),
            schemaVersion: COUNTER_SCHEMA_VERSION,
          },
          { merge: true },
        );
      }
    });
  }
}

/**
 * Returns the `day -> providerID -> tokens` map backing the all_time
 * `dailyProviderTokens` field.
 *
 * `addContribution` maintains the rolling nested map in the monthly
 * `all_time_daily_YYYY-MM` shards right beside `dailyTokens` (same
 * merge-write increment semantics, one level deeper). The frozen legacy map
 * on the pre-shard `all_time` doc merges underneath; overlap SUMS per
 * provider (see `allTimeDailyTokenEntries`). Totals docs written before any
 * map existed fall back to one legacy scan of each retained day doc's
 * `providers` subcollection, persisted into the shards under the same
 * updatedAt-moved guard — an in-flight counter increment is never
 * overwritten by the scan's absolute values; the next worker pass retries.
 */
async function allTimeDailyProviderTokenEntries(
  db: Firestore,
  uid: string,
  allTimeData: DocumentData | undefined,
): Promise<Record<string, Record<string, number>>> {
  const shards = await fetchAllTimeDailyShards(db, uid);
  const merged = new Map<string, Map<string, number>>();
  const absorb = (day: string, providerID: string, tokens: number) => {
    const providers = merged.get(day) ?? new Map<string, number>();
    providers.set(providerID, (providers.get(providerID) ?? 0) + tokens);
    merged.set(day, providers);
  };
  const absorbMap = (map: Record<string, unknown> | undefined) => {
    if (!map) return;
    for (const [day, providers] of Object.entries(map)) {
      for (const [providerID, tokens] of Object.entries(recordOrUndefined(providers) ?? {})) {
        absorb(day, providerID, sumNumber(tokens));
      }
    }
  };
  absorbMap(recordOrUndefined(allTimeData?.dailyProviderTokens));
  for (const shard of shards) absorbMap(recordOrUndefined(shard.dailyProviderTokens));
  if (merged.size > 0 || !allTimeData) {
    return Object.fromEntries(
      [...merged.entries()].map(([day, providers]) => [day, Object.fromEntries(providers)]),
    );
  }

  const dayDocs = (await db.collection(`users/${uid}/usage_counter_days`).get()).docs;
  // Bound the fan-out. One provider-subcollection query per retained day, all
  // launched at once, means a heavy account issues hundreds of concurrent
  // Firestore reads during a routine compute — exhausting the function's
  // sockets/memory or timing out the rebuild on exactly the long-lived
  // accounts this backfill exists to migrate. Retention bounds the scan now,
  // but the cap stays as defense in depth.
  const BACKFILL_QUERY_CONCURRENCY = 25;
  const providerDocsByDay: { day: string; providers: FirebaseFirestore.DocumentData[] }[] = [];
  for (let offset = 0; offset < dayDocs.length; offset += BACKFILL_QUERY_CONCURRENCY) {
    const page = dayDocs.slice(offset, offset + BACKFILL_QUERY_CONCURRENCY);
    const resolved = await Promise.all(
      page.map(async (doc) => ({
        day: doc.id,
        providers: (await db.collection(`users/${uid}/usage_counter_days/${doc.id}/providers`).get()).docs.map(
          (providerDoc) => providerDoc.data() ?? {},
        ),
      })),
    );
    providerDocsByDay.push(...resolved);
  }
  const entries: Record<string, Record<string, number>> = {};
  for (const { day, providers } of providerDocsByDay) {
    const dayProviders: Record<string, number> = {};
    for (const providerDoc of providers) {
      const providerID =
        typeof providerDoc.providerID === "string"
          ? providerDoc.providerID
          : typeof providerDoc.provider === "string"
            ? providerDoc.provider
            : undefined;
      if (!providerID) continue;
      dayProviders[providerID] = (dayProviders[providerID] ?? 0) + sumNumber(providerDoc.tokens);
    }
    entries[day] = dayProviders;
  }

  // No map anywhere (pre-map totals doc): backfill the monthly shards. The
  // scan only sees retained day docs — provider history older than the
  // counter TTL is intentionally truncated to the retained window.
  await backfillDailyProviderTokenShards(db, uid, entries, allTimeData.updatedAt);

  return entries;
}

/**
 * Persists scanned `day -> providerID -> tokens` entries into their monthly
 * shards, filling only days absent from each shard. Same best-effort guard
 * and chunking as `backfillDailyTokenShards`.
 */
async function backfillDailyProviderTokenShards(
  db: Firestore,
  uid: string,
  entries: Record<string, Record<string, number>>,
  observedUpdatedAt: unknown,
): Promise<void> {
  const byMonth = new Map<string, Record<string, Record<string, number>>>();
  for (const [day, providers] of Object.entries(entries)) {
    const month = counterShardMonth(day);
    const group = byMonth.get(month) ?? {};
    group[day] = providers;
    byMonth.set(month, group);
  }
  const months = [...byMonth.keys()].sort();
  const allTimeRef = db.doc(`users/${uid}/usage_counter_totals/all_time`);
  for (let offset = 0; offset < months.length; offset += 100) {
    const page = months.slice(offset, offset + 100);
    await db.runTransaction(async (transaction) => {
      const baseSnap = await transaction.get(allTimeRef);
      const baseData = baseSnap.exists ? (baseSnap.data() ?? {}) : undefined;
      if (!baseData || baseData.updatedAt !== observedUpdatedAt) return;
      if (recordOrUndefined(baseData.dailyProviderTokens)) return;
      const shardSnaps = await Promise.all(
        page.map((month) => transaction.get(db.doc(`users/${uid}/usage_counter_totals/${allTimeDailyShardID(month)}`))),
      );
      for (let i = 0; i < page.length; i++) {
        const month = page[i];
        const existing = recordOrUndefined(shardSnaps[i].exists ? (shardSnaps[i].data() ?? {}) : undefined);
        const existingMap = recordOrUndefined(existing?.dailyProviderTokens) ?? {};
        const fill: Record<string, Record<string, number>> = {};
        for (const [day, providers] of Object.entries(byMonth.get(month) ?? {})) {
          if (!(day in existingMap)) fill[day] = providers;
        }
        if (Object.keys(fill).length === 0) continue;
        transaction.set(
          db.doc(`users/${uid}/usage_counter_totals/${allTimeDailyShardID(month)}`),
          {
            windowKey: "all_time",
            shardMonth: month,
            dailyProviderTokens: fill,
            updatedAt: new Date().toISOString(),
            schemaVersion: COUNTER_SCHEMA_VERSION,
          },
          { merge: true },
        );
      }
    });
  }
}

type WindowCounterSlice = {
  bucketDocs: DocumentData[];
  counterDocs: CounterBucketDocs;
  dailyPointEntries: (readonly [string, number])[];
  dailyProviderTokens?: Record<string, Record<string, number>>;
};

type DayBucket = { id: string; data: DocumentData } & CounterBucketDocs;

type AllTimeSlice = {
  data: DocumentData | undefined;
  docs: CounterBucketDocs;
  dailyEntries: (readonly [string, number])[];
  dailyProviderTokens: Record<string, Record<string, number>>;
};

/**
 * Selects the bucket/counter docs and daily-point entries for one window from
 * the once-fetched 90-day union and all_time totals. Preserves the original
 * per-window iteration order (windows are prefixes of the newest-first union).
 */
function selectWindowCounters(
  key: WindowKey,
  now: Date,
  dayBuckets: DayBucket[],
  allTime: AllTimeSlice,
): WindowCounterSlice {
  if (key === "all_time") {
    return {
      bucketDocs: allTime.data ? [allTime.data] : [],
      counterDocs: allTime.docs,
      dailyPointEntries: allTime.dailyEntries,
      dailyProviderTokens: allTime.dailyProviderTokens,
    };
  }

  const windowSet = new Set(windowDays(key, now) ?? []);
  const windowBuckets = dayBuckets.filter((bucket) => windowSet.has(bucket.id));
  const bucketDocs = windowBuckets.map((bucket) => bucket.data);
  return {
    bucketDocs,
    counterDocs: {
      providers: windowBuckets.flatMap((bucket) => bucket.providers),
      accounts: windowBuckets.flatMap((bucket) => bucket.accounts),
      models: windowBuckets.flatMap((bucket) => bucket.models),
      devices: windowBuckets.flatMap((bucket) => bucket.devices),
      executionSources: windowBuckets.flatMap((bucket) => bucket.executionSources),
      combos: windowBuckets.flatMap((bucket) => bucket.combos),
    },
    dailyPointEntries: bucketDocs.map((doc) => [String(doc.day), sumNumber(doc.tokens)] as const),
  };
}

function sumBucketTotals(bucketDocs: DocumentData[]): { requests: number; tokens: number; costUsd: number } {
  return bucketDocs.reduce<{ requests: number; tokens: number; costUsd: number }>(
    (acc, doc) => {
      acc.requests += sumNumber(doc.requests);
      acc.tokens += sumNumber(doc.tokens);
      acc.costUsd += sumNumber(doc.costUsd);
      return acc;
    },
    { requests: 0, tokens: 0, costUsd: 0 },
  );
}

/** Builds one window's rollup doc from its selected counter slice. */
function buildWindowRollupDoc(key: WindowKey, slice: WindowCounterSlice, now: Date): UsageRollupDoc {
  const { providers, accounts, models, devices, executionSources, combos } = slice.counterDocs;
  const totals = sumBucketTotals(slice.bucketDocs);
  const dailyPoints = Object.fromEntries(slice.dailyPointEntries.filter(([day, tokens]) => day && tokens !== 0));

  // Zero-token provider entries (and days left empty by them) are omitted,
  // mirroring the dailyPoints zero filter; the field itself is omitted when
  // nothing remains.
  const dailyProviderTokens = Object.fromEntries(
    Object.entries(slice.dailyProviderTokens ?? {})
      .map(
        ([day, providers]) =>
          [day, Object.fromEntries(Object.entries(providers).filter(([, tokens]) => tokens !== 0))] as const,
      )
      .filter(([day, providers]) => day && Object.keys(providers).length > 0),
  );

  return {
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
    providerSummaries: aggregateProviderSummaries(providers),
    accountSummaries: aggregateAccountSummaries(accounts),
    modelSummaries: aggregateModelSummaries(models),
    deviceSummaries: aggregateDeviceSummaries(devices),
    executionSourceSummaries: aggregateExecutionSourceSummaries(executionSources),
    comboSummaries: aggregateComboSummaries(combos),
    dailyPoints,
    ...(Object.keys(dailyProviderTokens).length > 0 ? { dailyProviderTokens } : {}),
    computedAt: now.toISOString(),
    schemaVersion: ROLLUP_SCHEMA_VERSION,
  };
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
  const allTimeDailyProviderTokens = await allTimeDailyProviderTokenEntries(db, uid, allTimeData);
  const allTime: AllTimeSlice = {
    data: allTimeData,
    docs: allTimeDocs,
    dailyEntries: allTimeDailyEntries,
    dailyProviderTokens: allTimeDailyProviderTokens,
  };

  for (const key of WINDOW_KEYS) {
    const slice = selectWindowCounters(key, now, dayBuckets, allTime);
    results[key] = buildWindowRollupDoc(key, slice, now);
  }

  return requireWindowRollups(results);
}

type RebuildUserRollupCountersResult = {
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
  // mid-scan survive the purge. Cheap drains refuse to run while the
  // in-flight marker is fresh, so those surviving docs are not applied onto
  // counters this rebuild is about to delete.
  //
  // The counter collections are deleted only AFTER the scan below produces
  // countable winners (see the zero-parse guard). Deleting first turned a
  // total parse failure into a silent wipe: on 2026-09-19 a strict provider
  // allowlist rejected 100% of a real account's raw usage docs and the
  // "successful" rebuild replaced 163 days of counters with zeros.
  await db.recursiveDelete(db.collection(`users/${uid}/pending_counter_deltas`));

  const candidatesByLogicalKey = new Map<string, Record<string, UsageCounterCandidate>>();
  const usageRef = db.collection(`users/${uid}/usage`);
  const pageSize = Math.max(1, Math.floor(options.pageSize ?? Number(process.env.ROLLUP_REPAIR_PAGE_SIZE ?? 500)));
  let usageDocsScanned = 0;
  let countableDocs = 0;
  let pages = 0;
  let lastDoc: FirebaseFirestore.QueryDocumentSnapshot | undefined;

  try {
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
        countableDocs += 1;
        const candidates = candidatesByLogicalKey.get(contribution.logicalKey) ?? {};
        candidates[contribution.candidateKey] = contribution;
        candidatesByLogicalKey.set(contribution.logicalKey, candidates);
      }

      lastDoc = snapshot.docs.at(-1);
      if (snapshot.docs.length < pageSize || !lastDoc) break;
    }
  } finally {
    await flushDomainCorePricingShadowEvidence();
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

  // Zero-parse guard: raw history exists but nothing counted. Wiping the
  // counters here would destroy the account's rollups while reporting
  // success, so fail loudly with the counters intact. The caller's catch
  // records the failure against the circuit breaker like any repair failure,
  // and the surviving pending-delta purge is harmless: the queued events'
  // raw docs are still present for the next successful rescan to cover.
  if (usageDocsScanned > 0 && countableDocs === 0) {
    logError({
      event: "rollup.rescan_zero_parsed",
      uid,
      usage_docs_scanned: usageDocsScanned,
      pages,
      error: `refusing to wipe counters: 0 countable contributions from ${usageDocsScanned} usage docs`,
    });
    throw new Error(
      `Refusing to rebuild usage counters for this user: scanned ${usageDocsScanned} usage docs but parsed 0 countable contributions. Counters left intact.`,
    );
  }

  // Partial-parse collapse: one accepted doc must not authorize deleting
  // counters built from thousands of rejected ones. Winner count is the
  // wrong signal (many events share a logical key); countable docs vs
  // scanned docs is the parser-coverage check.
  const RESCAN_MIN_DOCS_FOR_COVERAGE = 20;
  const RESCAN_MIN_COUNTABLE_RATIO = 0.1;
  if (
    usageDocsScanned >= RESCAN_MIN_DOCS_FOR_COVERAGE &&
    countableDocs < usageDocsScanned * RESCAN_MIN_COUNTABLE_RATIO
  ) {
    logError({
      event: "rollup.rescan_partial_parse",
      uid,
      usage_docs_scanned: usageDocsScanned,
      countable_docs: countableDocs,
      pages,
      error: `refusing to wipe counters: ${countableDocs} countable of ${usageDocsScanned} usage docs`,
    });
    throw new Error(
      `Refusing to rebuild usage counters for this user: scanned ${usageDocsScanned} usage docs but only ${countableDocs} countable contributions. Counters left intact.`,
    );
  }

  await Promise.all([
    db.recursiveDelete(db.collection(`users/${uid}/usage_counter_days`)),
    db.recursiveDelete(db.collection(`users/${uid}/usage_counter_totals`)),
    db.recursiveDelete(db.collection(`users/${uid}/usage_counter_keys`)),
  ]);

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

  logInfo({
    event: "rollup.rescan_completed",
    uid,
    usage_docs_scanned: usageDocsScanned,
    pages,
    winners_written: winners.length,
  });

  return {
    usageDocsScanned,
    pages,
    winnersWritten: winners.length,
  };
}
