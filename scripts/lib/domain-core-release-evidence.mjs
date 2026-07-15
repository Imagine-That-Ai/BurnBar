import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { lstatSync, readFileSync } from "node:fs";
import { basename, isAbsolute, resolve } from "node:path";

import { validateDomainCoreCandidateIdentity } from "./domain-core-candidate-receipt.mjs";

export { validateDomainCoreCandidateIdentity };

export const DOMAIN_CORE_REPOSITORY = "Imagine-That-Ai/BurnBar";
export const DOMAIN_CORE_SOURCE_WORKFLOW = ".github/workflows/domain-core.yml";
export const DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW =
  ".github/workflows/domain-core-promotion-proof.yml";
export const DOMAIN_CORE_PROMOTION_PREDICATE_TYPE =
  "https://slsa.dev/provenance/v1";
export const DOMAIN_CORE_RELEASE_PREDICATE_TYPE =
  "https://openburnbar.dev/attestations/domain-core-release-artifact/v2";

const SHA256 = /^[0-9a-f]{64}$/u;
const FULL_SHA = /^[0-9a-f]{40}$/u;
export const STABLE_RELEASE_VERSION =
  /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;
export const NATIVE_RELEASE_VERSION =
  /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;
const SAFE_NAME = /^[0-9A-Za-z][0-9A-Za-z._+-]{0,254}$/u;

export const RELEASE_CONSUMERS = Object.freeze({
  apple: Object.freeze({
    signerWorkflow: ".github/workflows/release.yml",
    artifactKind: "macos-dmg",
    target: "macos-arm64",
    domains: Object.freeze([
      "quota",
      "cloudVault",
      "cloudVaultRewrap",
      "cloudVaultSearch",
      "hermes",
      "pricing",
    ]),
    fileName: (version) => `OpenBurnBar-${version}-macOS.dmg`,
  }),
  android: Object.freeze({
    signerWorkflow: ".github/workflows/release.yml",
    artifactKind: "android-aab",
    target: "android-universal",
    domains: Object.freeze([
      "cloudVault",
      "cloudVaultRewrap",
      "cloudVaultSearch",
      "hermes",
    ]),
    fileName: (version) => `OpenBurnBar-${version}-Android.aab`,
  }),
  windows: Object.freeze({
    signerWorkflow: ".github/workflows/openburnbar-release-windows.yml",
    artifactKind: "windows-release-bundle",
    target: "windows-x64-arm64",
    domains: Object.freeze(["quota", "cloudVault"]),
    fileName: (version) => `OpenBurnBar-${version}-windows-release.zip`,
  }),
  console: Object.freeze({
    signerWorkflow:
      ".github/workflows/domain-core-console-release-evidence.yml",
    artifactKind: "console-deployment-receipt",
    target: "firebase-hosting-production",
    domains: Object.freeze(["cloudVault"]),
    fileName: (version) => `OpenBurnBar-${version}-console-deployment.json`,
  }),
  functions: Object.freeze({
    signerWorkflow:
      ".github/workflows/domain-core-functions-release-evidence.yml",
    artifactKind: "functions-deployment-receipt",
    target: "firebase-functions-production",
    domains: Object.freeze(["pricing"]),
    fileName: (version) => `OpenBurnBar-${version}-functions-deployment.json`,
  }),
});

export function exactObject(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    throw new Error(`${label} must contain exactly: ${expected.join(", ")}`);
  }
  return value;
}

export function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export function canonicalSha256(value) {
  return createHash("sha256").update(canonicalJson(value)).digest("hex");
}

export function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

export function regularFile(path, label, { mustBeAbsolute = true } = {}) {
  if (mustBeAbsolute && !isAbsolute(path)) {
    throw new Error(`${label} must be an absolute path`);
  }
  const resolved = resolve(path);
  const stat = lstatSync(resolved);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) {
    throw new Error(`${label} must be a nonempty regular file, not a symlink`);
  }
  return resolved;
}

export function safeAssetName(value, label) {
  if (typeof value !== "string" || !SAFE_NAME.test(value)) {
    throw new Error(`${label} must be a safe release asset basename`);
  }
  return value;
}

function positiveInteger(value, label) {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new Error(`${label} must be a positive safe integer`);
  }
  return value;
}

function digest(value, label) {
  if (typeof value !== "string" || !SHA256.test(value)) {
    throw new Error(`${label} must be a lowercase SHA-256 digest`);
  }
  return value;
}

export function validateCandidateBundle(bundle) {
  if (
    bundle?.schemaVersion !== 1 ||
    bundle?.bundleKind !== "unsigned-domain-core-candidate" ||
    bundle?.status !== "eligible_for_attestation" ||
    bundle?.proofComplete !== true ||
    bundle?.eligibleForAttestation !== true ||
    bundle?.promotionAuthorized !== false
  ) {
    throw new Error(
      "candidate bundle is not an eligible unsigned deterministic proof",
    );
  }
  const candidate = validateDomainCoreCandidateIdentity(bundle.candidate);
  const workflow = exactObject(
    bundle.workflow,
    [
      "repository",
      "workflowPath",
      "workflowName",
      "runId",
      "runAttempt",
      "event",
      "ref",
      "headSha",
      "jobs",
    ],
    "candidate bundle workflow",
  );
  if (
    workflow.repository !== DOMAIN_CORE_REPOSITORY ||
    workflow.workflowPath !== DOMAIN_CORE_SOURCE_WORKFLOW ||
    workflow.event !== "push" ||
    workflow.ref !== "refs/heads/main" ||
    workflow.headSha !== candidate.candidateCommit
  ) {
    throw new Error(
      "candidate bundle workflow does not bind the exact main push candidate",
    );
  }
  return {
    candidate,
    sourceRun: {
      repository: workflow.repository,
      workflowPath: workflow.workflowPath,
      runId: positiveInteger(workflow.runId, "source run ID"),
      runAttempt: positiveInteger(workflow.runAttempt, "source run attempt"),
      event: "push",
      ref: "refs/heads/main",
      headSha: candidate.candidateCommit,
    },
  };
}

export function validateRollbackArtifact(value, candidate) {
  const identity = validateDomainCoreCandidateIdentity(
    value?.candidateIdentity ?? value?.candidate,
  );
  if (canonicalJson(identity) !== canonicalJson(candidate)) {
    throw new Error(
      "rollback artifact candidate identity does not match the release candidate",
    );
  }
  const modes = value?.modes;
  if (!modes || typeof modes !== "object" || Array.isArray(modes)) {
    throw new Error("rollback artifact must contain explicit domain modes");
  }
  if (
    Object.keys(modes).length === 0 ||
    Object.values(modes).some((mode) => mode !== "legacy")
  ) {
    throw new Error(
      "rollback artifact must restore every declared domain to legacy",
    );
  }
  return identity;
}

export function validateReleaseCoordinates({
  consumer,
  domain,
  artifactKind,
  target,
  version,
  tag,
  commit,
  candidate,
  activation,
}) {
  const contract = RELEASE_CONSUMERS[consumer];
  if (!contract)
    throw new Error(`unknown release consumer: ${String(consumer)}`);
  if (!contract.domains.includes(domain)) {
    throw new Error(`${consumer} does not release domain ${String(domain)}`);
  }
  if (artifactKind !== contract.artifactKind || target !== contract.target) {
    throw new Error(
      `${consumer} artifact kind and target do not match the release contract`,
    );
  }
  const allowedVersion = new Set(["apple", "android"]).has(consumer)
    ? NATIVE_RELEASE_VERSION
    : STABLE_RELEASE_VERSION;
  if (typeof version !== "string" || !allowedVersion.test(version)) {
    throw new Error(
      "release version does not match its consumer release train",
    );
  }
  const expectedTag =
    consumer === "windows" ? `windows-v${version}` : `v${version}`;
  if (tag !== expectedTag)
    throw new Error(`release tag must be ${expectedTag}`);
  if (typeof commit !== "string" || !FULL_SHA.test(commit)) {
    throw new Error("release commit must be a full lowercase Git SHA-1");
  }
  return {
    ...contract,
    activation: validateReleaseActivation(activation, {
      candidate,
      releaseCommit: commit,
    }),
  };
}

export function validateReleaseActivation(value, { candidate, releaseCommit }) {
  const activation = exactObject(
    value,
    [
      "candidateCommit",
      "activationCommit",
      "coreVersion",
      "abiVersion",
      "sourceSha256",
      "changedPathsSha256",
    ],
    "domain-core release activation",
  );
  const activationCandidate = validateDomainCoreCandidateIdentity({
    candidateCommit: activation.candidateCommit,
    coreVersion: activation.coreVersion,
    abiVersion: activation.abiVersion,
    sourceSha256: activation.sourceSha256,
  });
  const expectedCandidate = validateDomainCoreCandidateIdentity(candidate);
  if (canonicalJson(activationCandidate) !== canonicalJson(expectedCandidate)) {
    throw new Error(
      "release activation does not match the protected candidate",
    );
  }
  if (
    typeof activation.activationCommit !== "string" ||
    !FULL_SHA.test(activation.activationCommit) ||
    activation.activationCommit !== releaseCommit
  ) {
    throw new Error(
      "release activation commit does not match the release commit",
    );
  }
  if (activation.activationCommit === activation.candidateCommit) {
    throw new Error(
      "Rust release activation must be distinct from its candidate",
    );
  }
  if (
    typeof activation.changedPathsSha256 !== "string" ||
    !SHA256.test(activation.changedPathsSha256)
  ) {
    throw new Error("release activation path set must have a SHA-256 digest");
  }
  return structuredClone(activation);
}

export function buildPromotionBinding({
  candidateBundlePath,
  promotionAttestationPath,
  signerRunId,
  signerRunAttempt,
}) {
  const bundlePath = regularFile(candidateBundlePath, "candidate bundle");
  const attestationPath = regularFile(
    promotionAttestationPath,
    "protected promotion attestation",
  );
  if (basename(bundlePath) !== "domain-core-candidate-bundle.json") {
    throw new Error(
      "protected attestation subject must be domain-core-candidate-bundle.json",
    );
  }
  return {
    signerWorkflow: DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW,
    predicateType: DOMAIN_CORE_PROMOTION_PREDICATE_TYPE,
    signerRun: {
      runId: positiveInteger(signerRunId, "protected signer run ID"),
      runAttempt: positiveInteger(
        signerRunAttempt,
        "protected signer run attempt",
      ),
    },
    attestationSubject: {
      fileName: basename(bundlePath),
      sha256: sha256File(bundlePath),
    },
    attestationBundleSha256: sha256File(attestationPath),
  };
}

export function verifyProtectedPromotionAttestation({
  candidateBundlePath,
  promotionAttestationPath,
  signerRunId,
  signerRunAttempt,
  runner = spawnSync,
}) {
  const subject = regularFile(candidateBundlePath, "candidate bundle");
  const bundle = regularFile(
    promotionAttestationPath,
    "protected promotion attestation",
  );
  const runId = positiveInteger(signerRunId, "protected signer run ID");
  const runAttempt = positiveInteger(
    signerRunAttempt,
    "protected signer run attempt",
  );
  const result = runner(
    "gh",
    [
      "attestation",
      "verify",
      subject,
      "--bundle",
      bundle,
      "--repo",
      DOMAIN_CORE_REPOSITORY,
      "--signer-workflow",
      `${DOMAIN_CORE_REPOSITORY}/${DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW}`,
      "--source-ref",
      "refs/heads/main",
      "--cert-oidc-issuer",
      "https://token.actions.githubusercontent.com",
      "--deny-self-hosted-runners",
      "--predicate-type",
      DOMAIN_CORE_PROMOTION_PREDICATE_TYPE,
      "--format",
      "json",
    ],
    {
      encoding: "utf8",
      env: process.env,
      maxBuffer: 16 * 1024 * 1024,
    },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const detail = (
      result.stderr ||
      result.stdout ||
      "verification failed"
    ).trim();
    throw new Error(
      `protected promotion attestation verification failed: ${detail}`,
    );
  }
  let verified;
  try {
    verified = JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(
      `protected promotion verifier returned invalid JSON: ${error.message}`,
    );
  }
  if (!Array.isArray(verified) || verified.length === 0) {
    throw new Error(
      "protected promotion verifier returned no verification result",
    );
  }
  const expectedSubject = {
    name: basename(subject),
    digest: { sha256: sha256File(subject) },
  };
  const expectedRunInvocation = `https://github.com/${DOMAIN_CORE_REPOSITORY}/actions/runs/${runId}/attempts/${runAttempt}`;
  const exactSubject = verified.some((entry) => {
    const subjects = entry?.verificationResult?.statement?.subject;
    const certificate = entry?.verificationResult?.signature?.certificate;
    return (
      Array.isArray(subjects) &&
      subjects.some(
        (value) =>
          value?.name === expectedSubject.name &&
          value?.digest?.sha256 === expectedSubject.digest.sha256,
      ) &&
      certificate?.runInvocationURI === expectedRunInvocation
    );
  });
  if (!exactSubject) {
    throw new Error(
      "protected promotion attestation does not bind the exact candidate bundle subject and signer run",
    );
  }
  return verified;
}

export function verifyDomainCoreReleaseGate({
  candidateBundlePath,
  promotionAttestationPath,
  rollbackArtifactPath,
  expectedCandidate,
  expectedSourceRunId,
  expectedSourceRunAttempt,
  protectedSignerRunId,
  protectedSignerRunAttempt,
  expectedRollbackSha256,
  promotionVerifier = verifyProtectedPromotionAttestation,
}) {
  const candidateBundle = JSON.parse(
    readFileSync(regularFile(candidateBundlePath, "candidate bundle"), "utf8"),
  );
  const { candidate, sourceRun } = validateCandidateBundle(candidateBundle);
  const expectedIdentity =
    validateDomainCoreCandidateIdentity(expectedCandidate);
  if (canonicalJson(candidate) !== canonicalJson(expectedIdentity)) {
    throw new Error(
      "release gate candidate tuple does not match the protected candidate bundle",
    );
  }
  if (
    sourceRun.runId !==
      positiveInteger(expectedSourceRunId, "expected source run ID") ||
    sourceRun.runAttempt !==
      positiveInteger(expectedSourceRunAttempt, "expected source run attempt")
  ) {
    throw new Error(
      "release gate source run does not match the expected run and attempt",
    );
  }
  promotionVerifier({
    candidateBundlePath,
    promotionAttestationPath,
    signerRunId: protectedSignerRunId,
    signerRunAttempt: protectedSignerRunAttempt,
  });
  const promotionProof = buildPromotionBinding({
    candidateBundlePath,
    promotionAttestationPath,
    signerRunId: protectedSignerRunId,
    signerRunAttempt: protectedSignerRunAttempt,
  });
  const rollbackPath = regularFile(rollbackArtifactPath, "rollback artifact");
  validateRollbackArtifact(
    JSON.parse(readFileSync(rollbackPath, "utf8")),
    candidate,
  );
  const rollbackSha256 = sha256File(rollbackPath);
  if (
    rollbackSha256 !==
    digest(expectedRollbackSha256, "expected rollback artifact SHA-256")
  ) {
    throw new Error(
      "release gate rollback artifact digest does not match expected bytes",
    );
  }
  return {
    schemaVersion: 2,
    verificationKind: "domain-core-release-gate",
    candidate,
    sourceRun,
    promotionProof,
    rollbackArtifact: {
      fileName: safeAssetName(
        basename(rollbackPath),
        "rollback artifact basename",
      ),
      sha256: rollbackSha256,
      candidate,
    },
  };
}

export function validatePublicProfileSha256(value) {
  return digest(value, "public profile SHA-256");
}

export function expectedArtifactName(consumer, version) {
  return RELEASE_CONSUMERS[consumer]?.fileName(version);
}
