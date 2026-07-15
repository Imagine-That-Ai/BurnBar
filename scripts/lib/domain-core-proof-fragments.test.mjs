import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  DOMAIN_CORE_REQUIRED_JOB_IDS,
  DOMAIN_CORE_REQUIRED_SUITES,
} from "./domain-core-deterministic-candidate-bundle.mjs";
import {
  aggregateDomainCoreProofFragments,
  createDomainCoreProofFragment,
  sha256Artifact,
} from "./domain-core-proof-fragments.mjs";

import { readFileSync } from "node:fs";

const POLICY = JSON.parse(
  readFileSync(new URL("../../config/domain-core-promotion-policy.json", import.meta.url)),
);
const CANDIDATE = {
  candidateCommit: "a".repeat(40),
  coreVersion: "0.1.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};
const RUN = { runId: 42, runAttempt: 2, headSha: CANDIDATE.candidateCommit };

function fixture(context) {
  const root = mkdtempSync(join(tmpdir(), "domain-core-fragments-"));
  context.after(() => rmSync(root, { recursive: true, force: true }));
  const report = join(root, "report.log");
  const artifact = join(root, "artifact.bin");
  const benchmark = join(root, "benchmark.json");
  writeFileSync(report, "real test command passed\n");
  writeFileSync(artifact, "artifact bytes\n");
  writeFileSync(benchmark, '{"baselineNanos":1000,"candidateNanos":1049}\n');
  return { root, report, artifact, benchmark };
}

function fragments(paths) {
  return DOMAIN_CORE_REQUIRED_JOB_IDS.map((jobId) => {
    const suites = DOMAIN_CORE_REQUIRED_SUITES.filter((suite) => suite.jobId === jobId).map(
      ({ id }) => ({ id, reportPath: paths.report }),
    );
    const artifacts = POLICY.requiredArtifacts
      .filter((artifact) => artifact.jobId === jobId)
      .map(({ id }) => ({ id, path: paths.artifact }));
    const benchmarks = POLICY.requiredBenchmarks
      .filter((benchmark) => benchmark.jobId === jobId)
      .map(({ id }) => ({ id, reportPath: paths.benchmark }));
    const rollback =
      jobId === POLICY.rollback.jobId
        ? { reportPath: paths.report, restoredArtifactPath: paths.artifact }
        : null;
    return createDomainCoreProofFragment({
      jobId,
      ...RUN,
      candidate: CANDIDATE,
      suites,
      artifacts,
      benchmarks,
      rollback,
      policy: POLICY,
    });
  });
}

function jobResults() {
  return Object.fromEntries(DOMAIN_CORE_REQUIRED_JOB_IDS.map((id) => [id, { result: "success" }]));
}

test("strict fragments aggregate every policy suite, artifact, benchmark, and coverage cell", (context) => {
  const paths = fixture(context);
  const evidence = aggregateDomainCoreProofFragments({
    fragments: fragments(paths),
    jobResults: jobResults(),
    candidate: CANDIDATE,
    runId: RUN.runId,
    runAttempt: RUN.runAttempt,
    policy: POLICY,
  });
  assert.equal(evidence.jobs.length, 12);
  assert.equal(evidence.suites.length, 19);
  assert.equal(evidence.artifacts.length, 5);
  assert.equal(evidence.benchmarks[0].pairedRegressionBasisPoints, 490);
  assert.equal(evidence.coverage.length, 38);
  assert.equal(evidence.rollback.restoredMode, "legacy");
});

test("candidate identity comparison is independent of JSON object key order", (context) => {
  const paths = fixture(context);
  const values = fragments(paths);
  values[0].candidate = {
    sourceSha256: CANDIDATE.sourceSha256,
    abiVersion: CANDIDATE.abiVersion,
    coreVersion: CANDIDATE.coreVersion,
    candidateCommit: CANDIDATE.candidateCommit,
  };
  assert.doesNotThrow(() =>
    aggregateDomainCoreProofFragments({
      fragments: values,
      jobResults: jobResults(),
      candidate: CANDIDATE,
      runId: RUN.runId,
      runAttempt: RUN.runAttempt,
      policy: POLICY,
    }),
  );
});

test("aggregation rejects missing, skipped, stale, duplicate, and cross-candidate evidence", (context) => {
  const paths = fixture(context);
  const cases = [
    (values, results) => values.pop(),
    (values, results) => values.push(structuredClone(values[0])),
    (values, results) => (results.android.result = "skipped"),
    (values, results) => (values[0].runAttempt = 1),
    (values, results) => (values[0].candidate.sourceSha256 = "c".repeat(64)),
  ];
  for (const mutate of cases) {
    const values = fragments(paths);
    const results = jobResults();
    mutate(values, results);
    assert.throws(() =>
      aggregateDomainCoreProofFragments({
        fragments: values,
        jobResults: results,
        candidate: CANDIDATE,
        runId: RUN.runId,
        runAttempt: RUN.runAttempt,
        policy: POLICY,
      }),
    );
  }
});

test("artifact hashing is stable, path-sensitive, and rejects symlinks", (context) => {
  const paths = fixture(context);
  const tree = join(paths.root, "tree");
  mkdirSync(join(tree, "nested"), { recursive: true });
  writeFileSync(join(tree, "nested", "value"), "one");
  const first = sha256Artifact(tree);
  writeFileSync(join(tree, "nested", "value"), "two");
  assert.notEqual(sha256Artifact(tree), first);
  symlinkSync(paths.artifact, join(tree, "link"));
  assert.throws(() => sha256Artifact(tree), /symlinks/u);
});
