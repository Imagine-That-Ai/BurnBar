import { readFileSync } from "node:fs";

export const DOMAIN_CORE_PROFILE_SCHEMA_VERSION = 1;
export const DOMAIN_CORE_MODES = new Set(["legacy", "shadow", "rust"]);
export const DOMAIN_CORE_ARTIFACT_AUTHORITIES = new Set(["development", "signed"]);

export function loadDomainCoreBuildProfiles(path) {
  return validateDomainCoreBuildProfiles(JSON.parse(readFileSync(path, "utf8")));
}

export function validateDomainCoreBuildProfiles(catalog) {
  if (!catalog || typeof catalog !== "object" || Array.isArray(catalog)) throw new Error("profile catalog must be an object");
  if (catalog.schemaVersion !== DOMAIN_CORE_PROFILE_SCHEMA_VERSION) throw new Error("unsupported profile catalog schemaVersion");
  if (!Array.isArray(catalog.domains) || catalog.domains.length === 0 || new Set(catalog.domains).size !== catalog.domains.length) {
    throw new Error("domains must be a non-empty unique string array");
  }
  if (catalog.domains.some((domain) => typeof domain !== "string" || !domain)) throw new Error("domain names must be non-empty strings");
  if (!catalog.profiles || typeof catalog.profiles !== "object" || Array.isArray(catalog.profiles)) throw new Error("profiles must be an object");
  if (!(catalog.defaultReleaseProfile in catalog.profiles)) throw new Error("defaultReleaseProfile is not declared");

  for (const [name, profile] of Object.entries(catalog.profiles)) validateProfile(name, profile, catalog.domains);
  if (catalog.profiles[catalog.defaultReleaseProfile].artifactAuthority !== "signed") {
    throw new Error("defaultReleaseProfile must be signed");
  }
  return catalog;
}

function validateProfile(name, profile, domains) {
  if (!profile || typeof profile !== "object" || Array.isArray(profile)) throw new Error(`${name}: profile must be an object`);
  if (!DOMAIN_CORE_ARTIFACT_AUTHORITIES.has(profile.artifactAuthority)) throw new Error(`${name}: invalid artifactAuthority`);
  if (!new Set(["development", "public", "internal", "beta"]).has(profile.distribution)) throw new Error(`${name}: invalid distribution`);
  if (profile.rolloutChannel !== null && profile.rolloutChannel !== "internal" && profile.rolloutChannel !== "beta") {
    throw new Error(`${name}: invalid rolloutChannel`);
  }
  if (typeof profile.evidenceEnabled !== "boolean") throw new Error(`${name}: evidenceEnabled must be boolean`);
  if (!profile.modes || typeof profile.modes !== "object" || Array.isArray(profile.modes)) throw new Error(`${name}: modes must be an object`);
  const modeKeys = Object.keys(profile.modes);
  if (modeKeys.length !== domains.length || domains.some((domain) => !modeKeys.includes(domain))) {
    throw new Error(`${name}: modes must exactly cover catalog domains`);
  }
  for (const domain of domains) {
    if (!DOMAIN_CORE_MODES.has(profile.modes[domain])) throw new Error(`${name}: invalid ${domain} mode`);
  }

  if (profile.artifactAuthority === "signed" && profile.distribution === "public") {
    if (profile.evidenceEnabled || profile.rolloutChannel !== null || Object.values(profile.modes).includes("shadow")) {
      throw new Error(`${name}: public signed profiles cannot enable evidence, a rollout channel, or shadow mode`);
    }
  }
  if (profile.artifactAuthority === "signed" && (profile.distribution === "internal" || profile.distribution === "beta")) {
    if (profile.rolloutChannel !== profile.distribution || !profile.evidenceEnabled || profile.modes.quota !== "shadow") {
      throw new Error(`${name}: signed ${profile.distribution} profiles require matching channel, evidence, and quota shadow`);
    }
  }
  if (profile.artifactAuthority === "development" && (profile.evidenceEnabled || profile.rolloutChannel !== null)) {
    throw new Error(`${name}: development profiles cannot upload rollout evidence`);
  }
}

export function resolveDomainCoreBuildProfile(catalog, name) {
  validateDomainCoreBuildProfiles(catalog);
  const profile = catalog.profiles[name];
  if (!profile) throw new Error(`unknown domain-core build profile: ${name}`);
  return {
    schemaVersion: catalog.schemaVersion,
    name,
    ...structuredClone(profile),
  };
}

export function profileEnvironment(profile) {
  return {
    OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE: profile.name,
    OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: profile.artifactAuthority,
    OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION: profile.distribution,
    OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL: profile.rolloutChannel ?? "",
    OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED: profile.evidenceEnabled ? "1" : "0",
    OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE: profile.modes.quota,
    OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE: profile.modes.cloudVault,
    OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE: profile.modes.cloudVaultRewrap,
    OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE: profile.modes.cloudVaultSearch,
    OPENBURNBAR_DOMAIN_CORE_HERMES_MODE: profile.modes.hermes,
    OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: profile.modes.pricing,
  };
}

export function profileWebEnvironment(profile) {
  return Object.fromEntries(
    Object.entries(profileEnvironment(profile)).map(([key, value]) => [`NEXT_PUBLIC_${key}`, value]),
  );
}

export function profileAppleEnvironment(profile) {
  const environment = profileEnvironment(profile);
  return {
    DOMAIN_CORE_BUILD_PROFILE: profile.name,
    DOMAIN_CORE_BUILD_AUTHORITY: profile.artifactAuthority,
    DOMAIN_CORE_DISTRIBUTION: profile.distribution,
    DOMAIN_CORE_ROLLOUT_CHANNEL: profile.rolloutChannel ?? "",
    DOMAIN_CORE_EVIDENCE_ENABLED: profile.evidenceEnabled ? "YES" : "NO",
    DOMAIN_CORE_QUOTA_MODE: environment.OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE,
    DOMAIN_CORE_CLOUDVAULT_MODE: environment.OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE,
    DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE: environment.OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE,
    DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE: environment.OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE,
    DOMAIN_CORE_HERMES_MODE: environment.OPENBURNBAR_DOMAIN_CORE_HERMES_MODE,
    DOMAIN_CORE_PRICING_MODE: environment.OPENBURNBAR_DOMAIN_CORE_PRICING_MODE,
  };
}

export function profileMSBuildProperties(profile) {
  return {
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
}
