import { readFileSync } from "node:fs";
import { validateDomainCoreCandidateIdentity } from "./domain-core-candidate-receipt.mjs";

export const DOMAIN_CORE_PROFILE_SCHEMA_VERSION = 1;
export const DOMAIN_CORE_MODES = new Set(["legacy", "shadow", "rust"]);
export const DOMAIN_CORE_ARTIFACT_AUTHORITIES = new Set([
  "development",
  "signed",
]);
const FULL_SHA = /^[0-9a-f]{40}$/u;
const STABLE_RELEASE_VERSION =
  /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;
const DOMAIN_CORE_PROFILE_IDENTITIES = new Map([
  [
    "developer",
    { artifactAuthority: "development", distribution: "development" },
  ],
  [
    "public-production",
    { artifactAuthority: "signed", distribution: "public" },
  ],
  [
    "public-production-rollback",
    { artifactAuthority: "signed", distribution: "public" },
  ],
  ["internal", { artifactAuthority: "signed", distribution: "internal" }],
  ["beta", { artifactAuthority: "signed", distribution: "beta" }],
]);

export function loadDomainCoreBuildProfiles(path) {
  return validateDomainCoreBuildProfiles(
    JSON.parse(readFileSync(path, "utf8")),
  );
}

export function validateDomainCoreBuildProfiles(catalog) {
  if (!catalog || typeof catalog !== "object" || Array.isArray(catalog))
    throw new Error("profile catalog must be an object");
  if (catalog.schemaVersion !== DOMAIN_CORE_PROFILE_SCHEMA_VERSION)
    throw new Error("unsupported profile catalog schemaVersion");
  if (
    !Array.isArray(catalog.domains) ||
    catalog.domains.length === 0 ||
    new Set(catalog.domains).size !== catalog.domains.length
  ) {
    throw new Error("domains must be a non-empty unique string array");
  }
  if (catalog.domains.some((domain) => typeof domain !== "string" || !domain))
    throw new Error("domain names must be non-empty strings");
  if (
    !catalog.profiles ||
    typeof catalog.profiles !== "object" ||
    Array.isArray(catalog.profiles)
  )
    throw new Error("profiles must be an object");
  const profileNames = Object.keys(catalog.profiles);
  if (
    profileNames.length !== DOMAIN_CORE_PROFILE_IDENTITIES.size ||
    profileNames.some((name) => !DOMAIN_CORE_PROFILE_IDENTITIES.has(name))
  ) {
    throw new Error(
      "profiles must exactly declare developer, public-production, public-production-rollback, internal, and beta",
    );
  }
  if (!(catalog.defaultReleaseProfile in catalog.profiles))
    throw new Error("defaultReleaseProfile is not declared");

  for (const [name, profile] of Object.entries(catalog.profiles))
    validateProfile(name, profile, catalog.domains);
  if (catalog.defaultReleaseProfile !== "public-production") {
    throw new Error("defaultReleaseProfile must be public-production");
  }
  return catalog;
}

function validateProfile(name, profile, domains) {
  if (!profile || typeof profile !== "object" || Array.isArray(profile))
    throw new Error(`${name}: profile must be an object`);
  if (!DOMAIN_CORE_ARTIFACT_AUTHORITIES.has(profile.artifactAuthority))
    throw new Error(`${name}: invalid artifactAuthority`);
  if (
    !new Set(["development", "public", "internal", "beta"]).has(
      profile.distribution,
    )
  )
    throw new Error(`${name}: invalid distribution`);
  const identity = DOMAIN_CORE_PROFILE_IDENTITIES.get(name);
  if (
    !identity ||
    profile.artifactAuthority !== identity.artifactAuthority ||
    profile.distribution !== identity.distribution
  ) {
    throw new Error(
      `${name}: artifactAuthority and distribution do not match the canonical profile identity`,
    );
  }
  if (
    profile.rolloutChannel !== null &&
    profile.rolloutChannel !== "internal" &&
    profile.rolloutChannel !== "beta"
  ) {
    throw new Error(`${name}: invalid rolloutChannel`);
  }
  if (typeof profile.evidenceEnabled !== "boolean")
    throw new Error(`${name}: evidenceEnabled must be boolean`);
  if (
    !profile.modes ||
    typeof profile.modes !== "object" ||
    Array.isArray(profile.modes)
  )
    throw new Error(`${name}: modes must be an object`);
  const modeKeys = Object.keys(profile.modes);
  if (
    modeKeys.length !== domains.length ||
    domains.some((domain) => !modeKeys.includes(domain))
  ) {
    throw new Error(`${name}: modes must exactly cover catalog domains`);
  }
  for (const domain of domains) {
    if (!DOMAIN_CORE_MODES.has(profile.modes[domain]))
      throw new Error(`${name}: invalid ${domain} mode`);
  }

  if (
    name === "public-production-rollback" &&
    Object.values(profile.modes).some((mode) => mode !== "legacy")
  ) {
    throw new Error(
      "public-production-rollback: every mode must remain legacy",
    );
  }

  if (
    profile.artifactAuthority === "signed" &&
    profile.distribution === "public"
  ) {
    if (
      profile.evidenceEnabled ||
      profile.rolloutChannel !== null ||
      Object.values(profile.modes).includes("shadow")
    ) {
      throw new Error(
        `${name}: public signed profiles cannot enable evidence, a rollout channel, or shadow mode`,
      );
    }
  }
  if (
    profile.artifactAuthority === "signed" &&
    (profile.distribution === "internal" || profile.distribution === "beta")
  ) {
    if (
      profile.rolloutChannel !== profile.distribution ||
      !profile.evidenceEnabled ||
      profile.modes.quota !== "shadow"
    ) {
      throw new Error(
        `${name}: signed ${profile.distribution} profiles require matching channel, evidence, and quota shadow`,
      );
    }
  }
  if (
    profile.artifactAuthority === "development" &&
    (profile.evidenceEnabled || profile.rolloutChannel !== null)
  ) {
    throw new Error(
      `${name}: development profiles cannot upload rollout evidence`,
    );
  }
}

export function resolveDomainCoreBuildProfile(
  catalog,
  name,
  candidateIdentity,
  releaseCoordinates,
) {
  validateDomainCoreBuildProfiles(catalog);
  const profile = catalog.profiles[name];
  if (!profile) throw new Error(`unknown domain-core build profile: ${name}`);
  if (
    profile.artifactAuthority === "signed" &&
    candidateIdentity === undefined
  ) {
    throw new Error(
      `${name}: signed profiles require a complete candidate identity`,
    );
  }
  const resolved = {
    schemaVersion: catalog.schemaVersion,
    name,
    ...structuredClone(profile),
    candidateIdentity: null,
  };
  if (candidateIdentity !== undefined) {
    resolved.candidateIdentity =
      validateDomainCoreCandidateIdentity(candidateIdentity);
  }
  if (releaseCoordinates !== undefined) {
    if (
      typeof releaseCoordinates.version !== "string" ||
      !STABLE_RELEASE_VERSION.test(releaseCoordinates.version)
    ) {
      throw new Error("rollback profile release version is invalid");
    }
    const expectedTag = `v${releaseCoordinates.version}`;
    if (releaseCoordinates.tag !== expectedTag) {
      throw new Error(`rollback profile release tag must be ${expectedTag}`);
    }
    if (
      typeof releaseCoordinates.commit !== "string" ||
      !FULL_SHA.test(releaseCoordinates.commit)
    ) {
      throw new Error(
        "rollback profile release commit must be a full lowercase Git SHA-1",
      );
    }
    if (
      resolved.candidateIdentity !== null &&
      releaseCoordinates.commit ===
        resolved.candidateIdentity.candidateCommit &&
      Object.values(resolved.modes).includes("rust")
    ) {
      throw new Error(
        "Rust activation requires distinct candidate and release commits",
      );
    }
    resolved.release = {
      version: releaseCoordinates.version,
      tag: releaseCoordinates.tag,
      commit: releaseCoordinates.commit,
    };
  }
  return resolved;
}

export function profileEnvironment(profile) {
  const environment = {
    OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE: profile.name,
    OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: profile.artifactAuthority,
    OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION: profile.distribution,
    OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL: profile.rolloutChannel ?? "",
    OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED: profile.evidenceEnabled
      ? "1"
      : "0",
    OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE: profile.modes.quota,
    OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE: profile.modes.cloudVault,
    OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE:
      profile.modes.cloudVaultRewrap,
    OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE:
      profile.modes.cloudVaultSearch,
    OPENBURNBAR_DOMAIN_CORE_HERMES_MODE: profile.modes.hermes,
    OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: profile.modes.pricing,
  };
  if (profile.candidateIdentity) {
    environment.OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT =
      profile.candidateIdentity.candidateCommit;
    environment.OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION =
      profile.candidateIdentity.coreVersion;
    environment.OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION = String(
      profile.candidateIdentity.abiVersion,
    );
    environment.OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256 =
      profile.candidateIdentity.sourceSha256;
  }
  return environment;
}

export function profileWebEnvironment(profile) {
  return Object.fromEntries(
    Object.entries(profileEnvironment(profile)).map(([key, value]) => [
      `NEXT_PUBLIC_${key}`,
      value,
    ]),
  );
}

export function profileAppleEnvironment(profile) {
  const environment = profileEnvironment(profile);
  const apple = {
    DOMAIN_CORE_BUILD_PROFILE: profile.name,
    DOMAIN_CORE_BUILD_AUTHORITY: profile.artifactAuthority,
    DOMAIN_CORE_DISTRIBUTION: profile.distribution,
    DOMAIN_CORE_ROLLOUT_CHANNEL: profile.rolloutChannel ?? "",
    DOMAIN_CORE_EVIDENCE_ENABLED: profile.evidenceEnabled ? "YES" : "NO",
    DOMAIN_CORE_QUOTA_MODE: environment.OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE,
    DOMAIN_CORE_CLOUDVAULT_MODE:
      environment.OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE,
    DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE:
      environment.OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE,
    DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE:
      environment.OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE,
    DOMAIN_CORE_HERMES_MODE: environment.OPENBURNBAR_DOMAIN_CORE_HERMES_MODE,
    DOMAIN_CORE_PRICING_MODE: environment.OPENBURNBAR_DOMAIN_CORE_PRICING_MODE,
  };
  if (profile.candidateIdentity) {
    apple.DOMAIN_CORE_CANDIDATE_COMMIT =
      profile.candidateIdentity.candidateCommit;
    apple.DOMAIN_CORE_EXPECTED_VERSION = profile.candidateIdentity.coreVersion;
    apple.DOMAIN_CORE_EXPECTED_ABI_VERSION = String(
      profile.candidateIdentity.abiVersion,
    );
    apple.DOMAIN_CORE_EXPECTED_SOURCE_SHA256 =
      profile.candidateIdentity.sourceSha256;
  }
  return apple;
}

export function profileMSBuildProperties(profile) {
  const properties = {
    DomainCoreBuildProfile: profile.name,
    DomainCoreBuildAuthority: profile.artifactAuthority,
    DomainCoreDistribution: profile.distribution,
    DomainCoreRolloutChannel: profile.rolloutChannel ?? "",
    DomainCoreEvidenceEnabled: profile.evidenceEnabled ? "true" : "false",
    DomainCoreQuotaMode: profile.modes.quota,
    DomainCoreCloudVaultMode: profile.modes.cloudVault,
    DomainCoreCloudVaultRewrapMode: profile.modes.cloudVaultRewrap,
    DomainCoreCloudVaultSearchMode: profile.modes.cloudVaultSearch,
    DomainCoreHermesMode: profile.modes.hermes,
    DomainCorePricingMode: profile.modes.pricing,
  };
  if (profile.candidateIdentity) {
    properties.DomainCoreCandidateCommit =
      profile.candidateIdentity.candidateCommit;
    properties.DomainCoreExpectedVersion =
      profile.candidateIdentity.coreVersion;
    properties.DomainCoreExpectedAbiVersion = String(
      profile.candidateIdentity.abiVersion,
    );
    properties.DomainCoreExpectedSourceSha256 =
      profile.candidateIdentity.sourceSha256;
  }
  return properties;
}

export function profileFunctionsJavaScript(profile) {
  if (profile.artifactAuthority !== "signed" || !profile.candidateIdentity) {
    throw new Error(
      "Functions artifact generation requires a signed profile with candidate identity",
    );
  }
  return `"use strict";\nObject.defineProperty(exports, "__esModule", { value: true });\nconst receipt = ${JSON.stringify(profile, null, 2)};\nObject.freeze(receipt.candidateIdentity);\nObject.freeze(receipt.modes);\nexports.DOMAIN_CORE_CANDIDATE_RECEIPT = Object.freeze(receipt);\n`;
}

export function parseDomainCoreFunctionsJavaScript(source) {
  const prefix = `"use strict";\nObject.defineProperty(exports, "__esModule", { value: true });\nconst receipt = `;
  const suffix = `;\nObject.freeze(receipt.candidateIdentity);\nObject.freeze(receipt.modes);\nexports.DOMAIN_CORE_CANDIDATE_RECEIPT = Object.freeze(receipt);\n`;
  if (
    typeof source !== "string" ||
    !source.startsWith(prefix) ||
    !source.endsWith(suffix)
  ) {
    throw new Error(
      "Functions domain-core receipt module has an invalid generated envelope",
    );
  }
  return JSON.parse(source.slice(prefix.length, -suffix.length));
}
