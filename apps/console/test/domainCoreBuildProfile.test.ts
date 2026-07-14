import { describe, expect, it } from "vitest";
import {
  resolveDomainCoreEvidenceChannel,
  resolveDomainCoreWebMode,
} from "../lib/domainCoreBuildProfile";

const domains = [
  "QUOTA",
  "CLOUDVAULT",
  "CLOUDVAULT_REWRAP",
  "CLOUDVAULT_SEARCH",
  "HERMES",
  "PRICING",
];

function signed(
  name: "public-production" | "internal" | "beta",
  mode: "legacy" | "shadow",
) {
  const environment: Record<string, string> = {
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "signed",
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE: name,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION:
      name === "public-production" ? "public" : name,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL:
      name === "public-production" ? "" : name,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED:
      name === "public-production" ? "0" : "1",
  };
  for (const domain of domains)
    environment[`NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_${domain}_MODE`] = mode;
  return environment;
}

describe("domain-core web build profile", () => {
  it("accepts a canonical public profile and ignores unsigned alternatives", () => {
    const environment = signed("public-production", "legacy");
    environment.OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE = "rust";
    expect(
      resolveDomainCoreWebMode(
        "cloudVault",
        environment,
        "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
      ),
    ).toBe("legacy");
  });

  it("fails closed when public metadata enables shadow evidence", () => {
    const environment = signed("public-production", "shadow");
    environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED = "1";
    expect(resolveDomainCoreWebMode("cloudVault", environment)).toBe("legacy");
  });

  it.each(["internal", "beta"] as const)(
    "accepts the %s profile only with matching channel and quota shadow",
    (name) => {
      const environment = signed(name, "shadow");
      expect(resolveDomainCoreWebMode("cloudVault", environment)).toBe(
        "shadow",
      );
      expect(resolveDomainCoreEvidenceChannel(environment)).toBe(name);
      environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL =
        name === "internal" ? "beta" : "internal";
      expect(resolveDomainCoreWebMode("cloudVault", environment)).toBe(
        "legacy",
      );
      expect(resolveDomainCoreEvidenceChannel(environment)).toBeUndefined();
    },
  );

  it("rejects evidence when a signed mode is missing or malformed", () => {
    const environment = signed("internal", "shadow");
    delete environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_HERMES_MODE;
    expect(resolveDomainCoreEvidenceChannel(environment)).toBeUndefined();
    environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_HERMES_MODE = "invalid";
    expect(resolveDomainCoreEvidenceChannel(environment)).toBeUndefined();
  });

  it("fails closed for unknown or unexpanded authority markers", () => {
    for (const authority of ["sigend", "${DOMAIN_CORE_BUILD_AUTHORITY}"]) {
      const environment = signed("internal", "shadow");
      environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY =
        authority;
      environment.OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE = "rust";
      expect(
        resolveDomainCoreWebMode(
          "cloudVault",
          environment,
          "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
        ),
      ).toBe("legacy");
      expect(resolveDomainCoreEvidenceChannel(environment)).toBeUndefined();
    }
  });
});
