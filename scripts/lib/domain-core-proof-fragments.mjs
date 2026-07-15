import { createHash } from "node:crypto";
import {
  lstatSync,
  readFileSync,
  readdirSync,
} from "node:fs";
import { basename, join, relative, resolve } from "node:path";

import {
  DOMAIN_CORE_REQUIRED_ARTIFACTS,
  DOMAIN_CORE_REQUIRED_JOB_IDS,
  DOMAIN_CORE_REQUIRED_SUITES,
  pairedRegressionBasisPoints,
  validateDeterministicPromotionPolicy,
} from "./domain-core-deterministic-candidate-bundle.mjs";
import { validateDomainCoreCandidateIdentity } from "./domain-core-candidate-receipt.mjs";

export const DOMAIN_CORE_PROOF_FRAGMENT_SCHEMA_VERSION = 1;

const POSITIVE_INTEGER = /^[1-9]\d*$/u;
const FRAGMENT_KEYS = new Set([
  "schemaVersion",
  "jobId",
  "runId",
  "runAttempt",
  "headSha",
  "candidate",
  "suites",
  "artifacts",
  "benchmarks",
  "rollback",
]);

function fail(message) {
  throw new Error(message);
}

function exactKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    fail(`${label} must contain exactly ${wanted.join(", ")}`);
  }
}

function positiveInteger(value, label) {
  const text = String(value ?? "");
  if (!POSITIVE_INTEGER.test(text)) fail(`${label} must be a positive integer`);
  const parsed = Number(text);
  if (!Number.isSafeInteger(parsed)) fail(`${label} exceeds the safe integer range`);
  return parsed;
}

export function sha256File(path) {
  return createHash("sha256").update(readFileSync(resolve(path))).digest("hex");
}

export function sha256Artifact(path) {
  const root = resolve(path);
  const rootStat = lstatSync(root);
  if (rootStat.isFile()) return sha256File(root);
  if (!rootStat.isDirectory()) fail(`artifact is neither a regular file nor directory: ${root}`);
  const hash = createHash("sha256");
  let fileCount = 0;
  const visit = (directory) => {
    for (const name of readdirSync(directory).sort()) {
      const child = join(directory, name);
      const stat = lstatSync(child);
      const childRelative = relative(root, child).replaceAll("\\", "/");
      if (stat.isSymbolicLink()) fail(`artifact directories cannot contain symlinks: ${childRelative}`);
      if (stat.isDirectory()) {
        hash.update(`directory\0${childRelative}\0`);
        visit(child);
      } else if (stat.isFile()) {
        fileCount += 1;
        hash.update(`file\0${childRelative}\0${stat.mode & 0o111}\0`);
        hash.update(readFileSync(child));
        hash.update("\0");
      } else {
        fail(`artifact contains unsupported entry: ${childRelative}`);
      }
    }
  };
  visit(root);
  if (fileCount === 0) fail(`artifact directory is empty: ${root}`);
  return hash.digest("hex");
}

function reportDigest(path, label) {
  const stat = lstatSync(resolve(path));
  if (!stat.isFile() || stat.size === 0) fail(`${label} report must be a non-empty file`);
  return sha256File(path);
}

function exactIdSet(actual, expected, label) {
  const actualIds = actual.map((value) => value.id).sort();
  const expectedIds = [...expected].sort();
  if (
    actualIds.length !== expectedIds.length ||
    actualIds.some((id, index) => id !== expectedIds[index])
  ) {
    fail(`${label} IDs must equal ${expectedIds.join(", ")}`);
  }
}

export function createDomainCoreProofFragment({
  jobId,
  runId,
  runAttempt,
  headSha,
  candidate,
  suites = [],
  artifacts = [],
  benchmarks = [],
  rollback = null,
  policy,
}) {
  const policyErrors = validateDeterministicPromotionPolicy(policy);
  if (policyErrors.length > 0) fail(policyErrors.join("; "));
  if (!DOMAIN_CORE_REQUIRED_JOB_IDS.includes(jobId)) fail(`unexpected job ID: ${jobId}`);
  const identity = validateDomainCoreCandidateIdentity(candidate);
  if (headSha !== identity.candidateCommit) fail("fragment head SHA must equal candidate commit");
  const normalizedRunId = positiveInteger(runId, "runId");
  const normalizedAttempt = positiveInteger(runAttempt, "runAttempt");
  const requiredSuites = DOMAIN_CORE_REQUIRED_SUITES.filter((suite) => suite.jobId === jobId);
  for (const suite of suites) {
    if (!requiredSuites.some((required) => required.id === suite.id)) {
      fail(`suite ${suite.id} does not belong to ${jobId}`);
    }
  }
  const requiredArtifacts = DOMAIN_CORE_REQUIRED_ARTIFACTS.filter(
    (artifact) => artifact.jobId === jobId,
  );
  for (const artifact of artifacts) {
    if (!requiredArtifacts.some((required) => required.id === artifact.id)) {
      fail(`artifact ${artifact.id} does not belong to ${jobId}`);
    }
  }
  const requiredBenchmarks = policy.requiredBenchmarks.filter(
    (benchmark) => benchmark.jobId === jobId,
  );
  for (const benchmark of benchmarks) {
    if (!requiredBenchmarks.some((required) => required.id === benchmark.id)) {
      fail(`benchmark ${benchmark.id} does not belong to ${jobId}`);
    }
  }
  if (rollback !== null && policy.rollback.jobId !== jobId) {
    fail(`rollback evidence does not belong to ${jobId}`);
  }
  return {
    schemaVersion: DOMAIN_CORE_PROOF_FRAGMENT_SCHEMA_VERSION,
    jobId,
    runId: normalizedRunId,
    runAttempt: normalizedAttempt,
    headSha,
    candidate: identity,
    suites: suites.map(({ id, reportPath }) => ({
      id,
      jobId,
      runId: normalizedRunId,
      runAttempt: normalizedAttempt,
      reportSha256: reportDigest(reportPath, id),
      candidate: identity,
    })),
    artifacts: artifacts.map(({ id, path }) => {
      const required = requiredArtifacts.find((item) => item.id === id);
      return {
        id,
        consumer: required.consumer,
        jobId,
        runId: normalizedRunId,
        runAttempt: normalizedAttempt,
        artifactSha256: sha256Artifact(path),
        loadedIdentity: identity,
        loadSuiteIds: [...required.requiredLoadSuiteIds],
      };
    }),
    benchmarks: benchmarks.map(({ id, reportPath }) => {
      const report = JSON.parse(readFileSync(resolve(reportPath), "utf8"));
      exactKeys(report, new Set(["baselineNanos", "candidateNanos"]), `${id} benchmark`);
      const baselineNanos = positiveInteger(report.baselineNanos, `${id}.baselineNanos`);
      const candidateNanos = positiveInteger(report.candidateNanos, `${id}.candidateNanos`);
      return {
        id,
        jobId,
        runId: normalizedRunId,
        runAttempt: normalizedAttempt,
        reportSha256: reportDigest(reportPath, id),
        baselineNanos,
        candidateNanos,
        pairedRegressionBasisPoints: pairedRegressionBasisPoints(
          baselineNanos,
          candidateNanos,
        ),
      };
    }),
    rollback:
      rollback === null
        ? null
        : {
            jobId,
            suiteId: policy.rollback.suiteId,
            runId: normalizedRunId,
            runAttempt: normalizedAttempt,
            reportSha256: reportDigest(rollback.reportPath, "rollback"),
            fromCandidateCommit: identity.candidateCommit,
            restoredArtifactSha256: sha256Artifact(rollback.restoredArtifactPath),
            restoredMode: "legacy",
          },
  };
}

function validateFragment(fragment, candidate, runId, runAttempt) {
  exactKeys(fragment, FRAGMENT_KEYS, `fragment ${fragment?.jobId ?? "unknown"}`);
  if (fragment.schemaVersion !== DOMAIN_CORE_PROOF_FRAGMENT_SCHEMA_VERSION) {
    fail(`fragment ${fragment.jobId} has unsupported schema version`);
  }
  if (!DOMAIN_CORE_REQUIRED_JOB_IDS.includes(fragment.jobId)) {
    fail(`fragment has unexpected job ID: ${String(fragment.jobId)}`);
  }
  if (fragment.runId !== runId || fragment.runAttempt !== runAttempt) {
    fail(`fragment ${fragment.jobId} does not belong to this workflow attempt`);
  }
  if (fragment.headSha !== candidate.candidateCommit) {
    fail(`fragment ${fragment.jobId} head SHA does not match candidate`);
  }
  const fragmentCandidate = validateDomainCoreCandidateIdentity(fragment.candidate);
  if (JSON.stringify(fragmentCandidate) !== JSON.stringify(candidate)) {
    fail(`fragment ${fragment.jobId} candidate tuple does not match`);
  }
  for (const key of ["suites", "artifacts", "benchmarks"]) {
    if (!Array.isArray(fragment[key])) fail(`fragment ${fragment.jobId}.${key} must be an array`);
  }
  if (fragment.rollback !== null && typeof fragment.rollback !== "object") {
    fail(`fragment ${fragment.jobId}.rollback must be null or an object`);
  }
}

export function aggregateDomainCoreProofFragments({
  fragments,
  jobResults,
  candidate,
  runId,
  runAttempt,
  policy,
}) {
  const identity = validateDomainCoreCandidateIdentity(candidate);
  const normalizedRunId = positiveInteger(runId, "runId");
  const normalizedAttempt = positiveInteger(runAttempt, "runAttempt");
  const policyErrors = validateDeterministicPromotionPolicy(policy);
  if (policyErrors.length > 0) fail(policyErrors.join("; "));
  exactKeys(jobResults, new Set(DOMAIN_CORE_REQUIRED_JOB_IDS), "job results");
  const jobs = DOMAIN_CORE_REQUIRED_JOB_IDS.map((id) => {
    const result = jobResults[id];
    if (!result || result.result !== "success") fail(`required job ${id} did not succeed`);
    return { id, status: "completed", conclusion: "success" };
  });
  const suites = [];
  const artifacts = [];
  const benchmarks = [];
  let rollback = null;
  for (const fragment of fragments) {
    validateFragment(fragment, identity, normalizedRunId, normalizedAttempt);
    suites.push(...fragment.suites);
    artifacts.push(...fragment.artifacts);
    benchmarks.push(...fragment.benchmarks);
    if (fragment.rollback !== null) {
      if (rollback !== null) fail("multiple rollback fragments are not allowed");
      rollback = fragment.rollback;
    }
  }
  exactIdSet(suites, DOMAIN_CORE_REQUIRED_SUITES.map((suite) => suite.id), "suite");
  exactIdSet(artifacts, DOMAIN_CORE_REQUIRED_ARTIFACTS.map((artifact) => artifact.id), "artifact");
  exactIdSet(benchmarks, policy.requiredBenchmarks.map((benchmark) => benchmark.id), "benchmark");
  if (rollback === null) fail("rollback evidence is required");
  const suitesById = new Map(suites.map((suite) => [suite.id, suite]));
  const coverage = Object.entries(policy.domains).flatMap(([domain, domainPolicy]) =>
    domainPolicy.requiredCoverage.map(({ slice, consumer, suiteId }) => ({
      domain,
      slice,
      consumer,
      suiteId,
      reportSha256: suitesById.get(suiteId).reportSha256,
    })),
  );
  return { jobs, suites, coverage, artifacts, benchmarks, rollback };
}

export function loadFragments(directory) {
  return readdirSync(resolve(directory))
    .filter((name) => name.endsWith(".json"))
    .sort()
    .map((name) => {
      try {
        return JSON.parse(readFileSync(join(resolve(directory), name), "utf8"));
      } catch (error) {
        fail(`unable to read fragment ${basename(name)}: ${error.message}`);
      }
    });
}
