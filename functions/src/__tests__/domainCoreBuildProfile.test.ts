import { describe, expect, it } from "vitest";
import { resolveDomainCoreEvidenceChannel, resolveDomainCoreRuntimeMode } from "../domainCoreBuildProfile.js";

const keys = ["QUOTA", "CLOUDVAULT", "CLOUDVAULT_REWRAP", "CLOUDVAULT_SEARCH", "HERMES", "PRICING"];

function signed(name: "public-production" | "internal" | "beta", mode: "legacy" | "shadow"): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = {
    OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "signed",
    OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE: name,
    OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION: name === "public-production" ? "public" : name,
    OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL: name === "public-production" ? "" : name,
    OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED: name === "public-production" ? "0" : "1",
  };
  for (const key of keys) environment[`OPENBURNBAR_DOMAIN_CORE_${key}_MODE`] = mode;
  return environment;
}

describe("domain-core Functions profile", () => {
  it("keeps development/test overrides", () => {
    expect(resolveDomainCoreRuntimeMode("pricing", { OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "rust" })).toBe("rust");
  });

  it("accepts valid public metadata and fails closed on shadow mutation", () => {
    const environment = signed("public-production", "legacy");
    environment.OPENBURNBAR_DOMAIN_CORE_PRICING_MODE = "rust";
    expect(resolveDomainCoreRuntimeMode("pricing", environment)).toBe("rust");
    environment.OPENBURNBAR_DOMAIN_CORE_HERMES_MODE = "shadow";
    expect(resolveDomainCoreRuntimeMode("pricing", environment)).toBe("legacy");
  });

  it.each(["internal", "beta"] as const)("requires matching %s enrollment metadata", (name) => {
    const environment = signed(name, "shadow");
    expect(resolveDomainCoreRuntimeMode("pricing", environment)).toBe("shadow");
    expect(resolveDomainCoreEvidenceChannel(environment)).toBe(name);
    environment.OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL = name === "internal" ? "beta" : "internal";
    expect(resolveDomainCoreRuntimeMode("pricing", environment)).toBe("legacy");
    expect(resolveDomainCoreEvidenceChannel(environment)).toBeUndefined();
  });
});
