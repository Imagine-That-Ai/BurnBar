export const DOMAIN_CORE_SHADOW_CHANNELS = new Set(["internal", "beta"]);
export const DOMAIN_CORE_SHADOW_CONSUMERS = new Set([
  "apple",
  "windows",
  "android",
  "console",
  "functions",
  "local-mcp",
  "remote-mcp",
]);

export const DOMAIN_CORE_SHADOW_CLAIMS = Object.freeze({
  channel: "domainCoreShadowChannel",
  consumers: "domainCoreShadowConsumers",
  candidateCommit: "domainCoreShadowCandidateCommit",
  coreVersion: "domainCoreShadowCoreVersion",
  coreAbiVersion: "domainCoreShadowCoreAbiVersion",
  coreSourceSha256: "domainCoreShadowCoreSourceSha256",
});

const FULL_GIT_SHA1_PATTERN = /^[0-9a-f]{40}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const UINT32_MAX = 4_294_967_295;
const SEMVER_PATTERN =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;

function normalizeConsumers(consumers) {
  if (
    !Array.isArray(consumers) ||
    consumers.some((consumer) => typeof consumer !== "string")
  ) {
    throw new Error(
      "consumers must be a non-empty list of known domain-core consumers",
    );
  }
  const normalized = [
    ...new Set(
      consumers
        .map((consumer) => consumer.trim().toLowerCase())
        .filter(Boolean),
    ),
  ].sort();
  if (
    normalized.length === 0 ||
    normalized.some((consumer) => !DOMAIN_CORE_SHADOW_CONSUMERS.has(consumer))
  ) {
    throw new Error(
      "consumers must be a non-empty list of known domain-core consumers",
    );
  }
  return normalized;
}

function normalizeAbiVersion(value) {
  if (typeof value === "string" && !/^[1-9]\d*$/.test(value)) {
    throw new Error("core ABI version must be a canonical positive uint32");
  }
  if (typeof value !== "number" && typeof value !== "string") {
    throw new Error("core ABI version must be a canonical positive uint32");
  }
  const normalized = Number(value);
  if (
    !Number.isSafeInteger(normalized) ||
    normalized < 1 ||
    normalized > UINT32_MAX
  ) {
    throw new Error("core ABI version must be a canonical positive uint32");
  }
  return normalized;
}

export function normalizeDomainCoreShadowEnrollment(
  channel,
  consumers,
  candidateCommit,
  expectedCore,
) {
  if (!DOMAIN_CORE_SHADOW_CHANNELS.has(channel))
    throw new Error("channel must be internal or beta");
  if (
    typeof candidateCommit !== "string" ||
    !FULL_GIT_SHA1_PATTERN.test(candidateCommit)
  ) {
    throw new Error(
      "candidate commit must be a canonical lowercase 40-character Git SHA-1",
    );
  }
  if (
    expectedCore === null ||
    typeof expectedCore !== "object" ||
    Array.isArray(expectedCore)
  ) {
    throw new Error(
      "expected core identity must include version, abiVersion, and sourceSha256",
    );
  }
  if (
    typeof expectedCore.version !== "string" ||
    !SEMVER_PATTERN.test(expectedCore.version)
  ) {
    throw new Error("core version must be canonical SemVer");
  }
  if (
    typeof expectedCore.sourceSha256 !== "string" ||
    !SHA256_PATTERN.test(expectedCore.sourceSha256)
  ) {
    throw new Error(
      "core source SHA-256 must be 64 lowercase hexadecimal characters",
    );
  }

  return {
    channel,
    consumers: normalizeConsumers(consumers),
    candidateCommit,
    expectedCore: {
      version: expectedCore.version,
      abiVersion: normalizeAbiVersion(expectedCore.abiVersion),
      sourceSha256: expectedCore.sourceSha256,
    },
  };
}

export function mergeDomainCoreShadowClaims(existing, enrollment) {
  return {
    ...existing,
    [DOMAIN_CORE_SHADOW_CLAIMS.channel]: enrollment.channel,
    [DOMAIN_CORE_SHADOW_CLAIMS.consumers]: enrollment.consumers,
    [DOMAIN_CORE_SHADOW_CLAIMS.candidateCommit]: enrollment.candidateCommit,
    [DOMAIN_CORE_SHADOW_CLAIMS.coreVersion]: enrollment.expectedCore.version,
    [DOMAIN_CORE_SHADOW_CLAIMS.coreAbiVersion]:
      enrollment.expectedCore.abiVersion,
    [DOMAIN_CORE_SHADOW_CLAIMS.coreSourceSha256]:
      enrollment.expectedCore.sourceSha256,
  };
}

export function clearDomainCoreShadowClaims(existing) {
  const next = { ...existing };
  for (const claim of Object.values(DOMAIN_CORE_SHADOW_CLAIMS))
    delete next[claim];
  return next;
}

export function readDomainCoreShadowEnrollmentClaims(claims) {
  const presentClaimCount = Object.values(DOMAIN_CORE_SHADOW_CLAIMS).filter(
    (claim) => Object.hasOwn(claims, claim),
  ).length;
  if (presentClaimCount === 0) return null;
  if (presentClaimCount !== Object.keys(DOMAIN_CORE_SHADOW_CLAIMS).length) {
    throw new Error("stored domain-core shadow enrollment is partial");
  }

  const enrollment = normalizeDomainCoreShadowEnrollment(
    claims[DOMAIN_CORE_SHADOW_CLAIMS.channel],
    claims[DOMAIN_CORE_SHADOW_CLAIMS.consumers],
    claims[DOMAIN_CORE_SHADOW_CLAIMS.candidateCommit],
    {
      version: claims[DOMAIN_CORE_SHADOW_CLAIMS.coreVersion],
      abiVersion: claims[DOMAIN_CORE_SHADOW_CLAIMS.coreAbiVersion],
      sourceSha256: claims[DOMAIN_CORE_SHADOW_CLAIMS.coreSourceSha256],
    },
  );

  if (
    JSON.stringify(claims[DOMAIN_CORE_SHADOW_CLAIMS.consumers]) !==
    JSON.stringify(enrollment.consumers)
  ) {
    throw new Error("stored domain-core shadow consumers are not canonical");
  }
  if (
    claims[DOMAIN_CORE_SHADOW_CLAIMS.coreAbiVersion] !==
    enrollment.expectedCore.abiVersion
  ) {
    throw new Error("stored domain-core shadow ABI version is not canonical");
  }
  return enrollment;
}

export function enrollmentMatches(claims, enrollment) {
  try {
    const stored = readDomainCoreShadowEnrollmentClaims(claims);
    return (
      stored !== null && JSON.stringify(stored) === JSON.stringify(enrollment)
    );
  } catch {
    return false;
  }
}
