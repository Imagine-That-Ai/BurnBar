export type DomainCoreMode = "legacy" | "shadow" | "rust";

type PublicEnvironment = Record<string, string | undefined>;

export interface DomainCoreCandidateIdentity {
  candidateCommit: string;
  coreVersion: string;
  abiVersion: number;
  sourceSha256: string;
}

const domainKeys = {
  quota: "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE",
  cloudVault: "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
  cloudVaultRewrap:
    "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE",
  cloudVaultSearch:
    "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE",
  hermes: "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_HERMES_MODE",
  pricing: "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_PRICING_MODE",
} as const;

const candidateKeys = {
  candidateCommit: "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT",
  coreVersion: "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION",
  abiVersion: "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION",
  sourceSha256: "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256",
} as const;

const CANONICAL_SEMVER =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/u;
const FULL_GIT_COMMIT = /^[0-9a-f]{40}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const POSITIVE_DECIMAL = /^[1-9]\d*$/u;
const UINT32_MAX = 0xffff_ffff;

export type DomainCoreWebDomain = keyof typeof domainKeys;

interface SignedDomainCoreWebProfile {
  modes: Record<DomainCoreWebDomain, DomainCoreMode>;
  candidateIdentity: DomainCoreCandidateIdentity;
  evidenceChannel?: "internal" | "beta";
}

type CandidateIdentityResolution =
  | { state: "absent" }
  | { state: "invalid" }
  | { state: "valid"; identity: DomainCoreCandidateIdentity };

export function resolveDomainCoreEvidenceChannel(
  environment: PublicEnvironment = embeddedPublicEnvironment(),
): "internal" | "beta" | undefined {
  return buildAuthority(environment) === "signed"
    ? resolveSignedProfile(environment)?.evidenceChannel
    : undefined;
}

export function resolveDomainCoreCandidateIdentity(
  environment: PublicEnvironment = embeddedPublicEnvironment(),
): DomainCoreCandidateIdentity | undefined {
  const authority = buildAuthority(environment);
  if (authority === "signed") {
    return resolveSignedProfile(environment)?.candidateIdentity;
  }
  if (authority !== undefined && authority !== "development") return undefined;
  const candidate = resolveCandidateIdentity(environment);
  return candidate.state === "valid" ? candidate.identity : undefined;
}

export function resolveDomainCoreWebMode(
  domain: DomainCoreWebDomain,
  environment: PublicEnvironment = embeddedPublicEnvironment(),
  developmentKey: string = domainKeys[domain],
): DomainCoreMode {
  const embedded = mode(environment[domainKeys[domain]]);
  const authority = buildAuthority(environment);
  if (authority === undefined || authority === "development") {
    if (resolveCandidateIdentity(environment).state === "invalid") {
      return "legacy";
    }
    return mode(environment[developmentKey]) ?? embedded ?? "legacy";
  }
  if (authority !== "signed") return "legacy";
  return resolveSignedProfile(environment)?.modes[domain] ?? "legacy";
}

function resolveSignedProfile(
  environment: PublicEnvironment,
): SignedDomainCoreWebProfile | undefined {
  const modes = Object.fromEntries(
    Object.entries(domainKeys).map(([name, key]) => [
      name,
      mode(environment[key]),
    ]),
  ) as Record<DomainCoreWebDomain, DomainCoreMode | undefined>;
  if (Object.values(modes).some((value) => value === undefined))
    return undefined;

  const candidate = resolveCandidateIdentity(environment);
  if (candidate.state !== "valid") return undefined;

  const name = environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE;
  const distribution =
    environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION;
  const channel =
    environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL ||
    undefined;
  const evidence =
    environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED === "1";
  const valid =
    (name === "public-production" &&
      distribution === "public" &&
      !evidence &&
      channel === undefined &&
      !Object.values(modes).includes("shadow")) ||
    ((name === "internal" || name === "beta") &&
      distribution === name &&
      channel === name &&
      evidence &&
      modes.quota === "shadow");
  if (!valid) return undefined;
  return {
    modes: modes as Record<DomainCoreWebDomain, DomainCoreMode>,
    candidateIdentity: candidate.identity,
    evidenceChannel: name === "internal" || name === "beta" ? name : undefined,
  };
}

function resolveCandidateIdentity(
  environment: PublicEnvironment,
): CandidateIdentityResolution {
  const raw = {
    candidateCommit: environment[candidateKeys.candidateCommit],
    coreVersion: environment[candidateKeys.coreVersion],
    abiVersion: environment[candidateKeys.abiVersion],
    sourceSha256: environment[candidateKeys.sourceSha256],
  };
  const values = Object.values(raw);
  if (values.every((value) => value === undefined)) return { state: "absent" };
  if (
    values.some((value) => value === undefined) ||
    !FULL_GIT_COMMIT.test(raw.candidateCommit ?? "") ||
    (raw.coreVersion?.length ?? 0) > 64 ||
    !CANONICAL_SEMVER.test(raw.coreVersion ?? "") ||
    !POSITIVE_DECIMAL.test(raw.abiVersion ?? "") ||
    !SHA256.test(raw.sourceSha256 ?? "")
  ) {
    return { state: "invalid" };
  }

  const abiVersion = Number(raw.abiVersion);
  if (!Number.isSafeInteger(abiVersion) || abiVersion > UINT32_MAX) {
    return { state: "invalid" };
  }
  return {
    state: "valid",
    identity: {
      candidateCommit: raw.candidateCommit as string,
      coreVersion: raw.coreVersion as string,
      abiVersion,
      sourceSha256: raw.sourceSha256 as string,
    },
  };
}

function buildAuthority(environment: PublicEnvironment): string | undefined {
  const authority =
    environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY?.trim();
  return authority || undefined;
}

function embeddedPublicEnvironment(): PublicEnvironment {
  return {
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_HERMES_MODE:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_HERMES_MODE,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_PRICING_MODE:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_PRICING_MODE,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256:
      process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256,
  };
}

function mode(value: string | undefined): DomainCoreMode | undefined {
  const normalized = value?.trim().toLowerCase();
  return normalized === "legacy" ||
    normalized === "shadow" ||
    normalized === "rust"
    ? normalized
    : undefined;
}
