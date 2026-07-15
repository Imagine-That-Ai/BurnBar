import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { parseArguments } from "./create-domain-core-deterministic-candidate-bundle.mjs";
import {
  deterministicPolicySha256,
  DOMAIN_CORE_REQUIRED_ARTIFACTS,
  DOMAIN_CORE_REQUIRED_JOB_IDS,
  DOMAIN_CORE_REQUIRED_SUITES,
  evaluateUnsignedDeterministicCandidateBundle,
} from "../lib/domain-core-deterministic-candidate-bundle.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, "../..");
const CLI = join(
  SCRIPT_DIR,
  "create-domain-core-deterministic-candidate-bundle.mjs",
);
const POLICY = JSON.parse(
  readFileSync(
    join(REPO_ROOT, "config/domain-core-promotion-policy.json"),
    "utf8",
  ),
);
const GENERATED_AT = "2026-07-14T18:00:00.000Z";
const SOURCE_SHA = "a".repeat(64);

function digest(value) {
  return createHash("sha256").update(value).digest("hex");
}

function git(repo, ...args) {
  return execFileSync("git", ["-C", repo, ...args], {
    encoding: "utf8",
  }).trim();
}

function evidence(candidate) {
  const suites = DOMAIN_CORE_REQUIRED_SUITES.map(({ id, jobId }) => ({
    id,
    jobId,
    runId: 123456,
    runAttempt: 1,
    reportSha256: digest(`suite:${id}`),
    candidate: structuredClone(candidate),
  }));
  const suiteById = new Map(suites.map((suite) => [suite.id, suite]));
  return {
    jobs: DOMAIN_CORE_REQUIRED_JOB_IDS.map((id) => ({
      id,
      status: "completed",
      conclusion: "success",
    })),
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
        loadedIdentity: structuredClone(candidate),
        loadSuiteIds: [...requiredLoadSuiteIds],
      }),
    ),
    benchmarks: [
      {
        id: "complete-payload-ffi",
        jobId: "rust-and-csharp",
        runId: 123456,
        runAttempt: 1,
        reportSha256: digest("benchmark"),
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
      fromCandidateCommit: candidate.candidateCommit,
      restoredArtifactSha256: digest("legacy-artifact"),
      restoredMode: "legacy",
    },
  };
}

function fixture(context) {
  const root = mkdtempSync(join(tmpdir(), "domain-core-bundle-cli-"));
  context.after(() => rmSync(root, { recursive: true, force: true }));
  const repo = join(root, "repo");
  mkdirSync(join(repo, "crates/openburnbar-domain-core"), { recursive: true });
  mkdirSync(join(repo, "scripts/ci"), { recursive: true });
  writeFileSync(
    join(repo, "crates/openburnbar-domain-core/union-abi-manifest.json"),
    `${JSON.stringify({ coreVersion: "0.3.0", abiVersion: 3, sourceSha256: SOURCE_SHA })}\n`,
  );
  writeFileSync(
    join(repo, "scripts/ci/domain-core-union-gate.py"),
    `#!/usr/bin/env python3\nprint("${SOURCE_SHA}")\n`,
  );
  git(repo, "init", "--quiet");
  git(repo, "config", "user.email", "domain-core-test@example.invalid");
  git(repo, "config", "user.name", "Domain Core Test");
  git(repo, "add", ".");
  git(repo, "commit", "--quiet", "-m", "candidate");
  const candidateCommit = git(repo, "rev-parse", "HEAD");
  const candidate = {
    candidateCommit,
    coreVersion: "0.3.0",
    abiVersion: 3,
    sourceSha256: SOURCE_SHA,
  };
  const evidencePath = join(root, "evidence.json");
  const outputPath = join(root, "nested", "bundle.json");
  writeFileSync(evidencePath, JSON.stringify(evidence(candidate)));
  const environment = {
    ...process.env,
    GITHUB_ACTIONS: "true",
    GITHUB_REPOSITORY: POLICY.workflow.repository,
    GITHUB_WORKFLOW: POLICY.workflow.workflowName,
    GITHUB_WORKFLOW_REF:
      `${POLICY.workflow.repository}/${POLICY.workflow.workflowPath}` +
      `@${POLICY.workflow.requiredRef}`,
    GITHUB_EVENT_NAME: "push",
    GITHUB_REF: POLICY.workflow.requiredRef,
    GITHUB_SHA: candidateCommit,
    GITHUB_RUN_ID: "123456",
    GITHUB_RUN_ATTEMPT: "1",
  };
  return { repo, candidate, evidencePath, outputPath, environment };
}

function runCli(paths, overrides = {}) {
  return spawnSync(
    process.execPath,
    [
      CLI,
      "--repo-root",
      paths.repo,
      "--expected-candidate-commit",
      overrides.expectedCandidateCommit ?? paths.candidate.candidateCommit,
      "--evidence",
      paths.evidencePath,
      "--output",
      paths.outputPath,
      "--generated-at",
      GENERATED_AT,
    ],
    {
      cwd: REPO_ROOT,
      encoding: "utf8",
      env: { ...paths.environment, ...overrides.environment },
    },
  );
}

test("CLI arguments require an exact candidate commit and reject ambiguity", () => {
  assert.equal(
    parseArguments([
      "--expected-candidate-commit",
      "a".repeat(40),
      "--evidence",
      "evidence.json",
      "--output",
      "bundle.json",
    ]).output,
    "bundle.json",
  );
  for (const argv of [
    [],
    ["--expected-candidate-commit", "a", "--evidence", "b", "--output"],
    [
      "--expected-candidate-commit",
      "a",
      "--evidence",
      "b",
      "--output",
      "c",
      "--output",
      "d",
    ],
    [
      "--expected-candidate-commit",
      "a",
      "--evidence",
      "b",
      "--output",
      "c",
      "--candidate-receipt",
      "receipt.json",
    ],
  ]) {
    assert.throws(() => parseArguments(argv));
  }
});

test("CLI creates only an unsigned candidate bundle from a clean verified checkout", (context) => {
  const paths = fixture(context);
  const result = runCli(paths);
  assert.equal(result.status, 0, result.stderr);
  const bundle = JSON.parse(readFileSync(paths.outputPath, "utf8"));
  assert.equal(bundle.policySha256, deterministicPolicySha256(POLICY));
  assert.deepEqual(bundle.candidate, paths.candidate);
  const report = evaluateUnsignedDeterministicCandidateBundle(bundle, POLICY, {
    now: GENERATED_AT,
  });
  assert.equal(report.proofComplete, true);
  assert.equal(report.eligibleForAttestation, true);
  assert.equal(report.promotionAuthorized, false);
  assert.equal(Object.hasOwn(report, "ready"), false);
  assert.equal(bundle.trust.authority, "none");
  assert.equal(bundle.trust.attestationRequired, true);
  assert.equal(statSync(paths.outputPath).mode & 0o777, 0o600);
});

test("CLI rejects dirty source, wrong HEAD, non-push context, and incomplete evidence", (context) => {
  const paths = fixture(context);
  const cases = [
    () => {
      writeFileSync(join(paths.repo, "dirty.txt"), "dirty\n");
      return runCli(paths);
    },
    () => {
      rmSync(join(paths.repo, "dirty.txt"), { force: true });
      return runCli(paths, { expectedCandidateCommit: "f".repeat(40) });
    },
    () =>
      runCli(paths, {
        environment: {
          GITHUB_EVENT_NAME: "pull_request",
          GITHUB_REF: "refs/pull/123/merge",
        },
      }),
    () => {
      const value = evidence(paths.candidate);
      value.jobs[0].conclusion = "skipped";
      writeFileSync(paths.evidencePath, JSON.stringify(value));
      return runCli(paths);
    },
    () => {
      const value = evidence(paths.candidate);
      delete value.rollback;
      writeFileSync(paths.evidencePath, JSON.stringify(value));
      return runCli(paths);
    },
  ];
  for (const execute of cases) {
    rmSync(paths.outputPath, { force: true });
    const result = execute();
    assert.equal(result.status, 1);
    assert.equal(existsSync(paths.outputPath), false);
  }
});
