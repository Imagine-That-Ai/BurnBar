import { createHash } from "node:crypto";

import { validateDomainCoreCandidateIdentity } from "./domain-core-candidate-receipt.mjs";
import {
  coverageKey,
  requiredCoverageForDomain,
} from "./domain-core-evidence-contract.mjs";

export const DOMAIN_CORE_DETERMINISTIC_CANDIDATE_BUNDLE_SCHEMA_VERSION = 1;

const IDENTIFIER = /^[a-z][a-z0-9_.-]{0,63}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const GIT_SHA = /^[0-9a-f]{40}$/u;
const UTC_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/u;
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1_000;

const ROOT_KEYS = new Set([
  "schemaVersion",
  "bundleKind",
  "status",
  "proofComplete",
  "eligibleForAttestation",
  "promotionAuthorized",
  "trust",
  "generatedAt",
  "candidate",
  "policySha256",
  "workflow",
  "suites",
  "coverage",
  "artifacts",
  "benchmarks",
  "rollback",
]);
const POLICY_KEYS = new Set([
  "schemaVersion",
  "authority",
  "promotionAuthority",
  "protectedAttestationRequired",
  "workflow",
  "requiredSuites",
  "requiredArtifacts",
  "requiredBenchmarks",
  "maximumPairedRegressionBasisPoints",
  "rollbackRequired",
  "rollback",
  "oneStableReleaseBeforeDeletion",
  "stableReleaseRollbackArtifactRequired",
  "domains",
]);
const POLICY_WORKFLOW_KEYS = new Set([
  "repository",
  "workflowPath",
  "workflowName",
  "allowedEvents",
  "requiredRef",
  "requiredJobIds",
]);
const POLICY_SUITE_KEYS = new Set(["id", "jobId"]);
const POLICY_ARTIFACT_KEYS = new Set([
  "id",
  "consumer",
  "jobId",
  "requiredLoadSuiteIds",
]);
const POLICY_BENCHMARK_KEYS = new Set(["id", "jobId"]);
const POLICY_ROLLBACK_KEYS = new Set(["jobId", "suiteId"]);
const POLICY_DOMAIN_KEYS = new Set(["requiredCoverage"]);
const POLICY_COVERAGE_KEYS = new Set(["slice", "consumer", "suiteId"]);
const WORKFLOW_KEYS = new Set([
  "repository",
  "workflowPath",
  "workflowName",
  "runId",
  "runAttempt",
  "event",
  "ref",
  "headSha",
  "jobs",
]);
const JOB_KEYS = new Set(["id", "status", "conclusion"]);
const SUITE_KEYS = new Set([
  "id",
  "jobId",
  "runId",
  "runAttempt",
  "reportSha256",
  "candidate",
]);
const COVERAGE_KEYS = new Set([
  "domain",
  "slice",
  "consumer",
  "suiteId",
  "reportSha256",
]);
const ARTIFACT_KEYS = new Set([
  "id",
  "consumer",
  "jobId",
  "runId",
  "runAttempt",
  "artifactSha256",
  "identityReportSha256",
  "loadedIdentity",
  "loadSuiteIds",
]);
const BENCHMARK_KEYS = new Set([
  "id",
  "jobId",
  "runId",
  "runAttempt",
  "reportSha256",
  "baselineNanos",
  "candidateNanos",
  "pairedRegressionBasisPoints",
]);
const ROLLBACK_KEYS = new Set([
  "jobId",
  "suiteId",
  "runId",
  "runAttempt",
  "reportSha256",
  "fromCandidateCommit",
  "restoredArtifactSha256",
  "restoredMode",
]);
const TRUST_KEYS = new Set([
  "authority",
  "attestationRequired",
  "requiredSigner",
  "verificationSteps",
]);
const REQUIRED_ATTESTATION_STEPS = Object.freeze([
  "query-github-api",
  "download-exact-run-artifacts",
  "revalidate-with-trusted-main",
  "sign-protected-attestation",
]);

const CANONICAL_WORKFLOW = Object.freeze({
  repository: "Imagine-That-Ai/BurnBar",
  workflowPath: ".github/workflows/domain-core.yml",
  workflowName: "Shared Rust domain core",
  allowedEvents: Object.freeze(["push"]),
  requiredRef: "refs/heads/main",
});

export const DOMAIN_CORE_REQUIRED_JOB_IDS = Object.freeze([
  "promotion-contracts",
  "rust-and-csharp",
  "windows-native",
  "linux-arm64-native",
  "wasm",
  "functions-pricing",
  "android",
  "apple",
  "apple-native-smoke",
  "swift-consumer-contracts",
  "console-consumer-contracts",
  "rollback-drill",
]);

export const DOMAIN_CORE_REQUIRED_SUITES = Object.freeze([
  Object.freeze({ id: "promotion-contracts", jobId: "promotion-contracts" }),
  Object.freeze({ id: "rust-workspace", jobId: "rust-and-csharp" }),
  Object.freeze({ id: "rust-fuzz-smoke", jobId: "rust-and-csharp" }),
  Object.freeze({ id: "rust-performance-smoke", jobId: "rust-and-csharp" }),
  Object.freeze({ id: "csharp-quota-native", jobId: "rust-and-csharp" }),
  Object.freeze({ id: "csharp-cloudvault-native", jobId: "rust-and-csharp" }),
  Object.freeze({ id: "windows-native-x64", jobId: "windows-native" }),
  Object.freeze({ id: "windows-native-arm64", jobId: "windows-native" }),
  Object.freeze({ id: "linux-arm64-native", jobId: "linux-arm64-native" }),
  Object.freeze({ id: "wasm-browser-kat", jobId: "wasm" }),
  Object.freeze({ id: "wasm-node-kat", jobId: "wasm" }),
  Object.freeze({ id: "functions-pricing-contracts", jobId: "functions-pricing" }),
  Object.freeze({ id: "android-native-load", jobId: "android" }),
  Object.freeze({ id: "android-consumer-contracts", jobId: "android" }),
  Object.freeze({ id: "swift-artifact-provenance", jobId: "apple" }),
  Object.freeze({ id: "swift-native-load", jobId: "apple-native-smoke" }),
  Object.freeze({ id: "swift-consumer-contracts", jobId: "swift-consumer-contracts" }),
  Object.freeze({ id: "console-consumer-contracts", jobId: "console-consumer-contracts" }),
  Object.freeze({ id: "rollback-drill", jobId: "rollback-drill" }),
]);

export const DOMAIN_CORE_REQUIRED_ARTIFACTS = Object.freeze([
  Object.freeze({
    id: "swift-xcframework",
    consumer: "swift",
    jobId: "apple-native-smoke",
    requiredLoadSuiteIds: Object.freeze(["swift-native-load"]),
  }),
  Object.freeze({
    id: "kotlin-aar",
    consumer: "kotlin",
    jobId: "android",
    requiredLoadSuiteIds: Object.freeze(["android-native-load"]),
  }),
  Object.freeze({
    id: "csharp-native",
    consumer: "csharp",
    jobId: "rust-and-csharp",
    requiredLoadSuiteIds: Object.freeze([
      "csharp-quota-native",
      "csharp-cloudvault-native",
    ]),
  }),
  Object.freeze({
    id: "browser-wasm",
    consumer: "browser-wasm",
    jobId: "wasm",
    requiredLoadSuiteIds: Object.freeze([
      "wasm-browser-kat",
      "console-consumer-contracts",
    ]),
  }),
  Object.freeze({
    id: "node-wasm",
    consumer: "node-wasm",
    jobId: "wasm",
    requiredLoadSuiteIds: Object.freeze([
      "wasm-node-kat",
      "functions-pricing-contracts",
    ]),
  }),
  Object.freeze({
    id: "windows-native-x64-binary",
    consumer: "csharp",
    jobId: "windows-native",
    requiredLoadSuiteIds: Object.freeze(["windows-native-x64"]),
  }),
  Object.freeze({
    id: "windows-native-arm64-binary",
    consumer: "csharp",
    jobId: "windows-native",
    requiredLoadSuiteIds: Object.freeze(["windows-native-arm64"]),
  }),
  Object.freeze({
    id: "linux-arm64-native-binary",
    consumer: "csharp",
    jobId: "linux-arm64-native",
    requiredLoadSuiteIds: Object.freeze(["linux-arm64-native"]),
  }),
]);

const CANONICAL_BENCHMARKS = Object.freeze([
  Object.freeze({ id: "complete-payload-ffi", jobId: "rust-and-csharp" }),
]);
const CANONICAL_ROLLBACK = Object.freeze({
  jobId: "rollback-drill",
  suiteId: "rollback-drill",
});

const COVERAGE_SUITE_BY_CONSUMER = Object.freeze({
  apple: "swift-consumer-contracts",
  android: "android-consumer-contracts",
  windows: null,
  console: "console-consumer-contracts",
  functions: "functions-pricing-contracts",
});

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, expected, path, errors) {
  if (!isRecord(value)) {
    errors.push(`${path} must be an object`);
    return false;
  }
  for (const key of Object.keys(value)) {
    if (!expected.has(key)) errors.push(`${path}.${key} is not allowed`);
  }
  for (const key of expected) {
    if (!Object.hasOwn(value, key)) errors.push(`${path}.${key} is required`);
  }
  return true;
}

function isIdentifier(value) {
  return typeof value === "string" && IDENTIFIER.test(value);
}

function validateDigest(value, path, errors) {
  if (typeof value !== "string" || !SHA256.test(value)) {
    errors.push(`${path} must be a lowercase SHA-256 digest`);
    return false;
  }
  return true;
}

function validatePositiveInteger(value, path, errors) {
  if (!Number.isSafeInteger(value) || value < 1) {
    errors.push(`${path} must be a positive safe integer`);
    return false;
  }
  return true;
}

function validateTimestamp(value, path, errors) {
  if (typeof value !== "string" || !UTC_TIMESTAMP.test(value)) {
    errors.push(`${path} must be an RFC 3339 UTC timestamp`);
    return null;
  }
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed) || new Date(parsed).toISOString() !== normalizeTimestamp(value)) {
    errors.push(`${path} must be a valid calendar timestamp`);
    return null;
  }
  return parsed;
}

function normalizeTimestamp(value) {
  return value.includes(".")
    ? value.replace(/\.(\d{1,3})Z$/u, (_, part) => `.${part.padEnd(3, "0")}Z`)
    : value.replace(/Z$/u, ".000Z");
}

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue);
  if (!isRecord(value)) return value;
  return Object.fromEntries(
    Object.keys(value)
      .sort()
      .map((key) => [key, stableValue(value[key])]),
  );
}

export function deterministicPolicySha256(policy) {
  return createHash("sha256")
    .update(JSON.stringify(stableValue(policy)))
    .digest("hex");
}

function exactStringSet(actual, expected, path, errors) {
  if (!Array.isArray(actual)) {
    errors.push(`${path} must be an array`);
    return false;
  }
  const seen = new Set();
  for (const [index, value] of actual.entries()) {
    if (!isIdentifier(value)) {
      errors.push(`${path}[${index}] must be a valid identifier`);
      continue;
    }
    if (seen.has(value)) errors.push(`${path} duplicates ${value}`);
    seen.add(value);
  }
  for (const value of expected) {
    if (!seen.has(value)) errors.push(`${path} omits ${value}`);
  }
  for (const value of seen) {
    if (!expected.includes(value)) errors.push(`${path} contains unexpected ${value}`);
  }
  return seen.size === expected.length;
}

function exactEventSet(actual, expected, path, errors) {
  if (!Array.isArray(actual)) {
    errors.push(`${path} must be an array`);
    return;
  }
  const seen = new Set(actual);
  if (seen.size !== actual.length) errors.push(`${path} must not contain duplicates`);
  for (const value of expected) {
    if (!seen.has(value)) errors.push(`${path} omits ${value}`);
  }
  for (const value of seen) {
    if (!expected.includes(value)) errors.push(`${path} contains unexpected ${String(value)}`);
  }
}

function expectedCoverageSuite(domain, consumer) {
  if (consumer === "windows") {
    return domain === "quota" ? "csharp-quota-native" : "csharp-cloudvault-native";
  }
  return COVERAGE_SUITE_BY_CONSUMER[consumer];
}

function canonicalCoverage() {
  return Object.keys({ quota: true, cloudvault: true, hermes: true, pricing: true }).flatMap(
    (domain) =>
      requiredCoverageForDomain(domain).map(({ slice, consumer }) => ({
        domain,
        slice,
        consumer,
        suiteId: expectedCoverageSuite(domain, consumer),
      })),
  );
}

function coverageIdentity(value) {
  return `${value.domain}:${coverageKey(value.slice, value.consumer)}`;
}

function validatePolicyCollection(actual, canonical, keys, path, errors, compare) {
  if (!Array.isArray(actual)) {
    errors.push(`${path} must be an array`);
    return;
  }
  const expectedById = new Map(canonical.map((item) => [item.id, item]));
  const seen = new Set();
  actual.forEach((item, index) => {
    const itemPath = `${path}[${index}]`;
    if (!exactKeys(item, keys, itemPath, errors)) return;
    if (!isIdentifier(item.id)) errors.push(`${itemPath}.id must be a valid identifier`);
    if (seen.has(item.id)) errors.push(`${path} duplicates ${item.id}`);
    seen.add(item.id);
    const expected = expectedById.get(item.id);
    if (!expected) errors.push(`${path} contains unexpected ${String(item.id)}`);
    else compare(item, expected, itemPath, errors);
  });
  for (const item of canonical) {
    if (!seen.has(item.id)) errors.push(`${path} omits ${item.id}`);
  }
}

export function validateDeterministicPromotionPolicy(policy) {
  const errors = [];
  if (!exactKeys(policy, POLICY_KEYS, "policy", errors)) return errors;
  if (policy.schemaVersion !== 3) errors.push("policy.schemaVersion must be 3");
  if (policy.authority !== "unsigned-candidate-evaluation") {
    errors.push("policy.authority must be unsigned-candidate-evaluation");
  }
  if (policy.promotionAuthority !== false) {
    errors.push("policy.promotionAuthority must be false");
  }
  if (policy.protectedAttestationRequired !== true) {
    errors.push("policy.protectedAttestationRequired must be true");
  }
  if (exactKeys(policy.workflow, POLICY_WORKFLOW_KEYS, "policy.workflow", errors)) {
    for (const field of ["repository", "workflowPath", "workflowName", "requiredRef"]) {
      if (policy.workflow[field] !== CANONICAL_WORKFLOW[field]) {
        errors.push(`policy.workflow.${field} must equal ${CANONICAL_WORKFLOW[field]}`);
      }
    }
    exactEventSet(
      policy.workflow.allowedEvents,
      CANONICAL_WORKFLOW.allowedEvents,
      "policy.workflow.allowedEvents",
      errors,
    );
    exactStringSet(
      policy.workflow.requiredJobIds,
      DOMAIN_CORE_REQUIRED_JOB_IDS,
      "policy.workflow.requiredJobIds",
      errors,
    );
  }
  validatePolicyCollection(
    policy.requiredSuites,
    DOMAIN_CORE_REQUIRED_SUITES,
    POLICY_SUITE_KEYS,
    "policy.requiredSuites",
    errors,
    (actual, expected, path) => {
      if (actual.jobId !== expected.jobId) errors.push(`${path}.jobId must equal ${expected.jobId}`);
    },
  );
  validatePolicyCollection(
    policy.requiredArtifacts,
    DOMAIN_CORE_REQUIRED_ARTIFACTS,
    POLICY_ARTIFACT_KEYS,
    "policy.requiredArtifacts",
    errors,
    (actual, expected, path) => {
      for (const field of ["consumer", "jobId"]) {
        if (actual[field] !== expected[field]) errors.push(`${path}.${field} must equal ${expected[field]}`);
      }
      exactStringSet(
        actual.requiredLoadSuiteIds,
        [...expected.requiredLoadSuiteIds],
        `${path}.requiredLoadSuiteIds`,
        errors,
      );
    },
  );
  validatePolicyCollection(
    policy.requiredBenchmarks,
    CANONICAL_BENCHMARKS,
    POLICY_BENCHMARK_KEYS,
    "policy.requiredBenchmarks",
    errors,
    (actual, expected, path) => {
      if (actual.jobId !== expected.jobId) errors.push(`${path}.jobId must equal ${expected.jobId}`);
    },
  );
  if (policy.maximumPairedRegressionBasisPoints !== 500) {
    errors.push("policy.maximumPairedRegressionBasisPoints must be 500");
  }
  if (policy.rollbackRequired !== true) errors.push("policy.rollbackRequired must be true");
  if (exactKeys(policy.rollback, POLICY_ROLLBACK_KEYS, "policy.rollback", errors)) {
    for (const field of ["jobId", "suiteId"]) {
      if (policy.rollback[field] !== CANONICAL_ROLLBACK[field]) {
        errors.push(`policy.rollback.${field} must equal ${CANONICAL_ROLLBACK[field]}`);
      }
    }
  }
  if (policy.oneStableReleaseBeforeDeletion !== true) {
    errors.push("policy.oneStableReleaseBeforeDeletion must be true");
  }
  if (policy.stableReleaseRollbackArtifactRequired !== true) {
    errors.push("policy.stableReleaseRollbackArtifactRequired must be true");
  }

  const expectedDomains = ["quota", "cloudvault", "hermes", "pricing"];
  if (!isRecord(policy.domains)) {
    errors.push("policy.domains must be an object");
  } else {
    exactStringSet(Object.keys(policy.domains), expectedDomains, "policy.domains", errors);
    const expectedCoverage = canonicalCoverage();
    for (const domain of expectedDomains) {
      const domainPolicy = policy.domains[domain];
      const path = `policy.domains.${domain}`;
      if (!exactKeys(domainPolicy, POLICY_DOMAIN_KEYS, path, errors)) continue;
      if (!Array.isArray(domainPolicy.requiredCoverage)) {
        errors.push(`${path}.requiredCoverage must be an array`);
        continue;
      }
      const expected = new Map(
        expectedCoverage
          .filter((item) => item.domain === domain)
          .map((item) => [coverageIdentity(item), item]),
      );
      const seen = new Set();
      domainPolicy.requiredCoverage.forEach((item, index) => {
        const itemPath = `${path}.requiredCoverage[${index}]`;
        if (!exactKeys(item, POLICY_COVERAGE_KEYS, itemPath, errors)) return;
        const identity = coverageIdentity({ domain, ...item });
        if (seen.has(identity)) errors.push(`${path}.requiredCoverage duplicates ${identity}`);
        seen.add(identity);
        const required = expected.get(identity);
        if (!required) errors.push(`${path}.requiredCoverage contains unexpected ${identity}`);
        else if (item.suiteId !== required.suiteId) {
          errors.push(`${itemPath}.suiteId must equal ${required.suiteId}`);
        }
      });
      for (const identity of expected.keys()) {
        if (!seen.has(identity)) errors.push(`${path}.requiredCoverage omits ${identity}`);
      }
    }
  }
  return errors;
}

function candidate(value, path, errors) {
  try {
    return validateDomainCoreCandidateIdentity(value);
  } catch (error) {
    errors.push(`${path}: ${error instanceof Error ? error.message : String(error)}`);
    return null;
  }
}

function sameCandidate(actual, expected, path, errors) {
  const validated = candidate(actual, path, errors);
  if (!validated || !expected) return false;
  for (const field of ["candidateCommit", "coreVersion", "abiVersion", "sourceSha256"]) {
    if (validated[field] !== expected[field]) errors.push(`${path}.${field} must match bundle.candidate.${field}`);
  }
  return true;
}

function validateWorkflow(value, policy, expectedCandidate, errors) {
  if (!exactKeys(value, WORKFLOW_KEYS, "bundle.workflow", errors)) return;
  for (const field of ["repository", "workflowPath", "workflowName"]) {
    if (value[field] !== policy.workflow[field]) {
      errors.push(`bundle.workflow.${field} must match policy.workflow.${field}`);
    }
  }
  validatePositiveInteger(value.runId, "bundle.workflow.runId", errors);
  validatePositiveInteger(value.runAttempt, "bundle.workflow.runAttempt", errors);
  if (!policy.workflow.allowedEvents.includes(value.event)) {
    errors.push("bundle.workflow.event is not an authorized deterministic event");
  }
  if (value.event === "pull_request" || value.event === "pull_request_target") {
    errors.push("pull request workflow runs cannot authorize promotion");
  }
  if (value.ref !== policy.workflow.requiredRef) {
    errors.push("bundle.workflow.ref must match the protected promotion ref");
  }
  if (value.headSha !== expectedCandidate?.candidateCommit) {
    errors.push("bundle.workflow.headSha must match bundle.candidate.candidateCommit");
  }
  if (!Array.isArray(value.jobs)) {
    errors.push("bundle.workflow.jobs must be an array");
    return;
  }
  const seen = new Set();
  value.jobs.forEach((job, index) => {
    const path = `bundle.workflow.jobs[${index}]`;
    if (!exactKeys(job, JOB_KEYS, path, errors)) return;
    if (!isIdentifier(job.id)) errors.push(`${path}.id must be a valid identifier`);
    if (seen.has(job.id)) errors.push(`bundle.workflow.jobs duplicates ${String(job.id)}`);
    seen.add(job.id);
    if (job.status !== "completed") errors.push(`${path}.status must be completed`);
    if (job.conclusion !== "success") errors.push(`${path}.conclusion must be success`);
  });
  for (const id of policy.workflow.requiredJobIds) {
    if (!seen.has(id)) errors.push(`bundle.workflow.jobs omits ${id}`);
  }
  for (const id of seen) {
    if (!policy.workflow.requiredJobIds.includes(id)) {
      errors.push(`bundle.workflow.jobs contains unexpected ${id}`);
    }
  }
}

function validateRunIdentity(value, workflow, path, errors) {
  validatePositiveInteger(value.runId, `${path}.runId`, errors);
  validatePositiveInteger(value.runAttempt, `${path}.runAttempt`, errors);
  if (value.runId !== workflow?.runId) {
    errors.push(`${path}.runId must match bundle.workflow.runId`);
  }
  if (value.runAttempt !== workflow?.runAttempt) {
    errors.push(`${path}.runAttempt must match bundle.workflow.runAttempt`);
  }
}

function validateSuites(value, policy, workflow, expectedCandidate, errors) {
  if (!Array.isArray(value)) {
    errors.push("bundle.suites must be an array");
    return new Map();
  }
  const expected = new Map(policy.requiredSuites.map((item) => [item.id, item]));
  const suites = new Map();
  const reportDigests = new Set();
  value.forEach((suite, index) => {
    const path = `bundle.suites[${index}]`;
    if (!exactKeys(suite, SUITE_KEYS, path, errors)) return;
    if (suites.has(suite.id)) errors.push(`bundle.suites duplicates ${String(suite.id)}`);
    suites.set(suite.id, suite);
    const required = expected.get(suite.id);
    if (!required) errors.push(`bundle.suites contains unexpected ${String(suite.id)}`);
    else if (suite.jobId !== required.jobId) errors.push(`${path}.jobId must equal ${required.jobId}`);
    validateRunIdentity(suite, workflow, path, errors);
    if (validateDigest(suite.reportSha256, `${path}.reportSha256`, errors)) {
      if (reportDigests.has(suite.reportSha256)) {
        errors.push(`${path}.reportSha256 must uniquely identify this suite report`);
      }
      reportDigests.add(suite.reportSha256);
    }
    sameCandidate(suite.candidate, expectedCandidate, `${path}.candidate`, errors);
  });
  for (const id of expected.keys()) {
    if (!suites.has(id)) errors.push(`bundle.suites omits ${id}`);
  }
  return suites;
}

function validateCoverage(value, policy, suites, errors) {
  if (!Array.isArray(value)) {
    errors.push("bundle.coverage must be an array");
    return;
  }
  const expected = new Map(
    Object.entries(policy.domains).flatMap(([domain, domainPolicy]) =>
      domainPolicy.requiredCoverage.map((item) => [coverageIdentity({ domain, ...item }), { domain, ...item }]),
    ),
  );
  const seen = new Set();
  value.forEach((item, index) => {
    const path = `bundle.coverage[${index}]`;
    if (!exactKeys(item, COVERAGE_KEYS, path, errors)) return;
    const identity = coverageIdentity(item);
    if (seen.has(identity)) errors.push(`bundle.coverage duplicates ${identity}`);
    seen.add(identity);
    const required = expected.get(identity);
    if (!required) errors.push(`bundle.coverage contains unexpected ${identity}`);
    else if (item.suiteId !== required.suiteId) errors.push(`${path}.suiteId must equal ${required.suiteId}`);
    validateDigest(item.reportSha256, `${path}.reportSha256`, errors);
    const suite = suites.get(item.suiteId);
    if (!suite) errors.push(`${path}.suiteId must reference a required suite`);
    else if (item.reportSha256 !== suite.reportSha256) {
      errors.push(`${path}.reportSha256 must match suite ${item.suiteId}`);
    }
  });
  for (const identity of expected.keys()) {
    if (!seen.has(identity)) errors.push(`bundle.coverage omits ${identity}`);
  }
  for (const identity of seen) {
    if (!expected.has(identity)) errors.push(`bundle.coverage contains unexpected ${identity}`);
  }
}

function validateArtifacts(
  value,
  policy,
  suites,
  workflow,
  expectedCandidate,
  errors,
) {
  if (!Array.isArray(value)) {
    errors.push("bundle.artifacts must be an array");
    return;
  }
  const expected = new Map(policy.requiredArtifacts.map((item) => [item.id, item]));
  const seen = new Set();
  value.forEach((artifact, index) => {
    const path = `bundle.artifacts[${index}]`;
    if (!exactKeys(artifact, ARTIFACT_KEYS, path, errors)) return;
    if (seen.has(artifact.id)) errors.push(`bundle.artifacts duplicates ${String(artifact.id)}`);
    seen.add(artifact.id);
    const required = expected.get(artifact.id);
    if (!required) errors.push(`bundle.artifacts contains unexpected ${String(artifact.id)}`);
    else {
      for (const field of ["consumer", "jobId"]) {
        if (artifact[field] !== required[field]) errors.push(`${path}.${field} must equal ${required[field]}`);
      }
      exactStringSet(
        artifact.loadSuiteIds,
        required.requiredLoadSuiteIds,
        `${path}.loadSuiteIds`,
        errors,
      );
      for (const suiteId of required.requiredLoadSuiteIds) {
        if (!suites.has(suiteId)) errors.push(`${path}.loadSuiteIds references missing suite ${suiteId}`);
      }
    }
    validateRunIdentity(artifact, workflow, path, errors);
    validateDigest(artifact.artifactSha256, `${path}.artifactSha256`, errors);
    validateDigest(artifact.identityReportSha256, `${path}.identityReportSha256`, errors);
    sameCandidate(artifact.loadedIdentity, expectedCandidate, `${path}.loadedIdentity`, errors);
  });
  for (const id of expected.keys()) {
    if (!seen.has(id)) errors.push(`bundle.artifacts omits ${id}`);
  }
}

export function pairedRegressionBasisPoints(baselineNanos, candidateNanos) {
  if (!Number.isSafeInteger(baselineNanos) || baselineNanos < 1) {
    throw new Error("baselineNanos must be a positive safe integer");
  }
  if (!Number.isSafeInteger(candidateNanos) || candidateNanos < 1) {
    throw new Error("candidateNanos must be a positive safe integer");
  }
  const numerator = (BigInt(candidateNanos) - BigInt(baselineNanos)) * 10_000n;
  const denominator = BigInt(baselineNanos);
  const sign = numerator < 0n ? -1n : 1n;
  const magnitude = numerator < 0n ? -numerator : numerator;
  const rounded = sign * ((magnitude + denominator / 2n) / denominator);
  if (
    rounded > BigInt(Number.MAX_SAFE_INTEGER) ||
    rounded < BigInt(Number.MIN_SAFE_INTEGER)
  ) {
    throw new Error("paired regression exceeds the safe integer range");
  }
  return Number(rounded);
}

function validateBenchmarks(value, policy, workflow, errors) {
  if (!Array.isArray(value)) {
    errors.push("bundle.benchmarks must be an array");
    return;
  }
  const expected = new Map(policy.requiredBenchmarks.map((item) => [item.id, item]));
  const seen = new Set();
  value.forEach((benchmark, index) => {
    const path = `bundle.benchmarks[${index}]`;
    if (!exactKeys(benchmark, BENCHMARK_KEYS, path, errors)) return;
    if (seen.has(benchmark.id)) errors.push(`bundle.benchmarks duplicates ${String(benchmark.id)}`);
    seen.add(benchmark.id);
    const required = expected.get(benchmark.id);
    if (!required) errors.push(`bundle.benchmarks contains unexpected ${String(benchmark.id)}`);
    else if (benchmark.jobId !== required.jobId) errors.push(`${path}.jobId must equal ${required.jobId}`);
    validateRunIdentity(benchmark, workflow, path, errors);
    validateDigest(benchmark.reportSha256, `${path}.reportSha256`, errors);
    const baselineValid = validatePositiveInteger(benchmark.baselineNanos, `${path}.baselineNanos`, errors);
    const candidateValid = validatePositiveInteger(benchmark.candidateNanos, `${path}.candidateNanos`, errors);
    if (!Number.isSafeInteger(benchmark.pairedRegressionBasisPoints)) {
      errors.push(`${path}.pairedRegressionBasisPoints must be a safe integer`);
    } else if (baselineValid && candidateValid) {
      let calculated;
      try {
        calculated = pairedRegressionBasisPoints(
          benchmark.baselineNanos,
          benchmark.candidateNanos,
        );
      } catch (error) {
        errors.push(
          `${path}: ${error instanceof Error ? error.message : String(error)}`,
        );
        return;
      }
      if (benchmark.pairedRegressionBasisPoints !== calculated) {
        errors.push(`${path}.pairedRegressionBasisPoints must equal calculated value ${calculated}`);
      }
      if (calculated > policy.maximumPairedRegressionBasisPoints) {
        errors.push(`${path} exceeds ${policy.maximumPairedRegressionBasisPoints} basis points`);
      }
    }
  });
  for (const id of expected.keys()) {
    if (!seen.has(id)) errors.push(`bundle.benchmarks omits ${id}`);
  }
}

function validateRollback(
  value,
  policy,
  suites,
  workflow,
  expectedCandidate,
  errors,
) {
  if (!policy.rollbackRequired) return;
  if (!exactKeys(value, ROLLBACK_KEYS, "bundle.rollback", errors)) return;
  for (const field of ["jobId", "suiteId"]) {
    if (value[field] !== policy.rollback[field]) {
      errors.push(`bundle.rollback.${field} must equal ${policy.rollback[field]}`);
    }
  }
  validateRunIdentity(value, workflow, "bundle.rollback", errors);
  validateDigest(value.reportSha256, "bundle.rollback.reportSha256", errors);
  const suite = suites.get(value.suiteId);
  if (!suite) errors.push("bundle.rollback.suiteId must reference the required rollback suite");
  else if (value.reportSha256 !== suite.reportSha256) {
    errors.push("bundle.rollback.reportSha256 must match the rollback suite report");
  }
  if (value.fromCandidateCommit !== expectedCandidate?.candidateCommit) {
    errors.push("bundle.rollback.fromCandidateCommit must match bundle.candidate.candidateCommit");
  }
  validateDigest(value.restoredArtifactSha256, "bundle.rollback.restoredArtifactSha256", errors);
  if (value.restoredMode !== "legacy") errors.push("bundle.rollback.restoredMode must be legacy");
}

function invalidBundle(errors) {
  return {
    schemaVersion: 1,
    bundleKind: "unsigned-domain-core-candidate",
    status: "invalid",
    proofComplete: false,
    eligibleForAttestation: false,
    promotionAuthorized: false,
    errors,
  };
}

function validateTrust(value, errors) {
  if (!exactKeys(value, TRUST_KEYS, "bundle.trust", errors)) return;
  if (value.authority !== "none") {
    errors.push("bundle.trust.authority must be none");
  }
  if (value.attestationRequired !== true) {
    errors.push("bundle.trust.attestationRequired must be true");
  }
  if (value.requiredSigner !== "protected-domain-core-signer") {
    errors.push(
      "bundle.trust.requiredSigner must be protected-domain-core-signer",
    );
  }
  exactStringSet(
    value.verificationSteps,
    REQUIRED_ATTESTATION_STEPS,
    "bundle.trust.verificationSteps",
    errors,
  );
}

export function evaluateUnsignedDeterministicCandidateBundle(
  bundle,
  policy,
  { now = new Date() } = {},
) {
  const errors = validateDeterministicPromotionPolicy(policy);
  if (errors.length > 0) {
    return invalidBundle(errors);
  }
  const activePolicySha256 = deterministicPolicySha256(policy);
  if (!exactKeys(bundle, ROOT_KEYS, "bundle", errors)) {
    return invalidBundle(errors);
  }
  if (
    bundle.schemaVersion !==
    DOMAIN_CORE_DETERMINISTIC_CANDIDATE_BUNDLE_SCHEMA_VERSION
  ) {
    errors.push(
      `bundle.schemaVersion must be ${DOMAIN_CORE_DETERMINISTIC_CANDIDATE_BUNDLE_SCHEMA_VERSION}`,
    );
  }
  if (bundle.bundleKind !== "unsigned-domain-core-candidate") {
    errors.push("bundle.bundleKind must be unsigned-domain-core-candidate");
  }
  if (bundle.status !== "eligible_for_attestation") {
    errors.push("bundle.status must be eligible_for_attestation");
  }
  if (bundle.proofComplete !== true) {
    errors.push("bundle.proofComplete must be true");
  }
  if (bundle.eligibleForAttestation !== true) {
    errors.push("bundle.eligibleForAttestation must be true");
  }
  if (bundle.promotionAuthorized !== false) {
    errors.push("bundle.promotionAuthorized must be false");
  }
  validateTrust(bundle.trust, errors);
  const generatedAt = validateTimestamp(
    bundle.generatedAt,
    "bundle.generatedAt",
    errors,
  );
  const nowMs = now instanceof Date ? now.getTime() : Date.parse(now);
  if (!Number.isFinite(nowMs)) errors.push("validation now must be a valid timestamp");
  else if (generatedAt !== null && generatedAt > nowMs + MAX_CLOCK_SKEW_MS) {
    errors.push("bundle.generatedAt cannot be in the future");
  }
  const expectedCandidate = candidate(
    bundle.candidate,
    "bundle.candidate",
    errors,
  );
  if (!validateDigest(bundle.policySha256, "bundle.policySha256", errors)) {
    // The digest format error is sufficient.
  } else if (bundle.policySha256 !== activePolicySha256) {
    errors.push(
      "bundle.policySha256 does not match the active deterministic policy",
    );
  }
  if (errors.length === 0 || isRecord(policy?.workflow)) {
    validateWorkflow(bundle.workflow, policy, expectedCandidate, errors);
  }
  const suites = validateSuites(
    bundle.suites,
    policy,
    bundle.workflow,
    expectedCandidate,
    errors,
  );
  validateCoverage(bundle.coverage, policy, suites, errors);
  validateArtifacts(
    bundle.artifacts,
    policy,
    suites,
    bundle.workflow,
    expectedCandidate,
    errors,
  );
  validateBenchmarks(bundle.benchmarks, policy, bundle.workflow, errors);
  validateRollback(
    bundle.rollback,
    policy,
    suites,
    bundle.workflow,
    expectedCandidate,
    errors,
  );
  if (errors.length > 0) {
    return invalidBundle(errors);
  }
  return {
    schemaVersion: 1,
    bundleKind: "unsigned-domain-core-candidate",
    status: "eligible_for_attestation",
    proofComplete: true,
    eligibleForAttestation: true,
    promotionAuthorized: false,
    candidate: structuredClone(expectedCandidate),
    policySha256: bundle.policySha256,
    workflowRunId: bundle.workflow.runId,
    coverageCellCount: bundle.coverage.length,
    stableReleaseRequiredBeforeDeletion: policy.oneStableReleaseBeforeDeletion,
    stableReleaseRollbackArtifactRequiredBeforeDeletion:
      policy.stableReleaseRollbackArtifactRequired,
  };
}

export function createUnsignedDeterministicCandidateBundle({
  verifiedCandidateIdentity,
  workflow,
  evidence,
  policy,
  generatedAt = new Date().toISOString(),
}) {
  if (!isRecord(evidence)) throw new Error("deterministic evidence must be an object");
  const allowedEvidenceKeys = new Set([
    "jobs",
    "suites",
    "coverage",
    "artifacts",
    "benchmarks",
    "rollback",
  ]);
  const evidenceErrors = [];
  exactKeys(evidence, allowedEvidenceKeys, "evidence", evidenceErrors);
  if (evidenceErrors.length > 0) throw new Error(evidenceErrors.join("; "));
  const bundle = {
    schemaVersion: DOMAIN_CORE_DETERMINISTIC_CANDIDATE_BUNDLE_SCHEMA_VERSION,
    bundleKind: "unsigned-domain-core-candidate",
    status: "eligible_for_attestation",
    proofComplete: true,
    eligibleForAttestation: true,
    promotionAuthorized: false,
    trust: {
      authority: "none",
      attestationRequired: true,
      requiredSigner: "protected-domain-core-signer",
      verificationSteps: [...REQUIRED_ATTESTATION_STEPS],
    },
    generatedAt,
    candidate: validateDomainCoreCandidateIdentity(verifiedCandidateIdentity),
    policySha256: deterministicPolicySha256(policy),
    workflow: { ...structuredClone(workflow), jobs: structuredClone(evidence.jobs) },
    suites: structuredClone(evidence.suites),
    coverage: structuredClone(evidence.coverage),
    artifacts: structuredClone(evidence.artifacts),
    benchmarks: structuredClone(evidence.benchmarks),
    rollback: structuredClone(evidence.rollback),
  };
  const report = evaluateUnsignedDeterministicCandidateBundle(bundle, policy, {
    now: generatedAt,
  });
  if (!report.proofComplete) throw new Error(report.errors.join("; "));
  return bundle;
}
