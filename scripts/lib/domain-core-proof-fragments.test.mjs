import assert from "node:assert/strict";
import {
  chmodSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
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
  const identityReport = join(root, "observed-identity.json");
  writeFileSync(report, "real test command passed\n");
  writeFileSync(artifact, "artifact bytes\n");
  writeFileSync(benchmark, '{"baselineNanos":1000,"candidateNanos":1049}\n');
  writeFileSync(identityReport, `${JSON.stringify(CANDIDATE)}\n`);
  return { root, report, artifact, benchmark, identityReport };
}

function fragments(paths) {
  return DOMAIN_CORE_REQUIRED_JOB_IDS.flatMap((jobId) => {
    const suites = DOMAIN_CORE_REQUIRED_SUITES.filter((suite) => suite.jobId === jobId).map(
      ({ id }) => ({ id, reportPath: paths.report }),
    );
    const artifacts = POLICY.requiredArtifacts
      .filter((artifact) => artifact.jobId === jobId)
      .map(({ id }) => ({ id, path: paths.artifact, identityReportPath: paths.identityReport }));
    const benchmarks = POLICY.requiredBenchmarks
      .filter((benchmark) => benchmark.jobId === jobId)
      .map(({ id }) => ({ id, reportPath: paths.benchmark }));
    const rollback =
      jobId === POLICY.rollback.jobId
        ? { reportPath: paths.report, restoredArtifactPath: paths.artifact }
        : null;
    const partitions =
      jobId === "windows-native"
        ? POLICY.requiredArtifacts
            .filter(({ jobId: artifactJobId }) => artifactJobId === jobId)
            .map((required) => ({
              suites: suites.filter(({ id }) => required.requiredLoadSuiteIds.includes(id)),
              artifacts: artifacts.filter(({ id }) => id === required.id),
            }))
        : [{ suites, artifacts }];
    return partitions.map((partition) =>
      createDomainCoreProofFragment({
        jobId,
        ...RUN,
        candidate: CANDIDATE,
        ...partition,
        benchmarks,
        rollback,
        policy: POLICY,
      }),
    );
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
  assert.equal(evidence.jobs.length, 13);
  assert.equal(evidence.suites.length, 21);
  assert.equal(evidence.artifacts.length, 9);
  assert.equal(evidence.benchmarks[0].pairedRegressionBasisPoints, 490);
  assert.equal(evidence.coverage.length, 46);
  assert.equal(evidence.rollback.restoredMode, "legacy");
});

test("artifact identity must be observed and cannot be assigned from the candidate", (context) => {
  const paths = fixture(context);
  writeFileSync(paths.identityReport, `${JSON.stringify({ ...CANDIDATE, sourceSha256: "c".repeat(64) })}\n`);
  assert.throws(() => fragments(paths), /observed identity does not match/u);
  rmSync(paths.identityReport);
  assert.throws(() => fragments(paths), /unreadable/u);
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

  const withEmptyDuplicate = fragments(paths);
  const results = jobResults();
  withEmptyDuplicate.push({
    ...structuredClone(withEmptyDuplicate[0]),
    suites: [],
    artifacts: [],
    benchmarks: [],
    rollback: null,
  });
  assert.throws(
    () =>
      aggregateDomainCoreProofFragments({
        fragments: withEmptyDuplicate,
        jobResults: results,
        candidate: CANDIDATE,
        runId: RUN.runId,
        runAttempt: RUN.runAttempt,
        policy: POLICY,
      }),
    /proof fragment job IDs/u,
  );
});

test("artifact hashing is byte/path exact, transport-mode stable, and rejects symlinks", (context) => {
  const paths = fixture(context);
  const tree = join(paths.root, "tree");
  mkdirSync(join(tree, "nested"), { recursive: true });
  writeFileSync(join(tree, "nested", "value"), "one");
  const first = sha256Artifact(tree);
  chmodSync(join(tree, "nested", "value"), 0o755);
  assert.equal(sha256Artifact(tree), first);
  renameSync(join(tree, "nested", "value"), join(tree, "nested", "renamed"));
  assert.notEqual(sha256Artifact(tree), first);
  renameSync(join(tree, "nested", "renamed"), join(tree, "nested", "value"));
  writeFileSync(join(tree, "nested", "value"), "two");
  assert.notEqual(sha256Artifact(tree), first);
  symlinkSync(paths.artifact, join(tree, "link"));
  assert.throws(() => sha256Artifact(tree), /symlinks/u);
});
