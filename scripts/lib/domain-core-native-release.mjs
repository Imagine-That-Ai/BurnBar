import { isDeepStrictEqual } from "node:util";

import {
  DOMAIN_CORE_PROTECTED_SIGNER_WORKFLOW,
  DOMAIN_CORE_REPOSITORY,
  RELEASE_CONSUMERS,
  canonicalSha256,
  exactObject,
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
const EMPTY_CHANGED_PATHS_SHA256 =
  "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945";

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

export function publicDomainProfileSha256(profile, domain) {
  if (
    profile?.name !== DOMAIN_CORE_PUBLIC_PROFILE ||
    profile?.artifactAuthority !== "signed" ||
    profile?.distribution !== "public" ||
    profile?.modes?.[domain] !== "rust"
  ) {
    throw new Error(`${String(domain)} is not active in public-production`);
  }
  return canonicalSha256({
    artifactAuthority: profile.artifactAuthority,
    distribution: profile.distribution,
    rolloutChannel: profile.rolloutChannel,
    evidenceEnabled: profile.evidenceEnabled,
    domain,
    mode: "rust",
  });
}

// An inactive activation carries the same four identity fields a candidate
// bundle would, and there is no attested bundle to read them from when no
// domain ships Rust. Project them so legacy lanes can drive the same
// candidate-bound profile and selector validation as the Rust lane.
export function inactiveCandidateIdentity(selector) {
  if (selector?.active !== false) {
    throw new Error("candidate identity requires an inactive activation");
  }
  return validateDomainCoreCandidateIdentity({
    candidateCommit: selector.candidateCommit,
    coreVersion: selector.coreVersion,
    abiVersion: selector.abiVersion,
    sourceSha256: selector.sourceSha256,
  });
}

export function validateNativeActivationSelector(
  raw,
  { candidate, releaseCommit, profile, profileName },
) {
  const expectedCandidate = validateDomainCoreCandidateIdentity(candidate);
  const selector = exactObject(
    raw,
    [
      "active",
      "candidateCommit",
      "activationCommit",
      "coreVersion",
      "abiVersion",
      "sourceSha256",
      "changedPathsSha256",
      "domains",
    ],
    "release activation selector",
  );
  if (
    typeof selector.active !== "boolean" ||
    selector.candidateCommit !== expectedCandidate.candidateCommit ||
    selector.activationCommit !== releaseCommit ||
    selector.coreVersion !== expectedCandidate.coreVersion ||
    selector.abiVersion !== expectedCandidate.abiVersion ||
    selector.sourceSha256 !== expectedCandidate.sourceSha256 ||
    !/^[0-9a-f]{64}$/u.test(selector.changedPathsSha256) ||
    !Array.isArray(selector.domains)
  ) {
    throw new Error(
      "release activation selector does not bind C and P exactly",
    );
  }
  const domains = new Map();
  for (const rawDomain of selector.domains) {
    const entry = exactObject(
      rawDomain,
      [
        "domain",
        "rowId",
        "promotionReceiptPath",
        "attestationPath",
        "bundlePath",
        "provenancePath",
        "signerRunId",
        "signerRunAttempt",
        "publicProfileSha256",
      ],
      "release activation domain",
    );
    if (
      typeof entry.domain !== "string" ||
      domains.has(entry.domain) ||
      ![
        entry.rowId,
        entry.promotionReceiptPath,
        entry.attestationPath,
        entry.bundlePath,
        entry.provenancePath,
      ].every((value) => typeof value === "string" && value.length > 0) ||
      !Number.isSafeInteger(entry.signerRunId) ||
      entry.signerRunId < 1 ||
      !Number.isSafeInteger(entry.signerRunAttempt) ||
      entry.signerRunAttempt < 1 ||
      !/^[0-9a-f]{64}$/u.test(entry.publicProfileSha256)
    ) {
      throw new Error("release activation contains an invalid domain binding");
    }
    domains.set(entry.domain, structuredClone(entry));
  }
  if (
    !selector.active &&
    (selector.candidateCommit !== selector.activationCommit ||
      selector.changedPathsSha256 !== EMPTY_CHANGED_PATHS_SHA256 ||
      domains.size !== 0)
  ) {
    throw new Error(
      "inactive release activation must be the exact empty C=P selector",
    );
  }
  if (profileName === DOMAIN_CORE_PUBLIC_PROFILE) {
    const expectedDomains = Object.entries(profile.modes)
      .filter(([, mode]) => mode === "rust")
      .map(([domain]) => domain)
      .sort();
    if (
      selector.active !== expectedDomains.length > 0 ||
      (selector.active &&
        selector.candidateCommit === selector.activationCommit) ||
      (!selector.active &&
        selector.candidateCommit !== selector.activationCommit) ||
      JSON.stringify([...domains.keys()].sort()) !==
        JSON.stringify(expectedDomains)
    ) {
      throw new Error(
        "public-production does not match its canonical activation domains",
      );
    }
    for (const domain of expectedDomains) {
      if (
        domains.get(domain).publicProfileSha256 !==
        publicDomainProfileSha256(profile, domain)
      ) {
        throw new Error(
          `${domain} public profile digest does not match activation`,
        );
      }
    }
  }
  return {
    active: selector.active,
    activation: {
      candidateCommit: selector.candidateCommit,
      activationCommit: selector.activationCommit,
      coreVersion: selector.coreVersion,
      abiVersion: selector.abiVersion,
      sourceSha256: selector.sourceSha256,
      changedPathsSha256: selector.changedPathsSha256,
    },
    domains,
  };
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
