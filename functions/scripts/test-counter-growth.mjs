/**
 * Counter growth load test (Wave 2.6 proof).
 *
 * Simulates ONE synthetic heavy user over 3 years (1095 days × 20 events/day
 * = 21,900 usage events across 4 providers) through the REAL built counter
 * pipeline (`applyUsageCounterDelta`, the retention sweeper,
 * `computeUserRollupsFromCounters`) against an in-memory Firestore that
 * mirrors the `test-rollups.mjs` fake (merge + FieldValue.increment
 * semantics) plus the collectionGroup surface the sweeper needs.
 *
 * Asserts the growth caps hold end to end:
 *   - every monthly shard stays far under the 1 MiB document limit;
 *   - the `all_time` base doc carries no daily maps and stays tiny;
 *   - expired day buckets (and their subcollections) are reaped, live ones kept;
 *   - day docs carry the TTL backstop stamp (`expireAt` = day + 190d);
 *   - lifetime totals stay exact and the full daily series survives in shards.
 */
import assert from "node:assert/strict";
import { applyUsageCounterDelta, computeUserRollupsFromCounters } from "../lib/rollups.js";
import { reapExpiredCounterDays } from "../lib/domains/scheduled/reapExpiredCounterDays.js";
import {
  ALL_TIME_DAILY_SHARD_PREFIX,
  COUNTER_DAY_RETENTION_DAYS,
  COUNTER_DAY_TTL_DAYS,
} from "../lib/rollupCounters.js";

const UID = "heavy-uid";
const END_MS = Date.parse("2026-09-24T12:00:00.000Z");
const SIM_DAYS = 1095;
const EVENTS_PER_DAY = 20;
const DAY_MS = 24 * 60 * 60 * 1000;

// Firestore's 1 MiB document limit, with the headroom each artifact must keep.
const DOC_LIMIT = 1024 * 1024;
const SHARD_BUDGET = 256 * 1024;
const BASE_BUDGET = 64 * 1024;
const ROLLUP_BUDGET = 512 * 1024;

// --- In-memory Firestore (merge/increment semantics like test-rollups.mjs). ---

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

function listCollectionDocs(store, path) {
  const prefix = `${path}/`;
  const expectedSegments = path.split("/").length + 1;
  return [...store.entries()]
    .filter(([key]) => key.startsWith(prefix) && key.split("/").length === expectedSegments)
    .map(([key, data]) => ({
      id: key.split("/").at(-1),
      ref: { path: key },
      data: () => data,
    }));
}

function makeQuery(listDocs, clauses = [], limitCount = undefined, startAfterId = undefined) {
  return {
    where(field, op, value) {
      return makeQuery(listDocs, [...clauses, [field, op, value]], limitCount, startAfterId);
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
          clauses.every(([field, op, value]) => {
            // FieldPath sentinels (documentId range for the 90d union)
            // compare ids; string fields read doc data (sweeper's day < cutoff).
            const actual = typeof field === "string" ? doc.data()[field] : doc.id;
            if (op === ">=") return actual >= value;
            if (op === "<=") return actual <= value;
            if (op === "<") return actual < value;
            return false;
          }),
        )
        .slice(0, limitCount ?? listDocs().length);
      return { empty: docs.length === 0, docs };
    },
  };
}

const store = new Map();
const db = {
  store,
  collection(path) {
    return {
      doc: (id) => db.doc(`${path}/${id}`),
      ...makeQuery(() => listCollectionDocs(store, path)),
    };
  },
  collectionGroup(name) {
    return makeQuery(() =>
      [...store.entries()]
        .filter(([key]) => {
          const segments = key.split("/");
          return segments.length === 4 && segments[0] === "users" && segments[2] === name;
        })
        .map(([key, data]) => ({ id: key.split("/").at(-1), ref: { path: key }, data: () => data })),
    );
  },
  doc(path) {
    return {
      path,
      collection: (name) => db.collection(`${path}/${name}`),
      async get() {
        const data = store.get(path);
        return { exists: data != null, data: () => data };
      },
    };
  },
  batch() {
    return {
      set(ref, data, options) {
        applySet(store, ref.path, data, options);
      },
      async commit() {},
    };
  },
  async runTransaction(work) {
    const transaction = {
      async get(ref) {
        const data = store.get(ref.path);
        return { exists: data != null, data: () => data };
      },
      set(ref, data, options) {
        applySet(store, ref.path, data, options);
      },
    };
    await work(transaction);
  },
  async recursiveDelete(ref) {
    for (const key of [...store.keys()]) {
      if (key === ref.path || key.startsWith(`${ref.path}/`)) store.delete(key);
    }
  },
};

// --- Simulation. ---

const PROVIDERS = [
  { provider: "codex", models: ["gpt-5.5", "gpt-5.4"] },
  { provider: "claude-code", models: ["claude-opus-4.7", "claude-sonnet-4.6"] },
  { provider: "kimi", models: ["kimi-for-coding", "kimi-k2"] },
  { provider: "gemini", models: ["gemini-3-pro", "gemini-3-flash"] },
];

const dayKey = (ms) => new Date(ms).toISOString().slice(0, 10);
const firstDayMs = END_MS - (SIM_DAYS - 1) * DAY_MS;

let expectedTokens = 0;
let expectedEvents = 0;
const t0 = Date.now();
for (let d = 0; d < SIM_DAYS; d++) {
  const dayStart = firstDayMs + d * DAY_MS;
  for (let e = 0; e < EVENTS_PER_DAY; e++) {
    const slot = d * EVENTS_PER_DAY + e;
    const provider = PROVIDERS[slot % PROVIDERS.length];
    const tokens = 100 + ((slot * 37) % 900);
    const at = new Date(dayStart + ((slot * 7919) % DAY_MS)).toISOString();
    expectedTokens += tokens;
    expectedEvents += 1;
    const event = {
      provider: provider.provider,
      providerID: provider.provider,
      schemaVersion: 1,
      sessionId: `heavy-s-${d}-${e}`,
      model: provider.models[slot % provider.models.length],
      inputTokens: Math.floor(tokens * 0.7),
      outputTokens: tokens - Math.floor(tokens * 0.7),
      totalTokens: tokens,
      cost: Number((tokens * 0.00001).toFixed(6)),
      recordedAt: at,
      startTime: at,
      accountLabel: slot % 2 === 0 ? "work" : "personal",
      executionSourceId: slot % 2 === 0 ? "ide" : undefined,
    };
    await applyUsageCounterDelta(db, UID, `usage-${d}-${e}`, undefined, event);
  }
}
const simSeconds = ((Date.now() - t0) / 1000).toFixed(1);

// --- Assertions: the caps hold. ---

const dayDocs = [...store.keys()].filter(
  (k) => k.startsWith(`users/${UID}/usage_counter_days/`) && k.split("/").length === 4,
);
assert.equal(dayDocs.length, SIM_DAYS);

// Retention: the sweeper reaps everything older than today - 180d.
const sweep = await reapExpiredCounterDays(db, { nowMs: END_MS });
const cutoff = dayKey(END_MS - COUNTER_DAY_RETENTION_DAYS * DAY_MS);
const liveDays = [];
for (let d = 0; d < SIM_DAYS; d++) {
  const day = dayKey(firstDayMs + d * DAY_MS);
  if (day >= cutoff) liveDays.push(day);
}
assert.equal(sweep.hasMore, false);
assert.equal(sweep.reaped, SIM_DAYS - liveDays.length);
const remainingDays = [...store.keys()].filter(
  (k) => k.startsWith(`users/${UID}/usage_counter_days/`) && k.split("/").length === 4,
);
assert.equal(remainingDays.length, liveDays.length);
// No orphaned subcollections under reaped days.
for (const key of store.keys()) {
  if (key.split("/").length > 4 && key.includes("/usage_counter_days/")) {
    const day = key.split("/")[3];
    assert.ok(day >= cutoff, `orphan under reaped day ${day}`);
  }
}

// TTL backstop stamps on the surviving day docs.
for (const day of liveDays.slice(0, 3)) {
  const doc = store.get(`users/${UID}/usage_counter_days/${day}`);
  const expireMs = doc.expireAt?.toMillis?.() ?? doc.expireAt?.seconds * 1000;
  assert.equal(expireMs, Date.parse(`${day}T00:00:00.000Z`) + COUNTER_DAY_TTL_DAYS * DAY_MS);
}

// Shard + base doc sizes.
const shardPaths = [...store.keys()].filter((k) =>
  k.startsWith(`users/${UID}/usage_counter_totals/${ALL_TIME_DAILY_SHARD_PREFIX}`),
);
assert.ok(shardPaths.length >= 35 && shardPaths.length <= 37, `shard count ${shardPaths.length}`);
let maxShardBytes = 0;
for (const path of shardPaths) {
  maxShardBytes = Math.max(maxShardBytes, JSON.stringify(store.get(path)).length);
}
assert.ok(maxShardBytes < SHARD_BUDGET, `max shard ${maxShardBytes} >= ${SHARD_BUDGET}`);
const baseDoc = store.get(`users/${UID}/usage_counter_totals/all_time`);
assert.equal("dailyTokens" in baseDoc, false);
assert.equal("dailyProviderTokens" in baseDoc, false);
const baseBytes = JSON.stringify(baseDoc).length;
assert.ok(baseBytes < BASE_BUDGET, `base ${baseBytes} >= ${BASE_BUDGET}`);

// Lifetime totals stay exact; the full daily series survives in shards.
const rollups = await computeUserRollupsFromCounters(db, UID);
assert.equal(rollups.all_time.totals.tokens, expectedTokens);
assert.equal(rollups.all_time.totals.requests, expectedEvents);
assert.equal(Object.keys(rollups.all_time.dailyPoints).length, SIM_DAYS);
const rollupBytes = JSON.stringify(rollups.all_time).length;
assert.ok(rollupBytes < ROLLUP_BUDGET, `all_time rollup ${rollupBytes} >= ${ROLLUP_BUDGET}`);

console.log(
  JSON.stringify({
    event: "counter_growth_check_passed",
    simDays: SIM_DAYS,
    events: expectedEvents,
    simSeconds,
    liveDayDocs: remainingDays.length,
    shards: shardPaths.length,
    maxShardBytes,
    baseBytes,
    rollupAllTimeBytes: rollupBytes,
    docLimit: DOC_LIMIT,
  }),
);
console.log("counter growth checks passed");
