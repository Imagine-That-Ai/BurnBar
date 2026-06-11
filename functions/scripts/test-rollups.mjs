import assert from "node:assert/strict";
import {
  applyUsageCounterDelta,
  computeUserRollups,
  computeUserRollupsFromCounters,
  drainPendingCounterDeltas,
  enqueueUsageCounterDelta,
  rebuildUserRollupCounters,
  writeUserRollups,
} from "../lib/rollups.js";

const now = new Date();

const usageDocs = [
  {
    provider: "kimi",
    providerID: "kimi",
    schemaVersion: 1,
    sessionId: "kimi-session-1",
    model: "chatcmpl-legacy-message-id",
    inputTokens: 1_250,
    outputTokens: 500,
    cacheCreationTokens: 50,
    cacheReadTokens: 200,
    totalTokens: 2_000,
    cost: 0.01,
    startTime: now.toISOString(),
  },
  {
    provider: "codex",
    providerID: "codex",
    schemaVersion: 1,
    sessionId: "codex-session-1",
    model: "gpt-5.5",
    inputTokens: 100,
    outputTokens: 25,
    totalTokens: 125,
    cost: 0.001,
    startTime: now.toISOString(),
  },
  {
    provider: "codex",
    providerID: "codex",
    schemaVersion: 1,
    sessionId: "codex-session-1",
    model: "unknown",
    inputTokens: 100,
    outputTokens: 25,
    totalTokens: 125,
    cost: 0.001,
    startTime: now.toISOString(),
  },
];

// Mirrors Firestore set() semantics: merge:false replaces the document,
// merge:true deep-merges plain maps, and FieldValue.increment sentinels apply
// against the existing numeric value (nested increments included, which the
// rolling all_time dailyTokens map relies on).
function mergeFieldValue(existing, value) {
  if (value && typeof value === "object" && "operand" in value) {
    return (typeof existing === "number" ? existing : 0) + value.operand;
  }
  if (value && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    const next =
      existing && typeof existing === "object" && Object.getPrototypeOf(existing) === Object.prototype
        ? { ...existing }
        : {};
    for (const [key, entry] of Object.entries(value)) {
      next[key] = mergeFieldValue(next[key], entry);
    }
    return next;
  }
  return value;
}

function applySet(store, path, data, options) {
  const merge = options?.merge === true;
  const next = merge ? { ...(store.get(path) ?? {}) } : {};
  for (const [key, value] of Object.entries(data)) {
    next[key] = mergeFieldValue(merge ? next[key] : undefined, value);
  }
  store.set(path, next);
}

function listCollectionDocs(fakeDb, path) {
  const prefix = `${path}/`;
  const expectedSegments = path.split("/").length + 1;
  return [...fakeDb.store.entries()]
    .filter(([key]) => key.startsWith(prefix) && key.split("/").length === expectedSegments)
    .map(([key, data]) => ({
      id: key.split("/").at(-1),
      ref: fakeDb.doc(key),
      data: () => data,
    }));
}

// Supports the documentId range filters used by the rollup day-window fetch.
function makeQuery(listDocs, clauses = [], limitCount = undefined, startAfterId = undefined) {
  return {
    where(_field, op, value) {
      return makeQuery(listDocs, [...clauses, [op, value]], limitCount, startAfterId);
    },
    orderBy() {
      return makeQuery(listDocs, clauses, limitCount, startAfterId);
    },
    limit(count) {
      return makeQuery(listDocs, clauses, count, startAfterId);
    },
    startAfter(doc) {
      return makeQuery(listDocs, clauses, limitCount, doc.id);
    },
    async get() {
      const docs = listDocs()
        .sort((a, b) => a.id.localeCompare(b.id))
        .filter((doc) => !startAfterId || doc.id > startAfterId)
        .filter((doc) =>
          clauses.every(([op, value]) => (op === ">=" ? doc.id >= value : op === "<=" ? doc.id <= value : false)),
        )
        .slice(0, limitCount ?? listDocs().length);
      return {
        empty: docs.length === 0,
        docs,
      };
    },
  };
}

const db = {
  store: new Map(),
  collection(path) {
    if (path === "users/test-uid/usage") {
      return makeQuery(() =>
        usageDocs.map((data, index) => ({
          id: `usage-${index}`,
          data: () => data,
        })),
      );
    }
    return {
      doc(id) {
        return db.doc(`${path}/${id}`);
      },
      ...makeQuery(() => listCollectionDocs(db, path)),
    };
  },
  doc(path) {
    return {
      path,
      collection(name) {
        return db.collection(`${path}/${name}`);
      },
      async get() {
        const data = db.store.get(path);
        return {
          exists: data != null,
          data: () => data,
        };
      },
    };
  },
  batch() {
    return {
      set(ref, data, options) {
        applySet(db.store, ref.path, data, options);
      },
      async commit() {},
    };
  },
  async runTransaction(work) {
    let hasWritten = false;
    const transaction = {
      async get(ref) {
        if (hasWritten) {
          throw new Error("test transaction read after write");
        }
        const data = db.store.get(ref.path);
        return {
          exists: data != null,
          data: () => data,
        };
      },
      set(ref, data, options) {
        hasWritten = true;
        applySet(db.store, ref.path, data, options);
      },
    };
    await work(transaction);
  },
  async recursiveDelete(ref) {
    for (const key of [...db.store.keys()]) {
      if (key === ref.path || key.startsWith(`${ref.path}/`)) {
        db.store.delete(key);
      }
    }
  },
};

const rollups = await computeUserRollups(db, "test-uid");
const today = rollups.today;
const dayKey = now.toISOString().slice(0, 10);

assert.equal(today.totals.requests, 2);
assert.equal(today.totals.tokens, 1_875);
assert.equal(today.today, 1_875);
assert.equal(today.providerSummaries.find((p) => p.provider === "kimi")?.totalTokens, 1_750);
assert.equal(today.modelSummaries.find((m) => m.provider === "kimi")?.model, "kimi-for-coding");
assert.equal(today.modelSummaries.find((m) => m.provider === "kimi")?.tokens, 1_750);
assert.equal(today.totals.costUsd, 0.00291);
assert.deepEqual(today.dailyPoints, { [dayKey]: 1_875 });
assert.deepEqual(rollups.all_time.dailyPoints, { [dayKey]: 1_875 });
// Full counter rebuilds regenerate the rolling dailyTokens map for free.
assert.deepEqual(db.store.get("users/test-uid/usage_counter_totals/all_time").dailyTokens, { [dayKey]: 1_875 });

await applyUsageCounterDelta(db, "test-uid", "usage-1", usageDocs[1], undefined);
const repairedThenUpdated = await computeUserRollupsFromCounters(db, "test-uid");
assert.equal(repairedThenUpdated.today.totals.requests, 2);
assert.equal(repairedThenUpdated.today.totals.tokens, 1_875);
assert.equal(repairedThenUpdated.today.modelSummaries.find((m) => m.provider === "codex")?.model, "unknown");

const pagedRepair = await rebuildUserRollupCounters(db, "test-uid", { pageSize: 1 });
assert.equal(pagedRepair.usageDocsScanned, 3);
assert.equal(pagedRepair.pages, 3);
assert.equal(pagedRepair.winnersWritten, 2);

function containsUndefined(value) {
  if (Array.isArray(value)) return value.some(containsUndefined);
  if (value && typeof value === "object") {
    return Object.values(value).some((entry) => entry === undefined || containsUndefined(entry));
  }
  return false;
}

const writes = [];
const jobStore = new Map();
const writeDb = {
  batch() {
    return {
      set(ref, data, options) {
        writes.push({ path: ref.path, data, options });
      },
      async commit() {},
    };
  },
  doc(path) {
    return { path };
  },
  async runTransaction(work) {
    const transaction = {
      async get(ref) {
        const data = jobStore.get(ref.path);
        return { exists: data != null, data: () => data };
      },
      set(ref, data, options) {
        writes.push({ path: ref.path, data, options });
        jobStore.set(ref.path, { ...(jobStore.get(ref.path) ?? {}), ...data });
      },
    };
    return work(transaction);
  },
};

await writeUserRollups(writeDb, "test-uid", rollups, undefined);

assert.equal(writes.length, 6);
assert.equal(writes.find((write) => write.path.endsWith("/rollup_jobs/current"))?.data.dirty, false);
assert.equal(
  writes.some((write) => containsUndefined(write.data)),
  false,
);

// Dirty-clear race guard: a usage event landing mid-compute refreshes
// `dirtiedAt`, so the clear must be skipped and the job stays dirty for the
// next worker pass instead of silently dropping the event from rollups.
jobStore.set("users/test-uid/rollup_jobs/current", {
  dirty: true,
  dirtiedAt: "2026-06-09T00:00:01.000Z",
});
await writeUserRollups(writeDb, "test-uid", rollups, "2026-06-09T00:00:00.000Z");
const racedJob = jobStore.get("users/test-uid/rollup_jobs/current");
assert.equal(racedJob.dirty, true);
assert.equal(racedJob.dirtiedAt, "2026-06-09T00:00:01.000Z");
assert.equal(typeof racedJob.lastComputedAt, "string");

const incrementalDb = {
  store: new Map(),
  // Read-amplification instrumentation: unfiltered scans of the whole
  // usage_counter_days collection, and per-day point gets of its docs.
  dayCollectionScans: 0,
  dayDocPointGets: 0,
  collection(_path) {
    throw new Error("collection stub not initialized");
  },
  doc(path) {
    return {
      path,
      collection(name) {
        return incrementalDb.collection(`${path}/${name}`);
      },
      async get() {
        if (/\/usage_counter_days\/[^/]+$/.test(path)) {
          incrementalDb.dayDocPointGets += 1;
        }
        const data = incrementalDb.store.get(path);
        return {
          exists: data != null,
          data: () => data,
        };
      },
    };
  },
  batch() {
    throw new Error("incremental test should not use repair batches");
  },
  async runTransaction(work) {
    let hasWritten = false;
    const transaction = {
      async get(ref) {
        if (hasWritten) {
          throw new Error("test transaction read after write");
        }
        const data = incrementalDb.store.get(ref.path);
        return {
          exists: data != null,
          data: () => data,
        };
      },
      set(ref, data, options) {
        hasWritten = true;
        applySet(incrementalDb.store, ref.path, data, options);
      },
    };
    await work(transaction);
  },
};

incrementalDb.collection = function collection(path) {
  const query = makeQuery(() => listCollectionDocs(incrementalDb, path));
  return {
    doc(id) {
      return incrementalDb.doc(`${path}/${id}`);
    },
    where: query.where,
    async get() {
      if (path.endsWith("/usage_counter_days")) {
        incrementalDb.dayCollectionScans += 1;
      }
      return query.get();
    },
  };
};

await applyUsageCounterDelta(incrementalDb, "test-uid", "codex-poor", undefined, usageDocs[2]);
await applyUsageCounterDelta(incrementalDb, "test-uid", "codex-good", undefined, usageDocs[1]);
let incrementalRollups = await computeUserRollupsFromCounters(incrementalDb, "test-uid");
assert.equal(incrementalRollups.today.totals.requests, 1);
assert.equal(incrementalRollups.today.totals.tokens, 125);
assert.equal(incrementalRollups.today.modelSummaries[0]?.model, "gpt-5.5");

await applyUsageCounterDelta(incrementalDb, "test-uid", "codex-good", usageDocs[1], undefined);
incrementalRollups = await computeUserRollupsFromCounters(incrementalDb, "test-uid");
assert.equal(incrementalRollups.today.totals.requests, 1);
assert.equal(incrementalRollups.today.modelSummaries[0]?.model, "unknown");

const upgradedCodex = {
  ...usageDocs[2],
  model: "gpt-5.5",
  updatedAt: new Date(now.getTime() + 1_000).toISOString(),
};
await applyUsageCounterDelta(incrementalDb, "test-uid", "codex-poor", usageDocs[2], upgradedCodex);
incrementalRollups = await computeUserRollupsFromCounters(incrementalDb, "test-uid");
assert.equal(incrementalRollups.today.totals.requests, 1);
assert.equal(incrementalRollups.today.modelSummaries[0]?.model, "gpt-5.5");

incrementalDb.store.clear();
await applyUsageCounterDelta(incrementalDb, "test-uid", "codex@good", undefined, usageDocs[2]);
await applyUsageCounterDelta(incrementalDb, "test-uid", "codex#good", undefined, usageDocs[1]);
incrementalRollups = await computeUserRollupsFromCounters(incrementalDb, "test-uid");
assert.equal(incrementalRollups.today.totals.requests, 1);
assert.equal(incrementalRollups.today.modelSummaries[0]?.model, "gpt-5.5");

await applyUsageCounterDelta(incrementalDb, "test-uid", "codex#good", usageDocs[1], undefined);
incrementalRollups = await computeUserRollupsFromCounters(incrementalDb, "test-uid");
assert.equal(incrementalRollups.today.totals.requests, 1);
assert.equal(incrementalRollups.today.modelSummaries[0]?.model, "unknown");

incrementalDb.store.clear();
const movedCodex = {
  ...usageDocs[1],
  sessionId: "codex-session-moved",
};
await applyUsageCounterDelta(incrementalDb, "test-uid", "codex-moved", usageDocs[1], movedCodex);
incrementalRollups = await computeUserRollupsFromCounters(incrementalDb, "test-uid");
assert.equal(incrementalRollups.today.totals.requests, 1);
assert.equal(incrementalRollups.today.modelSummaries[0]?.model, "gpt-5.5");

// crosscut-004 read-amplification regression: the counter compute fetches day
// buckets through one documentId range query (zero per-day point gets) and
// serves all_time dailyPoints from the rolling dailyTokens map on the totals
// doc (zero unbounded usage_counter_days scans).
incrementalDb.store.clear();
incrementalDb.dayCollectionScans = 0;
incrementalDb.dayDocPointGets = 0;
await applyUsageCounterDelta(incrementalDb, "test-uid", "codex-good", undefined, usageDocs[1]);
let perfRollups = await computeUserRollupsFromCounters(incrementalDb, "test-uid");
assert.deepEqual(perfRollups.all_time.dailyPoints, { [dayKey]: 125 });
assert.deepEqual(perfRollups.today.dailyPoints, { [dayKey]: 125 });
assert.equal(perfRollups.today.totals.tokens, perfRollups.all_time.totals.tokens);
assert.equal(incrementalDb.dayDocPointGets, 0);
assert.equal(incrementalDb.dayCollectionScans, 0);

// Totals docs that predate the dailyTokens map fall back to one legacy scan
// and persist the derived map, so the next compute is incremental again.
const totalsPath = "users/test-uid/usage_counter_totals/all_time";
const legacyTotals = { ...incrementalDb.store.get(totalsPath) };
delete legacyTotals.dailyTokens;
incrementalDb.store.set(totalsPath, legacyTotals);
perfRollups = await computeUserRollupsFromCounters(incrementalDb, "test-uid");
assert.deepEqual(perfRollups.all_time.dailyPoints, { [dayKey]: 125 });
assert.equal(incrementalDb.dayCollectionScans, 1);
assert.deepEqual(incrementalDb.store.get(totalsPath).dailyTokens, { [dayKey]: 125 });
perfRollups = await computeUserRollupsFromCounters(incrementalDb, "test-uid");
assert.equal(incrementalDb.dayCollectionScans, 1);

// The backfill persist is skipped when a counter write lands mid-scan
// (updatedAt mismatch), so an in-flight increment is never overwritten by the
// scan's absolute values; the next worker pass retries the backfill.
const racedTotals = { ...incrementalDb.store.get(totalsPath) };
delete racedTotals.dailyTokens;
incrementalDb.store.set(totalsPath, racedTotals);
const originalCollection = incrementalDb.collection;
incrementalDb.collection = function collection(path) {
  const result = originalCollection(path);
  if (path === "users/test-uid/usage_counter_days") {
    const originalGet = result.get;
    result.get = async function get() {
      const snapshot = await originalGet.call(result);
      // Simulate a counter write landing while the legacy scan runs.
      incrementalDb.store.set(totalsPath, {
        ...incrementalDb.store.get(totalsPath),
        updatedAt: "2099-01-01T00:00:00.000Z",
      });
      return snapshot;
    };
  }
  return result;
};
perfRollups = await computeUserRollupsFromCounters(incrementalDb, "test-uid");
incrementalDb.collection = originalCollection;
assert.deepEqual(perfRollups.all_time.dailyPoints, { [dayKey]: 125 });
assert.equal(incrementalDb.store.get(totalsPath).dailyTokens, undefined);

// The retry pass persists the map; removing the only event then decrements
// the day's dailyTokens entry to zero, and zero entries are filtered from
// dailyPoints output exactly like the legacy day-doc filter.
perfRollups = await computeUserRollupsFromCounters(incrementalDb, "test-uid");
assert.deepEqual(incrementalDb.store.get(totalsPath).dailyTokens, { [dayKey]: 125 });
await applyUsageCounterDelta(incrementalDb, "test-uid", "codex-good", usageDocs[1], undefined);
perfRollups = await computeUserRollupsFromCounters(incrementalDb, "test-uid");
assert.deepEqual(incrementalDb.store.get(totalsPath).dailyTokens, { [dayKey]: 0 });
assert.deepEqual(perfRollups.all_time.dailyPoints, {});
assert.deepEqual(perfRollups.today.dailyPoints, {});

// ---------------------------------------------------------------------------
// Pending-delta queue (crosscut-011): the trigger appends one queue doc per
// usage event; the worker drains pages with coalesced increments. These
// checks prove (1) the trigger path writes ZERO counter docs, (2) draining
// produces byte-identical counter state to the reference
// applyUsageCounterDelta transactions, (3) a same-bucket burst collapses to
// ONE set per bucket doc, (4) winner dedupe survives the queue, and (5) the
// full rebuild purges the queue.
// ---------------------------------------------------------------------------

function makeQueueDb() {
  const fakeDb = {
    store: new Map(),
    // sets per document path — the coalescing instrumentation.
    setCounts: new Map(),
    collection(path) {
      return makeQueueCollection(fakeDb, path);
    },
    doc(path) {
      return {
        path,
        collection(name) {
          return fakeDb.collection(`${path}/${name}`);
        },
        async get() {
          const data = fakeDb.store.get(path);
          return { exists: data != null, data: () => data };
        },
        async set(data, options) {
          countingSet(fakeDb, { path }, data, options);
        },
      };
    },
    batch() {
      return {
        set(ref, data, options) {
          countingSet(fakeDb, ref, data, options);
        },
        async commit() {},
      };
    },
    async runTransaction(work) {
      let hasWritten = false;
      const transaction = {
        async get(ref) {
          if (hasWritten) throw new Error("queue test transaction read after write");
          const data = fakeDb.store.get(ref.path);
          return { exists: data != null, data: () => data };
        },
        async getAll(...refs) {
          if (hasWritten) throw new Error("queue test transaction read after write");
          return refs.map((ref) => {
            const data = fakeDb.store.get(ref.path);
            return { exists: data != null, data: () => data };
          });
        },
        set(ref, data, options) {
          hasWritten = true;
          countingSet(fakeDb, ref, data, options);
        },
        delete(ref) {
          hasWritten = true;
          fakeDb.store.delete(ref.path);
        },
      };
      await work(transaction);
    },
    async recursiveDelete(ref) {
      for (const key of [...fakeDb.store.keys()]) {
        if (key === ref.path || key.startsWith(`${ref.path}/`)) {
          fakeDb.store.delete(key);
        }
      }
    },
  };
  return fakeDb;
}

function countingSet(fakeDb, ref, data, options) {
  fakeDb.setCounts.set(ref.path, (fakeDb.setCounts.get(ref.path) ?? 0) + 1);
  applySet(fakeDb.store, ref.path, data, options);
}

function makeQueueCollection(fakeDb, path, clauses = [], limitCount = undefined) {
  return {
    path,
    doc(id) {
      return fakeDb.doc(`${path}/${id}`);
    },
    where(_field, op, value) {
      return makeQueueCollection(fakeDb, path, [...clauses, [op, value]], limitCount);
    },
    limit(count) {
      return makeQueueCollection(fakeDb, path, clauses, count);
    },
    async get() {
      // Implicit __name__ ordering, like Firestore queries without orderBy.
      let docs = listCollectionDocs(fakeDb, path)
        .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
        .filter((doc) =>
          clauses.every(([op, value]) => (op === ">=" ? doc.id >= value : op === "<=" ? doc.id <= value : false)),
        );
      if (limitCount !== undefined) docs = docs.slice(0, limitCount);
      return { docs };
    },
  };
}

function listQueueDocs(fakeDb) {
  return listCollectionDocs(fakeDb, "users/test-uid/pending_counter_deltas");
}

function stripVolatileFields(value) {
  if (Array.isArray(value)) return value.map(stripVolatileFields);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key]) => key !== "updatedAt")
        .map(([key, entry]) => [key, stripVolatileFields(entry)]),
    );
  }
  return value;
}

function counterStateSnapshot(fakeDb) {
  const snapshot = {};
  for (const [path, data] of [...fakeDb.store.entries()].sort()) {
    if (path.includes("/usage_counter_")) snapshot[path] = stripVolatileFields(data);
  }
  return snapshot;
}

// (1) Trigger-side enqueue: exactly one queue doc, zero counter writes.
const queueDb = makeQueueDb();
assert.equal(await enqueueUsageCounterDelta(queueDb, "test-uid", "codex-good", undefined, usageDocs[1]), true);
assert.equal(listQueueDocs(queueDb).length, 1);
assert.equal(
  [...queueDb.store.keys()].some((key) => key.includes("usage_counter")),
  false,
);
// Nothing countable -> nothing enqueued.
assert.equal(await enqueueUsageCounterDelta(queueDb, "test-uid", "empty-doc", undefined, undefined), false);
assert.equal(listQueueDocs(queueDb).length, 1);

// (2) Drain equivalence: queue-then-drain produces the same counter state as
// the reference applyUsageCounterDelta transaction for the same event.
const drainOnce = await drainPendingCounterDeltas(queueDb, "test-uid");
assert.equal(drainOnce.drainedDocs, 1);
assert.equal(drainOnce.pages, 1);
assert.equal(listQueueDocs(queueDb).length, 0);

const referenceDb = makeQueueDb();
await applyUsageCounterDelta(referenceDb, "test-uid", "codex-good", undefined, usageDocs[1]);
assert.deepEqual(counterStateSnapshot(queueDb), counterStateSnapshot(referenceDb));

// Draining an empty queue is a no-op (zero pages, zero transactions).
const emptyDrain = await drainPendingCounterDeltas(queueDb, "test-uid");
assert.equal(emptyDrain.drainedDocs, 0);
assert.equal(emptyDrain.pages, 0);

// (3) Burst coalescing: 10 same-bucket events drain into ONE set per bucket
// doc (instead of 10 transactions x up to 11 sets each).
const burstDb = makeQueueDb();
let burstTokens = 0;
for (let i = 0; i < 10; i += 1) {
  const tokens = 100 + i;
  burstTokens += tokens;
  const burstEvent = { ...usageDocs[1], inputTokens: tokens, outputTokens: 0, totalTokens: tokens };
  assert.equal(await enqueueUsageCounterDelta(burstDb, "test-uid", `burst-${i}`, undefined, burstEvent), true);
}
assert.equal(listQueueDocs(burstDb).length, 10);
burstDb.setCounts.clear();
const burstDrain = await drainPendingCounterDeltas(burstDb, "test-uid");
assert.equal(burstDrain.drainedDocs, 10);
assert.equal(burstDrain.pages, 1);
assert.equal(burstDb.setCounts.get(`users/test-uid/usage_counter_days/${dayKey}`), 1);
assert.equal(burstDb.setCounts.get("users/test-uid/usage_counter_totals/all_time"), 1);
const burstRollups = await computeUserRollupsFromCounters(burstDb, "test-uid");
assert.equal(burstRollups.today.totals.requests, 10);
assert.equal(burstRollups.today.totals.tokens, burstTokens);

// (4) Winner dedupe survives the queue: poor + good copies of the same
// logical event collapse to the good one; deleting the good copy falls back.
const dedupeDb = makeQueueDb();
await enqueueUsageCounterDelta(dedupeDb, "test-uid", "codex-poor", undefined, usageDocs[2]);
await enqueueUsageCounterDelta(dedupeDb, "test-uid", "codex-good", undefined, usageDocs[1]);
await drainPendingCounterDeltas(dedupeDb, "test-uid");
let dedupeRollups = await computeUserRollupsFromCounters(dedupeDb, "test-uid");
assert.equal(dedupeRollups.today.totals.requests, 1);
assert.equal(dedupeRollups.today.modelSummaries[0]?.model, "gpt-5.5");

await enqueueUsageCounterDelta(dedupeDb, "test-uid", "codex-good", usageDocs[1], undefined);
await drainPendingCounterDeltas(dedupeDb, "test-uid");
dedupeRollups = await computeUserRollupsFromCounters(dedupeDb, "test-uid");
assert.equal(dedupeRollups.today.totals.requests, 1);
assert.equal(dedupeRollups.today.modelSummaries[0]?.model, "unknown");

// Mixed within one page too: create + winner-flip + cross-key move drain to
// the same state the reference path reaches applying them one by one.
const mixedQueueDb = makeQueueDb();
const movedCodexEvent = { ...usageDocs[1], sessionId: "codex-session-moved" };
await enqueueUsageCounterDelta(mixedQueueDb, "test-uid", "codex-poor", undefined, usageDocs[2]);
await enqueueUsageCounterDelta(mixedQueueDb, "test-uid", "codex-good", undefined, usageDocs[1]);
await enqueueUsageCounterDelta(mixedQueueDb, "test-uid", "codex-good", usageDocs[1], movedCodexEvent);
await drainPendingCounterDeltas(mixedQueueDb, "test-uid");
const mixedReferenceDb = makeQueueDb();
await applyUsageCounterDelta(mixedReferenceDb, "test-uid", "codex-poor", undefined, usageDocs[2]);
await applyUsageCounterDelta(mixedReferenceDb, "test-uid", "codex-good", undefined, usageDocs[1]);
await applyUsageCounterDelta(mixedReferenceDb, "test-uid", "codex-good", usageDocs[1], movedCodexEvent);
assert.deepEqual(counterStateSnapshot(mixedQueueDb), counterStateSnapshot(mixedReferenceDb));

// (5) The full rebuild purges the queue: stale deltas are superseded by the
// raw usage rescan and must not replay afterwards.
const rebuildDb = makeQueueDb();
await enqueueUsageCounterDelta(rebuildDb, "test-uid", "stale-event", undefined, usageDocs[1]);
assert.equal(listQueueDocs(rebuildDb).length, 1);
const originalRebuildCollection = rebuildDb.collection;
rebuildDb.collection = function collection(path) {
  if (path === "users/test-uid/usage") {
    return makeQuery(() => []);
  }
  return originalRebuildCollection(path);
};
await computeUserRollups(rebuildDb, "test-uid");
assert.equal(listQueueDocs(rebuildDb).length, 0);

console.log("rollup normalization regression checks passed");
