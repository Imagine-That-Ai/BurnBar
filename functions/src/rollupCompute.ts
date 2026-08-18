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
import type {
  UsageRollupDoc,
  ProviderSummary,
  ProviderAccountSummary,
  ModelSummary,
  DeviceSummary,
  ExecutionSourceSummary,
  ComboSummary,
} from "./types.js";
import { isProviderAccountStorageScope, parseProvider, parseUsageEventDoc, recordOrUndefined } from "./guards.js";
import { flushDomainCorePricingShadowEvidence } from "./pricing.js";
import {
  COUNTER_SCHEMA_VERSION,
  ROLLUP_SCHEMA_VERSION,
  WINDOW_KEYS,
  addContribution,
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

/**
 * Returns the `day -> providerID -> tokens` map backing the all_time
 * `dailyProviderTokens` field.
 *
 * `addContribution` maintains the rolling nested map on the all_time totals
 * doc right beside `dailyTokens` (same merge-write increment semantics, one
 * level deeper). Totals docs written before the map existed fall back to one
 * legacy scan of each day doc's `providers` subcollection, and the derived
 * map is persisted under the same updatedAt-moved guard `dailyTokens` uses —
 * an in-flight counter increment is never overwritten by the scan's absolute
 * values; the next worker pass retries the backfill.
 */
async function allTimeDailyProviderTokenEntries(
  db: Firestore,
  uid: string,
  allTimeData: DocumentData | undefined,
): Promise<Record<string, Record<string, number>>> {
  const dailyProviderTokens = recordOrUndefined(allTimeData?.dailyProviderTokens);
  if (dailyProviderTokens) {
    return Object.fromEntries(
      Object.entries(dailyProviderTokens).map(([day, providers]) => [
        day,
        Object.fromEntries(
          Object.entries(recordOrUndefined(providers) ?? {}).map(([providerID, tokens]) => [
            providerID,
            sumNumber(tokens),
          ]),
        ),
      ]),
    );
  }

  const dayDocs = (await db.collection(`users/${uid}/usage_counter_days`).get()).docs;
  // Bound the fan-out. One provider-subcollection query per lifetime day, all
  // launched at once, means a multi-year account issues thousands of concurrent
  // Firestore reads during a routine compute — exhausting the function's
  // sockets/memory or timing out the rebuild on exactly the long-lived accounts
  // this backfill exists to migrate.
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

  if (allTimeData) {
    const observedUpdatedAt = allTimeData.updatedAt;
    const allTimeRef = db.doc(`users/${uid}/usage_counter_totals/all_time`);
    await db.runTransaction(async (transaction) => {
      const snap = await transaction.get(allTimeRef);
      const data = snap.exists ? (snap.data() ?? {}) : undefined;
      if (!data || recordOrUndefined(data.dailyProviderTokens) || data.updatedAt !== observedUpdatedAt) return;
      transaction.set(allTimeRef, { dailyProviderTokens: entries }, { merge: true });
    });
  }

  return entries;
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

function aggregateProviderSummaries(providers: DocumentData[]): ProviderSummary[] {
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
  return Array.from(providerMap.values()).filter(
    (entry) => entry.totalRequests !== 0 || entry.totalTokens !== 0 || (entry.totalCost ?? 0) !== 0,
  );
}

function aggregateAccountSummaries(accounts: DocumentData[]): ProviderAccountSummary[] {
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
  return Array.from(accountMap.values()).filter(
    (entry) => entry.totalRequests !== 0 || entry.totalTokens !== 0 || (entry.totalCost ?? 0) !== 0,
  );
}

function aggregateModelSummaries(models: DocumentData[]): ModelSummary[] {
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
  return Array.from(modelMap.values()).filter(
    (entry) => entry.requests !== 0 || entry.tokens !== 0 || (entry.cost ?? 0) !== 0,
  );
}

function aggregateDeviceSummaries(devices: DocumentData[]): DeviceSummary[] {
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
  return Array.from(deviceMap.values()).filter((entry) => entry.requests !== 0 || entry.tokens !== 0);
}

export function aggregateExecutionSourceSummaries(executionSources: DocumentData[]): ExecutionSourceSummary[] {
  const sourceMap = new Map<string, ExecutionSourceSummary>();
  for (const doc of executionSources) {
    const sourceId = typeof doc.executionSourceId === "string" ? doc.executionSourceId : "";
    if (!sourceId) continue;
    const sourceName = typeof doc.executionSourceName === "string" ? doc.executionSourceName : "";
    const existing = sourceMap.get(sourceId);
    if (existing) {
      if (!existing.sourceName && sourceName) existing.sourceName = sourceName;
      existing.totalRequests += sumNumber(doc.requests);
      existing.totalTokens += sumNumber(doc.tokens);
      existing.totalCost += sumNumber(doc.costUsd);
    } else {
      sourceMap.set(sourceId, {
        sourceId,
        sourceName,
        totalRequests: sumNumber(doc.requests),
        totalTokens: sumNumber(doc.tokens),
        totalCost: sumNumber(doc.costUsd),
      });
    }
  }
  return Array.from(sourceMap.values())
    .filter((entry) => entry.totalRequests !== 0 || entry.totalTokens !== 0 || entry.totalCost !== 0)
    .sort((a, b) => b.totalTokens - a.totalTokens || b.totalRequests - a.totalRequests);
}

export function aggregateComboSummaries(combos: DocumentData[]): ComboSummary[] {
  const comboMap = new Map<string, ComboSummary>();
  for (const doc of combos) {
    const sourceId = typeof doc.executionSourceId === "string" ? doc.executionSourceId : "";
    if (!sourceId) continue;
    const providerName = typeof doc.provider === "string" ? doc.provider : "unknown";
    const provider = parseProvider(providerName);
    if (!provider) continue;
    const model = typeof doc.model === "string" ? doc.model : "";
    if (!model) continue;
    const sourceName = typeof doc.executionSourceName === "string" ? doc.executionSourceName : "";
    const id = `${sourceId}:${provider}:${model}`;
    const existing = comboMap.get(id);
    if (existing) {
      if (!existing.sourceName && sourceName) existing.sourceName = sourceName;
      existing.requests += sumNumber(doc.requests);
      existing.tokens += sumNumber(doc.tokens);
      existing.cost += sumNumber(doc.costUsd);
    } else {
      comboMap.set(id, {
        sourceId,
        sourceName,
        provider,
        model,
        requests: sumNumber(doc.requests),
        tokens: sumNumber(doc.tokens),
        cost: sumNumber(doc.costUsd),
      });
    }
  }
  return Array.from(comboMap.values())
    .filter((entry) => entry.requests !== 0 || entry.tokens !== 0 || entry.cost !== 0)
    .sort((a, b) => b.tokens - a.tokens || b.requests - a.requests);
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
