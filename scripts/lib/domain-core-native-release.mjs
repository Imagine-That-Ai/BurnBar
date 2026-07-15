import { isDeepStrictEqual } from "node:util";

import {
  DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW,
  DOMAIN_CORE_REPOSITORY,
  RELEASE_CONSUMERS,
  canonicalSha256,
  validateCandidateBundle,
  validateDomainCoreCandidateIdentity,
} from "./domain-core-release-evidence.mjs";

export const DOMAIN_CORE_PUBLIC_PROFILE = "public-production";
export const DOMAIN_CORE_ROLLBACK_PROFILE = "public-production-rollback";
export const DOMAIN_CORE_PROMOTION_PREDICATE_TYPE =
  "https://slsa.dev/provenance/v1";
export const DOMAIN_CORE_CANDIDATE_FILE = "domain-core-candidate-bundle.json";
export const DOMAIN_CORE_ROLLBACK_FILE =
  "domain-core-public-production-rollback.json";
export const DOMAIN_CORE_PROMOTION_BUNDLE_FILE =
  "domain-core-promotion-attestation.sigstore.jsonl";

const RUN_INVOCATION = new RegExp(
  `^https://github\\.com/${DOMAIN_CORE_REPOSITORY.replace("/", "\\/")}/actions/runs/([1-9]\\d*)/attempts/([1-9]\\d*)$`,
  "u",
);

export function resolveNativeReleaseProfile({ eventName, requestedProfile }) {
  if (eventName !== "push" && eventName !== "workflow_dispatch") {
    throw new Error(`unsupported native release event: ${String(eventName)}`);
  }
  if (eventName === "push") {
    if (
      requestedProfile !== undefined &&
      requestedProfile !== "" &&
      requestedProfile !== DOMAIN_CORE_PUBLIC_PROFILE
    ) {
      throw new Error("tag releases must use public-production");
    }
    return DOMAIN_CORE_PUBLIC_PROFILE;
  }
  if (
    requestedProfile !== DOMAIN_CORE_PUBLIC_PROFILE &&
    requestedProfile !== DOMAIN_CORE_ROLLBACK_PROFILE
  ) {
    throw new Error(
      "manual native releases require an explicit public-production or public-production-rollback profile",
    );
  }
  return requestedProfile;
}

export function candidateArtifactName(candidateCommit, sourceRun) {
  const candidate = validateDomainCoreCandidateIdentity({
    candidateCommit,
    coreVersion: "0.0.0",
    abiVersion: 1,
    sourceSha256: "0".repeat(64),
  });
  return `domain-core-candidate-bundle-${candidate.candidateCommit}-${positiveInteger(sourceRun.runId, "source run ID")}-${positiveInteger(sourceRun.runAttempt, "source run attempt")}`;
}

export function rollbackArtifactName(candidateCommit, sourceRun) {
  const candidateName = candidateArtifactName(candidateCommit, sourceRun);
  return candidateName.replace(
    "domain-core-candidate-bundle-",
    "domain-core-public-production-rollback-",
  );
}

export function resolveSourceCoordinates(bundle, expectedCandidateCommit) {
  const { candidate, sourceRun } = validateCandidateBundle(bundle);
  if (candidate.candidateCommit !== expectedCandidateCommit) {
    throw new Error(
      "release commit does not match the deterministic candidate bundle",
    );
  }
  return { candidate, sourceRun };
}

export function resolveProtectedSignerCoordinates(
  verifiedAttestations,
  expectedCandidate,
) {
  const candidate = validateDomainCoreCandidateIdentity(expectedCandidate);
  if (
    !Array.isArray(verifiedAttestations) ||
    verifiedAttestations.length === 0
  ) {
    throw new Error("protected promotion verifier returned no results");
  }
  const coordinates = new Map();
  for (const entry of verifiedAttestations) {
    const statement = entry?.verificationResult?.statement;
    const certificate = entry?.verificationResult?.signature?.certificate;
    const subjects = statement?.subject;
    if (
      !Array.isArray(subjects) ||
      !subjects.some(
        (subject) =>
          subject?.name === DOMAIN_CORE_CANDIDATE_FILE &&
          typeof subject?.digest?.sha256 === "string",
      )
    ) {
      continue;
    }
    const workflow = certificate?.workflow?.repository;
    if (
      workflow !== undefined &&
      workflow !==
        `${DOMAIN_CORE_REPOSITORY}/${DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW}`
    ) {
      continue;
    }
    const match = RUN_INVOCATION.exec(certificate?.runInvocationURI ?? "");
    if (!match) continue;
    const value = { runId: Number(match[1]), runAttempt: Number(match[2]) };
    coordinates.set(`${value.runId}/${value.runAttempt}`, value);
  }
  if (coordinates.size !== 1) {
    throw new Error(
      `expected exactly one protected signer run for candidate ${candidate.candidateCommit}`,
    );
  }
  return [...coordinates.values()][0];
}

export function validateResolvedProfile(profile, profileName, candidate) {
  const expectedCandidate = validateDomainCoreCandidateIdentity(candidate);
  if (
    profile?.schemaVersion !== 1 ||
    profile?.name !== profileName ||
    profile?.artifactAuthority !== "signed" ||
    profile?.distribution !== "public" ||
    !isDeepStrictEqual(profile?.candidateIdentity, expectedCandidate)
  ) {
    throw new Error(
      "selected native release profile is not the exact candidate-bound signed public profile",
    );
  }
  if (profileName === DOMAIN_CORE_ROLLBACK_PROFILE) {
    if (
      profile.evidenceEnabled !== false ||
      profile.rolloutChannel !== null ||
      Object.values(profile.modes ?? {}).length === 0 ||
      Object.values(profile.modes).some((mode) => mode !== "legacy")
    ) {
      throw new Error(
        "public-production-rollback must permanently select legacy for every domain",
      );
    }
  }
  return profile;
}

export function publicProfileSha256(profile, profileName, candidate) {
  return canonicalSha256(
    validateResolvedProfile(profile, profileName, candidate),
  );
}

export function nativeEvidenceDomains(consumer, profile, profileName) {
  const contract = RELEASE_CONSUMERS[consumer];
  if (!contract || !new Set(["apple", "android", "windows"]).has(consumer)) {
    throw new Error(`unsupported native release consumer: ${String(consumer)}`);
  }
  if (profileName === DOMAIN_CORE_ROLLBACK_PROFILE) {
    return [];
  }
  return contract.domains.filter(
    (domain) => profile.modes?.[domain] === "rust",
  );
}

export function nativePredicateName(consumer, version, domain) {
  requireSafeToken(consumer, "consumer");
  requireSafeToken(version, "version");
  requireSafeToken(domain, "domain");
  return `OpenBurnBar-${version}-${consumer}-${domain}-domain-core.predicate.json`;
}

export function nativeAttestationName(consumer, version, domain) {
  return nativePredicateName(consumer, version, domain).replace(
    ".predicate.json",
    ".sigstore.json",
  );
}

function positiveInteger(value, label) {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new Error(`${label} must be a positive safe integer`);
  }
  return value;
}

function requireSafeToken(value, label) {
  if (
    typeof value !== "string" ||
    !/^[0-9A-Za-z][0-9A-Za-z._+-]*$/u.test(value)
  ) {
    throw new Error(`${label} must be a safe filename token`);
  }
}
