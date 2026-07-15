import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  createUnsignedDeterministicCandidateBundle,
  deterministicPolicySha256,
  DOMAIN_CORE_REQUIRED_ARTIFACTS,
  DOMAIN_CORE_REQUIRED_JOB_IDS,
  DOMAIN_CORE_REQUIRED_SUITES,
  evaluateUnsignedDeterministicCandidateBundle,
  pairedRegressionBasisPoints,
  validateDeterministicPromotionPolicy,
} from "./domain-core-deterministic-candidate-bundle.mjs";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const POLICY = JSON.parse(
  readFileSync(join(REPO_ROOT, "config/domain-core-promotion-policy.json"), "utf8"),
);
const DIAGNOSTIC_POLICY = JSON.parse(
  readFileSync(
    join(REPO_ROOT, "config/domain-core-shadow-diagnostic-policy.json"),
    "utf8",
  ),
);
const CANDIDATE = Object.freeze({
  candidateCommit: "0123456789abcdef0123456789abcdef01234567",
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "a".repeat(64),
});
const NOW = "2026-07-14T18:00:00.000Z";

function digest(value) {
  return createHash("sha256").update(value).digest("hex");
}

function validBundle() {
  const suites = DOMAIN_CORE_REQUIRED_SUITES.map(({ id, jobId }) => ({
    id,
    jobId,
    runId: 123456,
    runAttempt: 1,
    reportSha256: digest(`suite:${id}`),
    candidate: structuredClone(CANDIDATE),
  }));
  const suiteById = new Map(suites.map((suite) => [suite.id, suite]));
  return {
    schemaVersion: 1,
    bundleKind: "unsigned-domain-core-candidate",
    status: "eligible_for_attestation",
    proofComplete: true,
    eligibleForAttestation: true,
    promotionAuthorized: false,
    trust: {
      authority: "none",
      attestationRequired: true,
      requiredSigner: "protected-domain-core-signer",
      verificationSteps: [
        "query-github-api",
        "download-exact-run-artifacts",
        "revalidate-with-trusted-main",
        "sign-protected-attestation",
      ],
    },
    generatedAt: NOW,
    candidate: structuredClone(CANDIDATE),
    policySha256: deterministicPolicySha256(POLICY),
    workflow: {
      repository: POLICY.workflow.repository,
      workflowPath: POLICY.workflow.workflowPath,
      workflowName: POLICY.workflow.workflowName,
      runId: 123456,
      runAttempt: 1,
      event: "push",
      ref: "refs/heads/main",
      headSha: CANDIDATE.candidateCommit,
      jobs: DOMAIN_CORE_REQUIRED_JOB_IDS.map((id) => ({
        id,
        status: "completed",
        conclusion: "success",
      })),
    },
    suites,
    coverage: Object.entries(POLICY.domains).flatMap(([domain, value]) =>
      value.requiredCoverage.map(({ slice, consumer, suiteId }) => ({
        domain,
        slice,
        consumer,
        suiteId,
        reportSha256: suiteById.get(suiteId).reportSha256,
      })),
    ),
    artifacts: DOMAIN_CORE_REQUIRED_ARTIFACTS.map(
      ({ id, consumer, jobId, requiredLoadSuiteIds }) => ({
        id,
        consumer,
        jobId,
        runId: 123456,
        runAttempt: 1,
        artifactSha256: digest(`artifact:${id}`),
        identityReportSha256: digest(`identity:${id}`),
        loadedIdentity: structuredClone(CANDIDATE),
        loadSuiteIds: [...requiredLoadSuiteIds],
      }),
    ),
    benchmarks: [
      {
        id: "complete-payload-ffi",
        jobId: "rust-and-csharp",
        runId: 123456,
        runAttempt: 1,
        reportSha256: digest("benchmark:complete-payload-ffi"),
        baselineNanos: 1_000,
        candidateNanos: 1_050,
        pairedRegressionBasisPoints: 500,
      },
    ],
    rollback: {
      jobId: "rollback-drill",
      suiteId: "rollback-drill",
      runId: 123456,
      runAttempt: 1,
      reportSha256: suiteById.get("rollback-drill").reportSha256,
      fromCandidateCommit: CANDIDATE.candidateCommit,
      restoredArtifactSha256: digest("rollback:legacy-artifact"),
      restoredMode: "legacy",
    },
  };
}

function evaluate(bundle, policy = POLICY) {
  return evaluateUnsignedDeterministicCandidateBundle(bundle, policy, { now: NOW });
}

test("schema-3 policy is canonical and covers all 38 real cells", () => {
  assert.deepEqual(validateDeterministicPromotionPolicy(POLICY), []);
  assert.equal(
    Object.values(POLICY.domains).reduce(
      (count, domain) => count + domain.requiredCoverage.length,
      0,
    ),
    38,
  );
  assert.equal(POLICY.maximumPairedRegressionBasisPoints, 500);
  assert.deepEqual(POLICY.workflow.allowedEvents, ["push"]);
  assert.equal(POLICY.promotionAuthority, false);
  assert.equal(POLICY.protectedAttestationRequired, true);
  assert.equal(POLICY.rollbackRequired, true);
  assert.equal(POLICY.oneStableReleaseBeforeDeletion, true);
  assert.equal(POLICY.stableReleaseRollbackArtifactRequired, true);
});

test("shadow telemetry is explicitly non-authoritative and has no time or sample targets", () => {
  assert.equal(DIAGNOSTIC_POLICY.authority, "diagnostic-only");
  assert.equal(DIAGNOSTIC_POLICY.promotionAuthority, false);
  const serialized = JSON.stringify(DIAGNOSTIC_POLICY);
  for (const forbidden of [
    "minimumCoverageSeconds",
    "minimumSamples",
    "ObservationTarget",
    "SampleTarget",
    "1209600",
    "10000",
  ]) {
    assert.equal(serialized.includes(forbidden), false, forbidden);
  }
  assert.notEqual(deterministicPolicySha256(DIAGNOSTIC_POLICY), deterministicPolicySha256(POLICY));
});

test("complete deterministic evidence is only eligible for protected attestation", () => {
  const bundle = validBundle();
  const report = evaluate(bundle);
  assert.equal(report.status, "eligible_for_attestation");
  assert.equal(report.proofComplete, true);
  assert.equal(report.eligibleForAttestation, true);
  assert.equal(report.promotionAuthorized, false);
  assert.equal(Object.hasOwn(report, "ready"), false);
  assert.equal(bundle.promotionAuthorized, false);
  assert.equal(report.coverageCellCount, 38);
  assert.equal(report.stableReleaseRequiredBeforeDeletion, true);
  assert.equal(report.stableReleaseRollbackArtifactRequiredBeforeDeletion, true);
  assert.deepEqual(report.candidate, CANDIDATE);
});

test("creator binds a verified checkout identity and remains unsigned", () => {
  const complete = validBundle();
  const evidence = {
    jobs: complete.workflow.jobs,
    suites: complete.suites,
    coverage: complete.coverage,
    artifacts: complete.artifacts,
    benchmarks: complete.benchmarks,
    rollback: complete.rollback,
  };
  const { jobs: _jobs, ...workflow } = complete.workflow;
  const bundle = createUnsignedDeterministicCandidateBundle({
    verifiedCandidateIdentity: structuredClone(CANDIDATE),
    workflow,
    evidence,
    policy: POLICY,
    generatedAt: NOW,
  });
  assert.equal(bundle.policySha256, deterministicPolicySha256(POLICY));
  assert.deepEqual(bundle.candidate, CANDIDATE);
  assert.equal(evaluate(bundle).eligibleForAttestation, true);
  assert.equal(evaluate(bundle).promotionAuthorized, false);
});

test("policy cannot weaken exact jobs, suites, artifacts, cells, rollback, or performance", () => {
  const mutations = [
    (policy) => policy.workflow.allowedEvents.push("workflow_dispatch"),
    (policy) => (policy.promotionAuthority = true),
    (policy) => (policy.protectedAttestationRequired = false),
    (policy) => policy.workflow.requiredJobIds.pop(),
    (policy) => policy.requiredSuites.pop(),
    (policy) => policy.requiredArtifacts.pop(),
    (policy) => policy.domains.cloudvault.requiredCoverage.pop(),
    (policy) => (policy.maximumPairedRegressionBasisPoints = 501),
    (policy) => (policy.rollbackRequired = false),
    (policy) => (policy.oneStableReleaseBeforeDeletion = false),
    (policy) => (policy.stableReleaseRollbackArtifactRequired = false),
  ];
  for (const mutate of mutations) {
    const policy = structuredClone(POLICY);
    mutate(policy);
    assert.notDeepEqual(validateDeterministicPromotionPolicy(policy), []);
    assert.equal(evaluate(validBundle(), policy).eligibleForAttestation, false);
  }
});

test("job set is exact and skipped, failed, or PR jobs never promote", () => {
  const cases = [
    (bundle) => bundle.workflow.jobs.pop(),
    (bundle) => bundle.workflow.jobs.push({ id: "extra", status: "completed", conclusion: "success" }),
    (bundle) => (bundle.workflow.jobs[0].status = "queued"),
    (bundle) => (bundle.workflow.jobs[0].conclusion = "skipped"),
    (bundle) => (bundle.workflow.jobs[0].conclusion = "failure"),
    (bundle) => (bundle.workflow.event = "pull_request"),
    (bundle) => (bundle.workflow.ref = "refs/pull/123/merge"),
    (bundle) => (bundle.workflow.headSha = "f".repeat(40)),
  ];
  for (const mutate of cases) {
    const bundle = validBundle();
    mutate(bundle);
    assert.equal(evaluate(bundle).eligibleForAttestation, false);
  }
});

test("suite, coverage, and artifact sets reject missing, extra, duplicate, or relabeled evidence", () => {
  const mutations = [
    (bundle) => bundle.suites.pop(),
    (bundle) => bundle.suites.push(structuredClone(bundle.suites[0])),
    (bundle) => bundle.coverage.pop(),
    (bundle) => bundle.coverage.push({ ...bundle.coverage[0], slice: "invented" }),
    (bundle) => bundle.coverage.push(structuredClone(bundle.coverage[0])),
    (bundle) => (bundle.coverage[0].suiteId = "rust-workspace"),
    (bundle) => (bundle.coverage[0].reportSha256 = "f".repeat(64)),
    (bundle) => bundle.artifacts.pop(),
    (bundle) => bundle.artifacts.push(structuredClone(bundle.artifacts[0])),
    (bundle) => (bundle.artifacts[0].consumer = "kotlin"),
    (bundle) => bundle.artifacts[0].loadSuiteIds.pop(),
  ];
  for (const mutate of mutations) {
    const bundle = validBundle();
    mutate(bundle);
    assert.equal(evaluate(bundle).eligibleForAttestation, false);
  }
});

test("every reported and loaded candidate tuple must match exactly", () => {
  const mutations = [
    (bundle) => (bundle.workflow.headSha = "b".repeat(40)),
    (bundle) => (bundle.suites[0].candidate.coreVersion = "0.3.1"),
    (bundle) => (bundle.suites[0].candidate.abiVersion = 4),
    (bundle) => (bundle.suites[0].candidate.sourceSha256 = "b".repeat(64)),
    (bundle) => (bundle.suites[0].runId = 654321),
    (bundle) => (bundle.artifacts[0].loadedIdentity.candidateCommit = "b".repeat(40)),
    (bundle) => (bundle.artifacts[0].loadedIdentity.coreVersion = "0.3.1"),
    (bundle) => (bundle.artifacts[0].loadedIdentity.abiVersion = 4),
    (bundle) => (bundle.artifacts[0].loadedIdentity.sourceSha256 = "b".repeat(64)),
    (bundle) => (bundle.artifacts[0].runAttempt = 2),
  ];
  for (const mutate of mutations) {
    const bundle = validBundle();
    mutate(bundle);
    assert.equal(evaluate(bundle).eligibleForAttestation, false);
  }
});

test("stale policy and hand-authored authorization never authorize promotion", () => {
  const stale = validBundle();
  stale.policySha256 = "f".repeat(64);
  assert.equal(evaluate(stale).eligibleForAttestation, false);

  const asserted = validBundle();
  asserted.promotionAuthorized = true;
  assert.equal(evaluate(asserted).eligibleForAttestation, false);
  assert.equal(evaluate(asserted).promotionAuthorized, false);

  const perfectHandAuthoredBundle = validBundle();
  const report = evaluate(perfectHandAuthoredBundle);
  assert.equal(report.proofComplete, true);
  assert.equal(report.eligibleForAttestation, true);
  assert.equal(report.promotionAuthorized, false);
  assert.equal(Object.hasOwn(report, "ready"), false);
});

test("benchmark is recomputed and enforces the paired 500bp ceiling", () => {
  assert.equal(pairedRegressionBasisPoints(1_000, 1_050), 500);
  assert.equal(pairedRegressionBasisPoints(1_000, 950), -500);

  const over = validBundle();
  over.benchmarks[0].candidateNanos = 1_051;
  over.benchmarks[0].pairedRegressionBasisPoints = 510;
  assert.equal(evaluate(over).eligibleForAttestation, false);

  const forged = validBundle();
  forged.benchmarks[0].candidateNanos = 1_051;
  forged.benchmarks[0].pairedRegressionBasisPoints = 500;
  assert.equal(evaluate(forged).eligibleForAttestation, false);

  const unsafe = validBundle();
  unsafe.benchmarks[0].baselineNanos = 1;
  unsafe.benchmarks[0].candidateNanos = Number.MAX_SAFE_INTEGER;
  unsafe.benchmarks[0].pairedRegressionBasisPoints = 0;
  assert.doesNotThrow(() => evaluate(unsafe));
  assert.equal(evaluate(unsafe).eligibleForAttestation, false);
});

test("rollback must be a candidate-bound report from the exact real suite", () => {
  const cases = [
    (bundle) => delete bundle.rollback,
    (bundle) => (bundle.rollback.jobId = "rust-and-csharp"),
    (bundle) => (bundle.rollback.suiteId = "rust-workspace"),
    (bundle) => (bundle.rollback.reportSha256 = "f".repeat(64)),
    (bundle) => (bundle.rollback.fromCandidateCommit = "f".repeat(40)),
    (bundle) => (bundle.rollback.runId = 654321),
    (bundle) => (bundle.rollback.restoredMode = "rust"),
  ];
  for (const mutate of cases) {
    const bundle = validBundle();
    mutate(bundle);
    assert.equal(evaluate(bundle).eligibleForAttestation, false);
  }
});

test("arbitrary malformed JSON values never throw or promote", () => {
  let state = 0x5eed1234;
  const random = () =>
    (state = (state * 1664525 + 1013904223) >>> 0) / 0x1_0000_0000;
  const scalar = () =>
    [null, true, false, random(), `value-${state}`, Number.MAX_SAFE_INTEGER + 1][
      Math.floor(random() * 6)
    ];
  for (let index = 0; index < 500; index += 1) {
    const value = random() < 0.5 ? scalar() : { [String(scalar())]: scalar() };
    assert.doesNotThrow(() => {
      const report = evaluate(value);
      assert.equal(report.eligibleForAttestation, false);
    });
  }
});
