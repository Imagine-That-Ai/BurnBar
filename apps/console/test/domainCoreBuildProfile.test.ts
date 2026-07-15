import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  resolveDomainCoreCandidateIdentity,
  resolveDomainCoreEvidenceChannel,
  resolveDomainCoreWebMode,
} from "../lib/domainCoreBuildProfile";

const CANDIDATE_COMMIT = "a".repeat(40);
const SOURCE_SHA256 = "b".repeat(64);
const publicBuildKeys = [
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_HERMES_MODE",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_PRICING_MODE",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION",
  "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256",
] as const;
const domains = [
  "QUOTA",
  "CLOUDVAULT",
  "CLOUDVAULT_REWRAP",
  "CLOUDVAULT_SEARCH",
  "HERMES",
  "PRICING",
];

function candidateIdentity(): Record<string, string> {
  return {
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: CANDIDATE_COMMIT,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION:
      "0.3.0-beta.1+build.7",
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION: "3",
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256: SOURCE_SHA256,
  };
}

function signed(
  name: "public-production" | "public-production-rollback" | "internal" | "beta",
  mode: "legacy" | "shadow",
): Record<string, string> {
  const environment: Record<string, string> = {
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "signed",
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE: name,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION:
      name.startsWith("public-production") ? "public" : name,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL:
      name.startsWith("public-production") ? "" : name,
    NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED:
      name.startsWith("public-production") ? "0" : "1",
    ...candidateIdentity(),
  };
  for (const domain of domains) {
    environment[`NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_${domain}_MODE`] = mode;
  }
  return environment;
}

describe("domain-core web build profile", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("reads every signed public value through the statically embeddable default loader", () => {
    for (const [key, value] of Object.entries(signed("internal", "shadow"))) {
      vi.stubEnv(key, value);
    }
    expect(resolveDomainCoreWebMode("pricing")).toBe("shadow");
    expect(resolveDomainCoreEvidenceChannel()).toBe("internal");
    expect(resolveDomainCoreCandidateIdentity()).toEqual(
      expect.objectContaining({ candidateCommit: CANDIDATE_COMMIT }),
    );
  });

  it("keeps every default public value visible to Next static replacement", () => {
    const source = readFileSync(
      fileURLToPath(
        new URL("../lib/domainCoreBuildProfile.ts", import.meta.url),
      ),
      "utf8",
    );
    for (const key of publicBuildKeys) {
      expect(source).toContain(`process.env.${key}`);
    }
    expect(source).not.toMatch(/process\.env\s*\[/u);
    expect(
      source.match(
        /environment: PublicEnvironment = embeddedPublicEnvironment\(\)/gu,
      ),
    ).toHaveLength(3);
  });

  it("accepts a candidate-bound public profile but keeps evidence disabled", () => {
    const environment = signed("public-production", "legacy");
    environment.OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE = "rust";

    expect(
      resolveDomainCoreWebMode(
        "cloudVault",
        environment,
        "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE",
      ),
    ).toBe("legacy");
    expect(resolveDomainCoreEvidenceChannel(environment)).toBeUndefined();
    expect(resolveDomainCoreCandidateIdentity(environment)).toEqual({
      candidateCommit: CANDIDATE_COMMIT,
      coreVersion: "0.3.0-beta.1+build.7",
      abiVersion: 3,
      sourceSha256: SOURCE_SHA256,
    });
  });

  it("uses the signed rollback profile for legacy even with hostile Rust overrides", () => {
    const environment = signed("public-production-rollback", "legacy");
    environment.OPENBURNBAR_DOMAIN_CORE_PRICING_MODE = "rust";
    expect(
      resolveDomainCoreWebMode(
        "pricing",
        environment,
        "OPENBURNBAR_DOMAIN_CORE_PRICING_MODE",
      ),
    ).toBe("legacy");
    environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_PRICING_MODE = "rust";
    expect(resolveDomainCoreWebMode("pricing", environment)).toBe("legacy");
  });

  it("fails closed when public metadata enables shadow evidence", () => {
    const environment = signed("public-production", "shadow");
    environment.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED = "1";
    expect(resolveDomainCoreWebMode("cloudVault", environment)).toBe("legacy");
    expect(resolveDomainCoreCandidateIdentity(environment)).toBeUndefined();
  });

  it.each(["internal", "beta"] as const)(
    "accepts the candidate-bound %s profile only with its matching channel",
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
      expect(resolveDomainCoreCandidateIdentity(environment)).toBeUndefined();
    },
  );

  it.each([
    "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT",
    "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION",
    "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION",
    "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256",
  ])("rejects a signed profile missing %s", (key) => {
    const environment: Record<string, string | undefined> = signed(
      "internal",
      "shadow",
    );
    delete environment[key];
    expect(resolveDomainCoreWebMode("pricing", environment)).toBe("legacy");
    expect(resolveDomainCoreEvidenceChannel(environment)).toBeUndefined();
    expect(resolveDomainCoreCandidateIdentity(environment)).toBeUndefined();
  });

  it.each([
    [
      "uppercase commit",
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT",
      "A".repeat(40),
    ],
    [
      "short commit",
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT",
      "a".repeat(39),
    ],
    [
      "noncanonical semver",
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION",
      "01.2.3",
    ],
    [
      "numeric prerelease with a leading zero",
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION",
      "1.2.3-01",
    ],
    [
      "oversized semver",
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION",
      `1.2.3+${"a".repeat(59)}`,
    ],
    [
      "zero ABI",
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION",
      "0",
    ],
    [
      "noncanonical ABI",
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION",
      "03",
    ],
    [
      "overflowing ABI",
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION",
      "4294967296",
    ],
    [
      "uppercase source digest",
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256",
      "B".repeat(64),
    ],
    [
      "short source digest",
      "NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256",
      "b".repeat(63),
    ],
  ])("rejects a signed profile with %s", (_label, key, value) => {
    const environment = signed("internal", "shadow");
    environment[key] = value;
    expect(resolveDomainCoreWebMode("pricing", environment)).toBe("legacy");
    expect(resolveDomainCoreEvidenceChannel(environment)).toBeUndefined();
    expect(resolveDomainCoreCandidateIdentity(environment)).toBeUndefined();
  });

  it("allows development to omit identity but rejects a partial tuple", () => {
    const development: Record<string, string | undefined> = {
      NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "development",
      NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "rust",
    };
    expect(resolveDomainCoreWebMode("pricing", development)).toBe("rust");
    expect(resolveDomainCoreCandidateIdentity(development)).toBeUndefined();

    development.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT =
      CANDIDATE_COMMIT;
    expect(resolveDomainCoreWebMode("pricing", development)).toBe("legacy");
    expect(resolveDomainCoreCandidateIdentity(development)).toBeUndefined();
  });

  it("returns a complete optional development identity", () => {
    const environment = {
      NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "development",
      NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "rust",
      ...candidateIdentity(),
    };
    expect(resolveDomainCoreWebMode("pricing", environment)).toBe("rust");
    expect(resolveDomainCoreCandidateIdentity(environment)).toEqual(
      expect.objectContaining({ candidateCommit: CANDIDATE_COMMIT }),
    );
  });

  it("rejects evidence when any signed mode is missing or malformed", () => {
    const environment: Record<string, string | undefined> = signed(
      "internal",
      "shadow",
    );
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
      expect(resolveDomainCoreCandidateIdentity(environment)).toBeUndefined();
    }
  });
});
