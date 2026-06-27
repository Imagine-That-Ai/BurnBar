#!/usr/bin/env node

import assert from "node:assert/strict";

import { collectResearchResult, loadSeedSnapshotsForDate } from "./run-research.mjs";

const futureDate = new Date("2099-01-01T12:00:00.000Z");

const seed = await loadSeedSnapshotsForDate(futureDate.toISOString().slice(0, 10));
assert.ok(seed, "expected fallback seed snapshot");
assert.ok(seed.file.includes("snapshots-"), "fallback should select a dated seed fixture");
assert.ok(seed.rows.length > 0, "seed fixture should contain snapshots");
assert.ok(seed.statuses.length > 0, "seed fixture should carry source statuses");

process.env.OPENBURNBAR_RESEARCH_SEED_ONLY = "1";
try {
  const result = await collectResearchResult(futureDate, 1_000);
  assert.equal(result.sourceMode, "seed", "forced seed-only research should report seed mode");
  assert.ok(result.snapshots.length > 0, "seed-only research result should contain snapshots");
  assert.ok(result.statuses.length > 0, "seed-only research result should contain source statuses");
  assert.ok(
    result.statuses.some(
      (status) => status.source === "manual_fixture" || status.status === "stale"
    ),
    "seed-only result should make cached/manual source posture explicit"
  );
} finally {
  delete process.env.OPENBURNBAR_RESEARCH_SEED_ONLY;
}

console.log("PASS: research generator falls back to committed seed snapshots");
