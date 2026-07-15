#!/usr/bin/env node

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";

import {
  DOMAIN_CORE_REQUIRED_JOB_IDS,
  evaluateUnsignedDeterministicCandidateBundle,
} from "../lib/domain-core-deterministic-candidate-bundle.mjs";
import { resolveDomainCoreCandidateIdentity } from "../lib/domain-core-candidate-receipt.mjs";
import {
  aggregateDomainCoreProofFragments,
  loadFragments,
  sha256Artifact,
  sha256File,
} from "../lib/domain-core-proof-fragments.mjs";
import { verifyDomainCoreControlPlane } from "./verify-domain-core-control-plane.mjs";

const FULL_SHA = /^[0-9a-f]{40}$/u;
const TRUSTED_REPO_ROOT = resolve(fileURLToPath(new URL("../..", import.meta.url)));
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
    "--attestation-inputs",
    "--candidate-repo",
    "--expected-candidate-commit",
    "--jobs",
    "--output",
    "--policy",
    "--proof-fragments",
    "--rollback-artifact",
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

function evidenceKey(value) {
  return value.id ?? [value.domain, value.slice, value.consumer, value.suiteId].join("\0");
}

function sameEvidence(actual, expected) {
  if (!Array.isArray(actual) || !Array.isArray(expected)) return isDeepStrictEqual(actual, expected);
  const byEvidenceKey = (left, right) => evidenceKey(left).localeCompare(evidenceKey(right));
  return isDeepStrictEqual([...actual].sort(byEvidenceKey), [...expected].sort(byEvidenceKey));
}

export function verifyDownloadedEvidence({ bundle, policy, proofFragments, attestationInputs, rollbackArtifact }) {
  const jobResults = Object.fromEntries(
    bundle.workflow.jobs.map(({ id, conclusion }) => [id, { result: conclusion }]),
  );
  const aggregated = aggregateDomainCoreProofFragments({
    fragments: loadFragments(proofFragments),
    jobResults,
    candidate: bundle.candidate,
    runId: bundle.workflow.runId,
    runAttempt: bundle.workflow.runAttempt,
    policy,
  });
  if (!sameEvidence(aggregated.jobs, bundle.workflow.jobs)) {
    throw new Error("downloaded proof fragments do not reproduce bundle.workflow.jobs");
  }
  for (const key of ["suites", "coverage", "artifacts", "benchmarks", "rollback"]) {
    if (!sameEvidence(aggregated[key], bundle[key])) {
      throw new Error(`downloaded proof fragments do not reproduce bundle.${key}`);
    }
  }
  const attestationRoot = resolve(attestationInputs);
  const expectedArchives = bundle.artifacts
    .map(({ id }) => `domain-core-attestation-${id}-${bundle.workflow.runId}-${bundle.workflow.runAttempt}`)
    .sort();
  const actualArchives = readdirSync(attestationRoot).sort();
  if (!isDeepStrictEqual(actualArchives, expectedArchives)) {
    throw new Error("downloaded artifact identity archive set does not exactly match the bundle");
  }
  for (const artifact of bundle.artifacts) {
    const root = join(
      attestationRoot,
      `domain-core-attestation-${artifact.id}-${bundle.workflow.runId}-${bundle.workflow.runAttempt}`,
    );
    if (!isDeepStrictEqual(readdirSync(root).sort(), ["artifact", "observed-identity.json"])) {
      throw new Error(`${artifact.id} archive must contain exactly artifact and observed-identity.json`);
    }
    const artifactPath = join(root, "artifact");
    const reportPath = join(root, "observed-identity.json");
    if (sha256Artifact(artifactPath) !== artifact.artifactSha256) {
      throw new Error(`${artifact.id} downloaded artifact bytes do not match proof`);
    }
    if (sha256File(reportPath) !== artifact.identityReportSha256) {
      throw new Error(`${artifact.id} observed identity report does not match proof`);
    }
    sameIdentity(readJson(reportPath, `${artifact.id} observed identity`), bundle.candidate, `${artifact.id}.observedIdentity`);
  }
  if (sha256Artifact(rollbackArtifact) !== bundle.rollback.restoredArtifactSha256) {
    throw new Error("downloaded rollback artifact bytes do not match proof");
  }
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
  if (!Number.isSafeInteger(jobsResponse.total_count) || jobsResponse.total_count < 0) {
    throw new Error("GitHub jobs response total_count must be a non-negative integer");
  }
  if (jobsResponse.total_count !== jobsResponse.jobs.length) {
    throw new Error("GitHub jobs response is incomplete; all pagination pages are required");
  }
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
  verifyDomainCoreControlPlane({
    trustedRoot: TRUSTED_REPO_ROOT,
    candidateRoot: resolve(args.get("--candidate-repo")),
    manifest: readJson(
      resolve(TRUSTED_REPO_ROOT, "config/domain-core-control-plane-manifest.json"),
      "trusted control-plane manifest",
    ),
  });
  const verifiedCandidateIdentity = resolveDomainCoreCandidateIdentity({
    repoRoot: args.get("--candidate-repo"),
    expectedCandidateCommit,
    requireClean: true,
    verifyArtifactIdentity: true,
    unionGatePath: resolve(TRUSTED_REPO_ROOT, "scripts/ci/domain-core-union-gate.py"),
  });
  const bundle = readJson(args.get("--bundle"), "bundle");
  const policy = readJson(args.get("--policy"), "policy");
  verifyDownloadedEvidence({
    bundle,
    policy,
    proofFragments: args.get("--proof-fragments"),
    attestationInputs: args.get("--attestation-inputs"),
    rollbackArtifact: args.get("--rollback-artifact"),
  });
  const verification = verifyProtectedAttestationInputs({
    bundle,
    policy,
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
