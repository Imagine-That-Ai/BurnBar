import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { verifyTrxResults } from "./verify-trx-results.mjs";

const workspace = mkdtempSync(join(tmpdir(), "verify-trx-results-test-"));
test.after(() => rmSync(workspace, { recursive: true, force: true }));

function writeTrx(path, overrides = {}) {
  const counters = {
    total: 3,
    executed: 2,
    passed: 2,
    failed: 0,
    error: 0,
    timeout: 0,
    aborted: 0,
    inconclusive: 0,
    passedButRunAborted: 0,
    notRunnable: 0,
    notExecuted: 1,
    disconnected: 0,
    warning: 0,
    completed: 0,
    inProgress: 0,
    pending: 0,
    ...overrides,
  };
  const attributes = Object.entries(counters)
    .map(([name, value]) => `${name}="${value}"`)
    .join(" ");
  writeFileSync(
    path,
    `<?xml version="1.0" encoding="utf-8"?>
<TestRun>
  <ResultSummary outcome="Completed">
    <Counters ${attributes} />
  </ResultSummary>
</TestRun>
`,
  );
}

test("accepts complete passing TRX evidence and aggregates counters", () => {
  const results = join(workspace, "complete");
  mkdirSync(join(results, "nested"), { recursive: true });
  writeTrx(join(results, "first.trx"));
  writeTrx(join(results, "nested", "second.trx"), {
    total: 4,
    executed: 4,
    passed: 4,
    notExecuted: 0,
  });

  assert.deepEqual(verifyTrxResults(results, 2, 7), {
    ok: true,
    resultsDirectory: results,
    files: 2,
    total: 7,
    executed: 6,
    passed: 6,
    failed: 0,
    notExecuted: 1,
  });
});

test("rejects an overwritten or otherwise incomplete TRX directory", () => {
  const results = join(workspace, "incomplete");
  mkdirSync(results);
  writeTrx(join(results, "only-last-project.trx"));

  assert.throws(
    () => verifyTrxResults(results, 2, 3),
    /expected at least 2 files, found 1/,
  );
  assert.throws(
    () => verifyTrxResults(results, 1, 4),
    /expected at least 4 tests, found 3/,
  );
});

test("rejects failed and internally inconsistent counters", () => {
  const failedResults = join(workspace, "failed");
  mkdirSync(failedResults);
  writeTrx(join(failedResults, "failed.trx"), {
    total: 3,
    executed: 3,
    passed: 2,
    failed: 1,
    notExecuted: 0,
  });
  assert.throws(() => verifyTrxResults(failedResults, 1, 3), /has failed=1/);

  const inconsistentResults = join(workspace, "inconsistent");
  mkdirSync(inconsistentResults);
  writeTrx(join(inconsistentResults, "inconsistent.trx"), {
    total: 4,
  });
  assert.throws(
    () => verifyTrxResults(inconsistentResults, 1, 4),
    /total counter is inconsistent/,
  );
});
