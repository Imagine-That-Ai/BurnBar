import { DOMAIN_CORE_CANDIDATE_RECEIPT } from "./generated/domainCoreCandidateReceipt.js";

export type DomainCoreRuntimeMode = "legacy" | "shadow" | "rust";
export type DomainCoreRuntimeDomain =
  | "quota"
  | "cloudVault"
  | "cloudVaultRewrap"
  | "cloudVaultSearch"
  | "hermes"
  | "pricing";

export interface DomainCoreCandidateIdentity {
  candidateCommit: string;
  coreVersion: string;
  abiVersion: number;
  sourceSha256: string;
}

export interface DomainCoreBuildReceipt {
  schemaVersion: number;
  name: string;
  artifactAuthority: string;
  distribution: string;
  rolloutChannel: string | null;
  evidenceEnabled: boolean;
  modes: Readonly<Record<DomainCoreRuntimeDomain, string>>;
  candidateIdentity: DomainCoreCandidateIdentity | null;
}

const domainKeys: Record<DomainCoreRuntimeDomain, string> = {
  quota: "OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE",
  cloudVault: "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
  cloudVaultRewrap: "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE",
  cloudVaultSearch: "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE",
  hermes: "OPENBURNBAR_DOMAIN_CORE_HERMES_MODE",
  pricing: "OPENBURNBAR_DOMAIN_CORE_PRICING_MODE",
};

const candidateKeys = {
  candidateCommit: "OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT",
  coreVersion: "OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION",
  abiVersion: "OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION",
  sourceSha256: "OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256",
} as const;

const CANONICAL_SEMVER =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/u;
const FULL_GIT_COMMIT = /^[0-9a-f]{40}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;
const POSITIVE_DECIMAL = /^[1-9]\d*$/u;
const UINT32_MAX = 0xffff_ffff;

interface ResolvedDomainCoreProfile {
  modes: Record<DomainCoreRuntimeDomain, DomainCoreRuntimeMode>;
  candidateIdentity?: DomainCoreCandidateIdentity;
  evidenceChannel?: "internal" | "beta";
}

export interface DomainCoreDeploymentIdentity {
  profile: string;
  candidateIdentity: DomainCoreCandidateIdentity | null;
  pricingMode: DomainCoreRuntimeMode;
}

type CandidateIdentityResolution =
  | { state: "absent" }
  | { state: "invalid" }
  | { state: "valid"; identity: DomainCoreCandidateIdentity };

export function resolveDomainCoreEvidenceChannel(
  environment: NodeJS.ProcessEnv = process.env,
  receipt: unknown = DOMAIN_CORE_CANDIDATE_RECEIPT,
): "internal" | "beta" | undefined {
  return resolveProfile(environment, receipt)?.evidenceChannel;
}

export function resolveDomainCoreCandidateIdentity(
  environment: NodeJS.ProcessEnv = process.env,
  receipt: unknown = DOMAIN_CORE_CANDIDATE_RECEIPT,
): DomainCoreCandidateIdentity | undefined {
  return resolveProfile(environment, receipt)?.candidateIdentity;
}

export function resolveDomainCoreRuntimeMode(
  domain: DomainCoreRuntimeDomain,
  environment: NodeJS.ProcessEnv = process.env,
  receipt: unknown = DOMAIN_CORE_CANDIDATE_RECEIPT,
): DomainCoreRuntimeMode {
  return resolveProfile(environment, receipt)?.modes[domain] ?? "legacy";
}

/** Public, non-secret identity used by the production health gate. */
export function domainCoreDeploymentIdentity(
  receipt: unknown = DOMAIN_CORE_CANDIDATE_RECEIPT,
): DomainCoreDeploymentIdentity | undefined {
  const parsed = parseReceipt(receipt);
  if (!parsed) return undefined;
  return {
    profile: parsed.name,
    candidateIdentity: parsed.candidateIdentity,
    pricingMode: parsed.modes.pricing as DomainCoreRuntimeMode,
  };
}

function resolveProfile(environment: NodeJS.ProcessEnv, receipt: unknown): ResolvedDomainCoreProfile | undefined {
  const parsedReceipt = parseReceipt(receipt);
  if (!parsedReceipt) return undefined;

  if (parsedReceipt.artifactAuthority === "signed") {
    return resolveSignedProfile(parsedReceipt);
  }

  const runtimeAuthority = environment.OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY?.trim();
  if (
    parsedReceipt.artifactAuthority !== "development" ||
    (runtimeAuthority !== undefined && runtimeAuthority !== "" && runtimeAuthority !== "development")
  ) {
    return undefined;
  }

  const environmentCandidate = resolveEnvironmentCandidateIdentity(environment);
  if (environmentCandidate.state === "invalid") return undefined;
  const candidateIdentity =
    parsedReceipt.candidateIdentity ??
    (environmentCandidate.state === "valid" ? environmentCandidate.identity : undefined);
  return {
    modes: Object.fromEntries(
      Object.entries(domainKeys).map(([domain, key]) => [
        domain,
        mode(environment[key]) ?? parsedReceipt.modes[domain as DomainCoreRuntimeDomain],
      ]),
    ) as Record<DomainCoreRuntimeDomain, DomainCoreRuntimeMode>,
    candidateIdentity,
  };
}

function resolveSignedProfile(receipt: DomainCoreBuildReceipt): ResolvedDomainCoreProfile | undefined {
  if (!receipt.candidateIdentity) return undefined;
  const valid =
    (receipt.name === "public-production" &&
      receipt.distribution === "public" &&
      !receipt.evidenceEnabled &&
      receipt.rolloutChannel === null &&
      !Object.values(receipt.modes).includes("shadow")) ||
    (receipt.name === "public-production-rollback" &&
      receipt.distribution === "public" &&
      !receipt.evidenceEnabled &&
      receipt.rolloutChannel === null &&
      Object.values(receipt.modes).every((value) => value === "legacy")) ||
    ((receipt.name === "internal" || receipt.name === "beta") &&
      receipt.distribution === receipt.name &&
      receipt.rolloutChannel === receipt.name &&
      receipt.evidenceEnabled &&
      receipt.modes.quota === "shadow");
  if (!valid) return undefined;

  return {
    modes: receipt.modes as Record<DomainCoreRuntimeDomain, DomainCoreRuntimeMode>,
    candidateIdentity: receipt.candidateIdentity,
    evidenceChannel: receipt.name === "internal" || receipt.name === "beta" ? receipt.name : undefined,
  };
}

function parseReceipt(value: unknown): DomainCoreBuildReceipt | undefined {
  if (!isRecord(value) || value.schemaVersion !== 1) return undefined;
  if (
    typeof value.name !== "string" ||
    (value.artifactAuthority !== "development" && value.artifactAuthority !== "signed") ||
    typeof value.distribution !== "string" ||
    (value.rolloutChannel !== null && value.rolloutChannel !== "internal" && value.rolloutChannel !== "beta") ||
    typeof value.evidenceEnabled !== "boolean" ||
    !isRecord(value.modes)
  ) {
    return undefined;
  }
  const receiptModes = value.modes;
  const modeKeys = Object.keys(receiptModes);
  if (
    modeKeys.length !== Object.keys(domainKeys).length ||
    Object.keys(domainKeys).some((domain) => mode(receiptModes[domain]) !== receiptModes[domain])
  ) {
    return undefined;
  }

  const candidate = resolveReceiptCandidateIdentity(value);
  if (candidate.state === "invalid") return undefined;
  const candidateIdentity = candidate.state === "valid" ? candidate.identity : undefined;
  if (
    value.artifactAuthority === "development" &&
    (value.name !== "developer" ||
      value.distribution !== "development" ||
      value.rolloutChannel !== null ||
      value.evidenceEnabled ||
      candidateIdentity !== undefined)
  ) {
    return undefined;
  }

  return {
    schemaVersion: value.schemaVersion,
    name: value.name,
    artifactAuthority: value.artifactAuthority,
    distribution: value.distribution,
    rolloutChannel: value.rolloutChannel,
    evidenceEnabled: value.evidenceEnabled,
    modes: receiptModes as Record<DomainCoreRuntimeDomain, DomainCoreRuntimeMode>,
    candidateIdentity: candidateIdentity ?? null,
  };
}

function resolveReceiptCandidateIdentity(receipt: Record<string, unknown>): CandidateIdentityResolution {
  if (!("candidateIdentity" in receipt)) return { state: "invalid" };
  const identity = receipt.candidateIdentity;
  if (identity === null) return { state: "absent" };
  if (!isRecord(identity)) return { state: "invalid" };
  if (
    Object.keys(identity).length !== 4 ||
    !isCandidateIdentity(identity.candidateCommit, identity.coreVersion, identity.abiVersion, identity.sourceSha256)
  ) {
    return { state: "invalid" };
  }
  return {
    state: "valid",
    identity: {
      candidateCommit: identity.candidateCommit as string,
      coreVersion: identity.coreVersion as string,
      abiVersion: identity.abiVersion as number,
      sourceSha256: identity.sourceSha256 as string,
    },
  };
}

function resolveEnvironmentCandidateIdentity(environment: NodeJS.ProcessEnv): CandidateIdentityResolution {
  const raw = {
    candidateCommit: environment[candidateKeys.candidateCommit],
    coreVersion: environment[candidateKeys.coreVersion],
    abiVersion: environment[candidateKeys.abiVersion],
    sourceSha256: environment[candidateKeys.sourceSha256],
  };
  const values = Object.values(raw);
  if (values.every((value) => value === undefined)) return { state: "absent" };
  if (values.some((value) => value === undefined) || !POSITIVE_DECIMAL.test(raw.abiVersion ?? "")) {
    return { state: "invalid" };
  }
  const abiVersion = Number(raw.abiVersion);
  if (!isCandidateIdentity(raw.candidateCommit, raw.coreVersion, abiVersion, raw.sourceSha256)) {
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

function isCandidateIdentity(
  candidateCommit: unknown,
  coreVersion: unknown,
  abiVersion: unknown,
  sourceSha256: unknown,
): boolean {
  return (
    typeof candidateCommit === "string" &&
    FULL_GIT_COMMIT.test(candidateCommit) &&
    typeof coreVersion === "string" &&
    coreVersion.length <= 64 &&
    CANONICAL_SEMVER.test(coreVersion) &&
    typeof abiVersion === "number" &&
    Number.isSafeInteger(abiVersion) &&
    abiVersion >= 1 &&
    abiVersion <= UINT32_MAX &&
    typeof sourceSha256 === "string" &&
    SHA256.test(sourceSha256)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function mode(value: unknown): DomainCoreRuntimeMode | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim().toLowerCase();
  return normalized === "legacy" || normalized === "shadow" || normalized === "rust" ? normalized : undefined;
}
