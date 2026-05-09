import assert from "node:assert/strict";
import {
  applyUsageCounterDelta,
  computeUserRollups,
  computeUserRollupsFromCounters,
  writeUserRollups,
} from "../lib/rollups.js";

const now = new Date();

const usageDocs = [
  {
    provider: "Kimi",
    providerID: "kimi",
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
    provider: "Codex",
    providerID: "codex",
    sessionId: "codex-session-1",
    model: "gpt-5.5",
    inputTokens: 100,
    outputTokens: 25,
    totalTokens: 125,
    cost: 0.001,
    startTime: now.toISOString(),
  },
  {
    provider: "Codex",
    providerID: "codex",
    sessionId: "codex-session-1",
    model: "unknown",
    inputTokens: 100,
    outputTokens: 25,
    totalTokens: 125,
    cost: 0.001,
    startTime: now.toISOString(),
  },
];

const db = {
  store: new Map(),
  collection(path) {
    if (path === "users/test-uid/usage") {
      return {
        async get() {
          return {
            docs: usageDocs.map((data, index) => ({
              id: `usage-${index}`,
              data: () => data,
            })),
          };
        },
      };
    }
    return {
      doc(id) {
        return db.doc(`${path}/${id}`);
      },
      async get() {
        const prefix = `${path}/`;
        const expectedSegments = path.split("/").length + 1;
        return {
          docs: [...db.store.entries()]
            .filter(([key]) => key.startsWith(prefix) && key.split("/").length === expectedSegments)
            .map(([key, data]) => ({
              id: key.split("/").at(-1),
              ref: db.doc(key),
              data: () => data,
            })),
        };
      },
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
      set(ref, data, _options) {
        const existing = db.store.get(ref.path) ?? {};
        const next = { ...existing };
        for (const [key, value] of Object.entries(data)) {
          if (value && typeof value === "object" && "operand" in value) {
            next[key] = (typeof next[key] === "number" ? next[key] : 0) + value.operand;
          } else {
            next[key] = value;
          }
        }
        db.store.set(ref.path, next);
      },
      async commit() {},
    };
  },
  async runTransaction(work) {
    const transaction = {
      async get(ref) {
        const data = db.store.get(ref.path);
        return {
          exists: data != null,
          data: () => data,
        };
      },
      set(ref, data, _options) {
        const existing = db.store.get(ref.path) ?? {};
        const next = { ...existing };
        for (const [key, value] of Object.entries(data)) {
          if (value && typeof value === "object" && "operand" in value) {
            next[key] = (typeof next[key] === "number" ? next[key] : 0) + value.operand;
          } else {
            next[key] = value;
          }
        }
        db.store.set(ref.path, next);
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

assert.equal(today.totals.requests, 2);
assert.equal(today.totals.tokens, 1_875);
assert.equal(today.today, 1_875);
assert.equal(today.providerSummaries.find((p) => p.provider === "Kimi")?.totalTokens, 1_750);
assert.equal(today.modelSummaries.find((m) => m.provider === "Kimi")?.model, "kimi-for-coding");
assert.equal(today.modelSummaries.find((m) => m.provider === "Kimi")?.tokens, 1_750);
assert.equal(today.totals.costUsd, 0.00291);

await applyUsageCounterDelta(db, "test-uid", "usage-1", usageDocs[1], undefined);
const repairedThenUpdated = await computeUserRollupsFromCounters(db, "test-uid");
assert.equal(repairedThenUpdated.today.totals.requests, 2);
assert.equal(repairedThenUpdated.today.totals.tokens, 1_875);
assert.equal(
  repairedThenUpdated.today.modelSummaries.find((m) => m.provider === "Codex")?.model,
  "unknown"
);

function containsUndefined(value) {
  if (Array.isArray(value)) return value.some(containsUndefined);
  if (value && typeof value === "object") {
    return Object.values(value).some((entry) => entry === undefined || containsUndefined(entry));
  }
  return false;
}

const writes = [];
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
};

await writeUserRollups(writeDb, "test-uid", rollups);

assert.equal(writes.length, 6);
assert.equal(writes.find((write) => write.path.endsWith("/rollup_jobs/current"))?.data.dirty, false);
assert.equal(writes.some((write) => containsUndefined(write.data)), false);

const incrementalDb = {
  store: new Map(),
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
    const transaction = {
      async get(ref) {
        const data = incrementalDb.store.get(ref.path);
        return {
          exists: data != null,
          data: () => data,
        };
      },
      set(ref, data, _options) {
        const existing = incrementalDb.store.get(ref.path) ?? {};
        const next = { ...existing };
        for (const [key, value] of Object.entries(data)) {
          if (value && typeof value === "object" && "operand" in value) {
            next[key] = (typeof next[key] === "number" ? next[key] : 0) + value.operand;
          } else {
            next[key] = value;
          }
        }
        incrementalDb.store.set(ref.path, next);
      },
    };
    await work(transaction);
  },
};

incrementalDb.collection = function collection(path) {
  return {
    doc(id) {
      return incrementalDb.doc(`${path}/${id}`);
    },
    async get() {
      const prefix = `${path}/`;
      const expectedSegments = path.split("/").length + 1;
      return {
        docs: [...incrementalDb.store.entries()]
          .filter(([key]) => key.startsWith(prefix) && key.split("/").length === expectedSegments)
          .map(([key, data]) => ({
            id: key.split("/").at(-1),
            ref: incrementalDb.doc(key),
            data: () => data,
          })),
      };
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

console.log("rollup normalization regression checks passed");
