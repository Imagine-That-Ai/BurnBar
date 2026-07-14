type DomainCoreRuntimeMode = "legacy" | "shadow" | "rust";
type DomainCoreRuntimeDomain =
  | "quota"
  | "cloudVault"
  | "cloudVaultRewrap"
  | "cloudVaultSearch"
  | "hermes"
  | "pricing";

export function resolveDomainCoreEvidenceChannel(
  environment: NodeJS.ProcessEnv = process.env,
): "internal" | "beta" | undefined {
  const channel = environment.OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL;
  if (
    environment.OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY !== "signed" ||
    environment.OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED !== "1" ||
    (channel !== "internal" && channel !== "beta") ||
    environment.OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE !== channel ||
    environment.OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION !== channel
  )
    return undefined;
  for (const key of Object.values(domainKeys)) {
    if (!mode(environment[key])) return undefined;
  }
  return mode(environment.OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE) === "shadow" ? channel : undefined;
}

const domainKeys: Record<DomainCoreRuntimeDomain, string> = {
  quota: "OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE",
  cloudVault: "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
  cloudVaultRewrap: "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE",
  cloudVaultSearch: "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE",
  hermes: "OPENBURNBAR_DOMAIN_CORE_HERMES_MODE",
  pricing: "OPENBURNBAR_DOMAIN_CORE_PRICING_MODE",
};

export function resolveDomainCoreRuntimeMode(
  domain: DomainCoreRuntimeDomain,
  environment: NodeJS.ProcessEnv = process.env,
): DomainCoreRuntimeMode {
  const authority = environment.OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY?.trim();
  if (authority === undefined || authority === "" || authority === "development") {
    return mode(environment[domainKeys[domain]]) ?? "legacy";
  }
  if (authority !== "signed") return "legacy";
  const modes: Record<DomainCoreRuntimeDomain, DomainCoreRuntimeMode | undefined> = {
    quota: mode(environment[domainKeys.quota]),
    cloudVault: mode(environment[domainKeys.cloudVault]),
    cloudVaultRewrap: mode(environment[domainKeys.cloudVaultRewrap]),
    cloudVaultSearch: mode(environment[domainKeys.cloudVaultSearch]),
    hermes: mode(environment[domainKeys.hermes]),
    pricing: mode(environment[domainKeys.pricing]),
  };
  if (Object.values(modes).some((value) => value === undefined)) return "legacy";
  const name = environment.OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE;
  const distribution = environment.OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION;
  const channel = environment.OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL || undefined;
  const evidence = environment.OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED === "1";
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
  return valid ? (modes[domain] ?? "legacy") : "legacy";
}

function mode(value: string | undefined): DomainCoreRuntimeMode | undefined {
  const normalized = value?.trim().toLowerCase();
  return normalized === "legacy" || normalized === "shadow" || normalized === "rust" ? normalized : undefined;
}
