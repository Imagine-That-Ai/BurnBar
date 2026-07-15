#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  DOMAIN_CORE_REQUIRED_JOB_IDS,
  evaluateUnsignedDeterministicCandidateBundle,
} from "../lib/domain-core-deterministic-candidate-bundle.mjs";
import { resolveDomainCoreCandidateIdentity } from "../lib/domain-core-candidate-receipt.mjs";

const FULL_SHA = /^[0-9a-f]{40}$/u;
const EXPECTED_JOB_NAMES = Object.freeze([
  ...DOMAIN_CORE_REQUIRED_JOB_IDS.filter((id) => id !== "windows-native"),
  "windows-native-win-x64",
  "windows-native-win-arm64",
  "candidate-bundle",
]);

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(resolve(path), "utf8"));
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

function argumentsMap(argv) {
  const allowed = new Set([
    "--bundle",
    "--candidate-repo",
    "--expected-candidate-commit",
    "--jobs",
    "--output",
    "--policy",
    "--run",
  ]);
  const result = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag)) throw new Error(`unknown argument: ${String(flag)}`);
    if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
    if (result.has(flag)) throw new Error(`duplicate argument: ${flag}`);
    result.set(flag, value);
  }
  for (const flag of allowed) {
    if (!result.has(flag)) throw new Error(`${flag} is required`);
  }
  return result;
}

function sameIdentity(actual, expected, label) {
  for (const key of ["candidateCommit", "coreVersion", "abiVersion", "sourceSha256"]) {
    if (actual?.[key] !== expected[key]) throw new Error(`${label}.${key} does not match candidate`);
  }
}

export function verifyProtectedAttestationInputs({
  bundle,
  policy,
  run,
  jobsResponse,
  expectedCandidateCommit,
  verifiedCandidateIdentity,
}) {
  if (!FULL_SHA.test(expectedCandidateCommit)) {
    throw new Error("expected candidate commit must be a full lowercase Git SHA-1");
  }
  sameIdentity(bundle.candidate, verifiedCandidateIdentity, "bundle.candidate");
  if (expectedCandidateCommit !== verifiedCandidateIdentity.candidateCommit) {
    throw new Error("verified candidate checkout does not match requested candidate");
  }
  const report = evaluateUnsignedDeterministicCandidateBundle(bundle, policy);
  if (!report.proofComplete || !report.eligibleForAttestation) {
    throw new Error(`unsigned bundle failed trusted evaluation: ${(report.errors ?? []).join("; ")}`);
  }
  if (report.promotionAuthorized !== false || bundle.promotionAuthorized !== false) {
    throw new Error("unsigned candidate bundle cannot assert promotion authority");
  }
  const expectedRun = {
    id: bundle.workflow.runId,
    run_attempt: bundle.workflow.runAttempt,
    event: "push",
    head_branch: "main",
    head_sha: expectedCandidateCommit,
    path: policy.workflow.workflowPath,
    status: "completed",
    conclusion: "success",
  };
  for (const [key, value] of Object.entries(expectedRun)) {
    if (run?.[key] !== value) throw new Error(`GitHub run ${key} must equal ${value}`);
  }
  if (run.repository?.full_name !== policy.workflow.repository) {
    throw new Error("GitHub run repository does not match policy");
  }
  if (!Array.isArray(jobsResponse?.jobs)) throw new Error("GitHub jobs response must contain jobs");
  const jobsByName = new Map();
  for (const job of jobsResponse.jobs) {
    if (job.run_id !== run.id || job.head_sha !== expectedCandidateCommit) {
      throw new Error(`GitHub job ${String(job.name)} is not bound to the exact run and candidate`);
    }
    if (job.status !== "completed" || job.conclusion !== "success") {
      throw new Error(`GitHub job ${String(job.name)} did not complete successfully`);
    }
    const entries = jobsByName.get(job.name) ?? [];
    entries.push(job);
    jobsByName.set(job.name, entries);
  }
  for (const name of EXPECTED_JOB_NAMES) {
    if ((jobsByName.get(name) ?? []).length !== 1) {
      throw new Error(`GitHub API must report exactly one successful ${name} job`);
    }
  }
  for (const name of jobsByName.keys()) {
    if (!EXPECTED_JOB_NAMES.includes(name)) {
      throw new Error(`GitHub API reported unexpected job ${name}`);
    }
  }
  return {
    schemaVersion: 1,
    verificationKind: "protected-domain-core-attestation-input",
    promotionAuthorized: false,
    candidate: verifiedCandidateIdentity,
    sourceRun: {
      repository: policy.workflow.repository,
      workflowPath: policy.workflow.workflowPath,
      runId: run.id,
      runAttempt: run.run_attempt,
      event: run.event,
      ref: policy.workflow.requiredRef,
      headSha: run.head_sha,
    },
    unsignedBundleStatus: report.status,
    protectedEnvironmentRequired: "domain-core-promotion",
  };
}

export function run(argv) {
  const args = argumentsMap(argv);
  const expectedCandidateCommit = args.get("--expected-candidate-commit");
  const verifiedCandidateIdentity = resolveDomainCoreCandidateIdentity({
    repoRoot: args.get("--candidate-repo"),
    expectedCandidateCommit,
    requireClean: true,
    verifyArtifactIdentity: true,
  });
  const verification = verifyProtectedAttestationInputs({
    bundle: readJson(args.get("--bundle"), "bundle"),
    policy: readJson(args.get("--policy"), "policy"),
    run: readJson(args.get("--run"), "GitHub run"),
    jobsResponse: readJson(args.get("--jobs"), "GitHub jobs"),
    expectedCandidateCommit,
    verifiedCandidateIdentity,
  });
  writeFileSync(args.get("--output"), `${JSON.stringify(verification, null, 2)}\n`, {
    mode: 0o600,
  });
  return verification;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
