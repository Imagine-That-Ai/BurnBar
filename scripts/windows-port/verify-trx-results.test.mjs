import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  readAllowedNotExecuted,
  verifyTrxResults,
} from "./verify-trx-results.mjs";

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
    // Current VSTest TRX output may leave this at zero even when an actual
    // UnitTestResult row has outcome="NotExecuted".
    notExecuted: 0,
    disconnected: 0,
    warning: 0,
    completed: 0,
    inProgress: 0,
    pending: 0,
    ...overrides,
  };
  const outcomes = overrides.outcomes ?? [
    ...Array(counters.passed).fill("Passed"),
    ...Array(counters.failed).fill("Failed"),
    ...Array(counters.total - counters.executed).fill("NotExecuted"),
  ];
  delete counters.outcomes;
  const attributes = Object.entries(counters)
    .map(([name, value]) => `${name}="${value}"`)
    .join(" ");
  const results = outcomes
    .map((entry, index) => {
      const outcome = typeof entry === "string" ? entry : entry.outcome;
      const testName =
        typeof entry === "string"
          ? `Example.Tests.Test${index}`
          : entry.testName;
      return `    <UnitTestResult testId="${index}" testName="${testName}" outcome="${outcome}" />`;
    })
    .join("\n");
  writeFileSync(
    path,
    `<?xml version="1.0" encoding="utf-8"?>
<TestRun>
  <Results>
${results}
  </Results>
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
  });

  assert.deepEqual(verifyTrxResults(results, 2, 7, 1), {
    ok: true,
    resultsDirectory: results,
    files: 2,
    total: 7,
    executed: 6,
    passed: 6,
    failed: 0,
    notExecuted: 1,
    notExecutedTests: ["Example.Tests.Test2"],
  });
});

test("rejects an overwritten or otherwise incomplete TRX directory", () => {
  const results = join(workspace, "incomplete");
  mkdirSync(results);
  writeTrx(join(results, "only-last-project.trx"));

  assert.throws(
    () => verifyTrxResults(results, 2, 3, 1),
    /expected at least 2 files, found 1/,
  );
  assert.throws(
    () => verifyTrxResults(results, 1, 4, 1),
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
  });
  assert.throws(() => verifyTrxResults(failedResults, 1, 3, 0), /has failed=1/);

  const inconsistentResults = join(workspace, "inconsistent");
  mkdirSync(inconsistentResults);
  writeTrx(join(inconsistentResults, "inconsistent.trx"), {
    total: 4,
    outcomes: ["Passed", "Passed", "NotExecuted"],
  });
  assert.throws(
    () => verifyTrxResults(inconsistentResults, 1, 4, 1),
    /total counter does not match test results/,
  );
});

test("rejects more skipped tests than the reviewed ceiling", () => {
  const results = join(workspace, "too-many-skips");
  mkdirSync(results);
  writeTrx(join(results, "skipped.trx"));

  assert.throws(
    () => verifyTrxResults(results, 1, 3, 0),
    /allowed at most 0, found 1/,
  );
});

test("rejects an unexpected test-result outcome even when counters claim success", () => {
  const results = join(workspace, "unexpected-outcome");
  mkdirSync(results);
  writeTrx(join(results, "unexpected.trx"), {
    total: 3,
    executed: 2,
    passed: 2,
    outcomes: ["Passed", "Passed", "Warning"],
  });

  assert.throws(
    () => verifyTrxResults(results, 1, 3, 1),
    /disallowed outcome Warning=1/,
  );
});

test("accepts only reviewed skipped-test names when an allowlist is supplied", () => {
  const results = join(workspace, "reviewed-skips");
  mkdirSync(results);
  writeTrx(join(results, "reviewed.trx"), {
    outcomes: [
      "Passed",
      "Passed",
      {
        testName: "Example.Tests.KnownLiveOnlyTest",
        outcome: "NotExecuted",
      },
    ],
  });

  assert.equal(
    verifyTrxResults(results, 1, 3, 1, ["Example.Tests.KnownLiveOnlyTest"])
      .notExecuted,
    1,
  );
  assert.throws(
    () =>
      verifyTrxResults(results, 1, 3, 1, ["Example.Tests.DifferentKnownTest"]),
    /unreviewed skipped tests: Example\.Tests\.KnownLiveOnlyTest/,
  );
});

test("loads a strict sorted skipped-test allowlist", () => {
  const path = join(workspace, "allowed.json");
  writeFileSync(
    path,
    `${JSON.stringify({
      schema: "openburnbar.windows.allowed-not-executed.v1",
      tests: ["A.Tests.First", "B.Tests.Second"],
    })}\n`,
  );
  assert.deepEqual(readAllowedNotExecuted(path), [
    "A.Tests.First",
    "B.Tests.Second",
  ]);

  writeFileSync(
    path,
    `${JSON.stringify({
      schema: "openburnbar.windows.allowed-not-executed.v1",
      tests: ["B.Tests.Second", "A.Tests.First"],
    })}\n`,
  );
  assert.throws(
    () => readAllowedNotExecuted(path),
    /test names must be sorted/,
  );

  const directory = join(workspace, "allowed-directory");
  mkdirSync(directory);
  assert.throws(
    () => readAllowedNotExecuted(directory),
    /allowed not-executed file must be a regular file/,
  );
});
