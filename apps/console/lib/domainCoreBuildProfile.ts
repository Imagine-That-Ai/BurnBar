export type DomainCoreMode = "legacy" | "shadow" | "rust";

type PublicEnvironment = Record<string, string | undefined>;

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

export type DomainCoreWebDomain = keyof typeof domainKeys;

export function resolveDomainCoreWebMode(
  domain: DomainCoreWebDomain,
  environment: PublicEnvironment = process.env,
  developmentKey: string = domainKeys[domain],
): DomainCoreMode {
  const embedded = mode(environment[domainKeys[domain]]);
  if (
    environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY !== "signed"
  ) {
    return mode(environment[developmentKey]) ?? embedded ?? "legacy";
  }
  const modes = Object.fromEntries(
    Object.entries(domainKeys).map(([name, key]) => [
      name,
      mode(environment[key]),
    ]),
  ) as Record<DomainCoreWebDomain, DomainCoreMode | undefined>;
  if (Object.values(modes).some((value) => value === undefined))
    return "legacy";
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
  return valid ? (modes[domain] ?? "legacy") : "legacy";
}

function mode(value: string | undefined): DomainCoreMode | undefined {
  const normalized = value?.trim().toLowerCase();
  return normalized === "legacy" ||
    normalized === "shadow" ||
    normalized === "rust"
    ? normalized
    : undefined;
}
