import assert from "node:assert/strict";
import { computeUserRollups, writeUserRollups } from "../lib/rollups.js";

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
  collection(path) {
    assert.equal(path, "users/test-uid/usage");
    return {
      async get() {
        return {
          docs: usageDocs.map((data) => ({ data: () => data })),
        };
      },
    };
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

console.log("rollup normalization regression checks passed");
