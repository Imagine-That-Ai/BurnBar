import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  deterministicPolicySha256,
  DOMAIN_CORE_REQUIRED_ARTIFACTS,
  DOMAIN_CORE_REQUIRED_JOB_IDS,
  DOMAIN_CORE_REQUIRED_SUITES,
} from "../lib/domain-core-deterministic-candidate-bundle.mjs";
import { verifyProtectedAttestationInputs } from "./verify-domain-core-protected-attestation.mjs";

const POLICY = JSON.parse(
  readFileSync(new URL("../../config/domain-core-promotion-policy.json", import.meta.url)),
);
const CANDIDATE = {
  candidateCommit: "a".repeat(40),
  coreVersion: "0.1.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};
const RUN_ID = 123456;
const RUN_ATTEMPT = 2;
const EXPECTED_JOB_NAMES = [
  ...DOMAIN_CORE_REQUIRED_JOB_IDS.filter((id) => id !== "windows-native"),
  "windows-native-win-x64",
  "windows-native-win-arm64",
  "candidate-bundle",
];

function digest(value) {
  return createHash("sha256").update(value).digest("hex");
}

function bundle() {
  const suites = DOMAIN_CORE_REQUIRED_SUITES.map(({ id, jobId }) => ({
    id,
    jobId,
    runId: RUN_ID,
    runAttempt: RUN_ATTEMPT,
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
    generatedAt: new Date().toISOString(),
    candidate: structuredClone(CANDIDATE),
    policySha256: deterministicPolicySha256(POLICY),
    workflow: {
      repository: POLICY.workflow.repository,
      workflowPath: POLICY.workflow.workflowPath,
      workflowName: POLICY.workflow.workflowName,
      runId: RUN_ID,
      runAttempt: RUN_ATTEMPT,
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
        runId: RUN_ID,
        runAttempt: RUN_ATTEMPT,
        artifactSha256: digest(`artifact:${id}`),
        loadedIdentity: structuredClone(CANDIDATE),
        loadSuiteIds: [...requiredLoadSuiteIds],
      }),
    ),
    benchmarks: [
      {
        id: "complete-payload-ffi",
        jobId: "rust-and-csharp",
        runId: RUN_ID,
        runAttempt: RUN_ATTEMPT,
        reportSha256: digest("benchmark"),
        baselineNanos: 1_000,
        candidateNanos: 1_049,
        pairedRegressionBasisPoints: 490,
      },
    ],
    rollback: {
      jobId: "rollback-drill",
      suiteId: "rollback-drill",
      runId: RUN_ID,
      runAttempt: RUN_ATTEMPT,
      reportSha256: suiteById.get("rollback-drill").reportSha256,
      fromCandidateCommit: CANDIDATE.candidateCommit,
      restoredArtifactSha256: digest("legacy-artifact"),
      restoredMode: "legacy",
    },
  };
}

function githubRun() {
  return {
    id: RUN_ID,
    run_attempt: RUN_ATTEMPT,
    event: "push",
    head_branch: "main",
    head_sha: CANDIDATE.candidateCommit,
    path: POLICY.workflow.workflowPath,
    status: "completed",
    conclusion: "success",
    repository: { full_name: POLICY.workflow.repository },
  };
}

function jobsResponse() {
  return {
    jobs: EXPECTED_JOB_NAMES.map((name, index) => ({
      id: index + 1,
      name,
      run_id: RUN_ID,
      head_sha: CANDIDATE.candidateCommit,
      status: "completed",
      conclusion: "success",
    })),
  };
}

function verify(value = bundle(), run = githubRun(), jobs = jobsResponse()) {
  return verifyProtectedAttestationInputs({
    bundle: value,
    policy: POLICY,
    run,
    jobsResponse: jobs,
    expectedCandidateCommit: CANDIDATE.candidateCommit,
    verifiedCandidateIdentity: CANDIDATE,
  });
}

test("protected verifier independently accepts only an exact successful main push proof", () => {
  assert.equal(EXPECTED_JOB_NAMES.length, 14);
  const result = verify();
  assert.equal(result.promotionAuthorized, false);
  assert.equal(result.sourceRun.runId, RUN_ID);
  assert.equal(result.protectedEnvironmentRequired, "domain-core-promotion");
});

test("protected verifier rejects dispatch/PR runs, failed or missing jobs, and candidate drift", () => {
  const cases = [
    () => {
      const run = githubRun();
      run.event = "workflow_dispatch";
      return [bundle(), run, jobsResponse()];
    },
    () => {
      const jobs = jobsResponse();
      jobs.jobs[0].conclusion = "skipped";
      return [bundle(), githubRun(), jobs];
    },
    () => {
      const jobs = jobsResponse();
      jobs.jobs.pop();
      return [bundle(), githubRun(), jobs];
    },
    () => {
      const jobs = jobsResponse();
      jobs.jobs.push({ ...jobs.jobs[0], id: 999, name: "untrusted-extra" });
      return [bundle(), githubRun(), jobs];
    },
    () => {
      const jobs = jobsResponse();
      jobs.jobs.push({ ...jobs.jobs[0], id: 999 });
      return [bundle(), githubRun(), jobs];
    },
    () => {
      const value = bundle();
      value.candidate.sourceSha256 = "c".repeat(64);
      return [value, githubRun(), jobsResponse()];
    },
    () => {
      const value = bundle();
      value.promotionAuthorized = true;
      return [value, githubRun(), jobsResponse()];
    },
  ];
  for (const build of cases) assert.throws(() => verify(...build()));
});
