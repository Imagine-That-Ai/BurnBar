import { describe, expect, it } from "vitest";
import {
  domainCoreDeploymentIdentity,
  resolveDomainCoreCandidateIdentity,
  resolveDomainCoreEvidenceChannel,
  resolveDomainCoreRuntimeMode,
} from "../domainCoreBuildProfile.js";
import { DOMAIN_CORE_CANDIDATE_RECEIPT } from "../generated/domainCoreCandidateReceipt.js";

const CANDIDATE_COMMIT = "a".repeat(40);
const SOURCE_SHA256 = "b".repeat(64);
const domains = ["quota", "cloudVault", "cloudVaultRewrap", "cloudVaultSearch", "hermes", "pricing"] as const;

function candidateIdentity() {
  return {
    candidateCommit: CANDIDATE_COMMIT,
    coreVersion: "0.3.0-beta.1+build.7",
    abiVersion: 3,
    sourceSha256: SOURCE_SHA256,
  };
}

function signedReceipt(
  name: "public-production" | "public-production-rollback" | "internal" | "beta",
  mode: "legacy" | "shadow" | "rust",
) {
  return {
    schemaVersion: 1,
    name,
    artifactAuthority: "signed",
    distribution: name.startsWith("public-production") ? "public" : name,
    rolloutChannel: name.startsWith("public-production") ? null : name,
    evidenceEnabled: !name.startsWith("public-production"),
    modes: Object.fromEntries(domains.map((domain) => [domain, mode])) as Record<(typeof domains)[number], string>,
    candidateIdentity: candidateIdentity(),
  };
}

function developerReceipt() {
  return {
    schemaVersion: 1,
    name: "developer",
    artifactAuthority: "development",
    distribution: "development",
    rolloutChannel: null,
    evidenceEnabled: false,
    modes: Object.fromEntries(domains.map((domain) => [domain, "legacy"])) as Record<(typeof domains)[number], string>,
    candidateIdentity: null,
  };
}

describe("domain-core Functions profile", () => {
  it("checks in an immutable development-default bundled receipt", () => {
    expect(DOMAIN_CORE_CANDIDATE_RECEIPT).toMatchObject({
      name: "developer",
      artifactAuthority: "development",
      candidateIdentity: null,
    });
    expect(Object.isFrozen(DOMAIN_CORE_CANDIDATE_RECEIPT)).toBe(true);
    expect(Object.isFrozen(DOMAIN_CORE_CANDIDATE_RECEIPT.modes)).toBe(true);
    expect(
      resolveDomainCoreRuntimeMode("pricing", {
        OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "rust",
      }),
    ).toBe("rust");
  });

  it("keeps development overrides and permits identity omission", () => {
    const environment = {
      OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "development",
      OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "rust",
    };
    expect(resolveDomainCoreRuntimeMode("pricing", environment, developerReceipt())).toBe("rust");
    expect(resolveDomainCoreCandidateIdentity(environment, developerReceipt())).toBeUndefined();
  });

  it("fails closed when a signed runtime environment has no signed bundled receipt", () => {
    const environment = {
      OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "signed",
      OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "rust",
      OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: CANDIDATE_COMMIT,
      OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION: "0.3.0",
      OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION: "3",
      OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256: SOURCE_SHA256,
    };
    expect(resolveDomainCoreRuntimeMode("pricing", environment, developerReceipt())).toBe("legacy");
    expect(resolveDomainCoreCandidateIdentity(environment, developerReceipt())).toBeUndefined();
  });

  it("uses the immutable signed receipt instead of mutable runtime values", () => {
    const receipt = signedReceipt("internal", "shadow");
    const hostileEnvironment = {
      OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "unknown",
      OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE: "public-production",
      OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION: "public",
      OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL: "beta",
      OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED: "0",
      OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "legacy",
      OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: "c".repeat(40),
    };

    expect(resolveDomainCoreRuntimeMode("pricing", hostileEnvironment, receipt)).toBe("shadow");
    expect(resolveDomainCoreEvidenceChannel(hostileEnvironment, receipt)).toBe("internal");
    expect(resolveDomainCoreCandidateIdentity(hostileEnvironment, receipt)).toEqual(candidateIdentity());
  });

  it("accepts a candidate-bound public receipt but keeps evidence disabled", () => {
    const receipt = signedReceipt("public-production", "rust");
    expect(resolveDomainCoreRuntimeMode("pricing", {}, receipt)).toBe("rust");
    expect(resolveDomainCoreEvidenceChannel({}, receipt)).toBeUndefined();
    expect(resolveDomainCoreCandidateIdentity({}, receipt)).toEqual(candidateIdentity());
  });

  it("uses the signed rollback receipt for legacy despite hostile runtime values", () => {
    const receipt = signedReceipt("public-production-rollback", "legacy");
    const environment = {
      OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "development",
      OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE: "public-production",
      OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "rust",
    };
    expect(resolveDomainCoreRuntimeMode("pricing", environment, receipt)).toBe("legacy");
    const invalidReceipt = {
      ...receipt,
      modes: { ...receipt.modes, pricing: "rust" },
    };
    expect(resolveDomainCoreRuntimeMode("pricing", environment, invalidReceipt)).toBe("legacy");
  });

  it("exposes the immutable non-secret receipt identity for deployment health", () => {
    const receipt = signedReceipt("public-production", "rust");
    expect(domainCoreDeploymentIdentity(receipt)).toEqual({
      profile: "public-production",
      candidateIdentity: candidateIdentity(),
      pricingMode: "rust",
    });
    expect(domainCoreDeploymentIdentity({})).toBeUndefined();
  });

  it.each(["internal", "beta"] as const)("requires matching %s enrollment metadata in the bundled receipt", (name) => {
    const receipt = signedReceipt(name, "shadow");
    expect(resolveDomainCoreRuntimeMode("pricing", {}, receipt)).toBe("shadow");
    expect(resolveDomainCoreEvidenceChannel({}, receipt)).toBe(name);

    receipt.rolloutChannel = name === "internal" ? "beta" : "internal";
    expect(resolveDomainCoreRuntimeMode("pricing", {}, receipt)).toBe("legacy");
    expect(resolveDomainCoreEvidenceChannel({}, receipt)).toBeUndefined();
    expect(resolveDomainCoreCandidateIdentity({}, receipt)).toBeUndefined();
  });

  it.each(["candidateCommit", "coreVersion", "abiVersion", "sourceSha256"])(
    "rejects a signed receipt missing candidateIdentity.%s",
    (key) => {
      const receipt = signedReceipt("internal", "shadow") as unknown as {
        candidateIdentity: Record<string, unknown>;
      };
      delete receipt.candidateIdentity[key];
      expect(resolveDomainCoreRuntimeMode("pricing", {}, receipt)).toBe("legacy");
      expect(resolveDomainCoreEvidenceChannel({}, receipt)).toBeUndefined();
      expect(resolveDomainCoreCandidateIdentity({}, receipt)).toBeUndefined();
    },
  );

  it.each([
    ["uppercase commit", "candidateCommit", "A".repeat(40)],
    ["short commit", "candidateCommit", "a".repeat(39)],
    ["noncanonical semver", "coreVersion", "01.2.3"],
    ["numeric prerelease with a leading zero", "coreVersion", "1.2.3-01"],
    ["oversized semver", "coreVersion", `1.2.3+${"a".repeat(59)}`],
    ["zero ABI", "abiVersion", 0],
    ["fractional ABI", "abiVersion", 1.5],
    ["overflowing ABI", "abiVersion", 0x1_0000_0000],
    ["uppercase source digest", "sourceSha256", "B".repeat(64)],
    ["short source digest", "sourceSha256", "b".repeat(63)],
  ])("rejects a signed receipt with %s", (_label, key, value) => {
    const receipt = signedReceipt("internal", "shadow") as unknown as {
      candidateIdentity: Record<string, unknown>;
    };
    receipt.candidateIdentity[key] = value;
    expect(resolveDomainCoreRuntimeMode("pricing", {}, receipt)).toBe("legacy");
    expect(resolveDomainCoreEvidenceChannel({}, receipt)).toBeUndefined();
    expect(resolveDomainCoreCandidateIdentity({}, receipt)).toBeUndefined();
  });

  it("rejects an extra candidate identity field", () => {
    const receipt = signedReceipt("internal", "shadow") as unknown as {
      candidateIdentity: Record<string, unknown>;
    };
    receipt.candidateIdentity.untrusted = "value";
    expect(resolveDomainCoreRuntimeMode("pricing", {}, receipt)).toBe("legacy");
  });

  it("rejects partial development env identity", () => {
    const partial = {
      OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "rust",
      OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: CANDIDATE_COMMIT,
    };
    expect(resolveDomainCoreRuntimeMode("pricing", partial, developerReceipt())).toBe("legacy");
    expect(resolveDomainCoreCandidateIdentity(partial, developerReceipt())).toBeUndefined();
  });

  it("parses a complete optional development identity from canonical env keys", () => {
    const environment = {
      OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT: CANDIDATE_COMMIT,
      OPENBURNBAR_DOMAIN_CORE_EXPECTED_VERSION: "0.3.0",
      OPENBURNBAR_DOMAIN_CORE_EXPECTED_ABI_VERSION: "3",
      OPENBURNBAR_DOMAIN_CORE_EXPECTED_SOURCE_SHA256: SOURCE_SHA256,
    };
    expect(resolveDomainCoreCandidateIdentity(environment, developerReceipt())).toEqual({
      candidateCommit: CANDIDATE_COMMIT,
      coreVersion: "0.3.0",
      abiVersion: 3,
      sourceSha256: SOURCE_SHA256,
    });
  });

  it("requires the canonical developer receipt to carry explicit null identity", () => {
    const missing = developerReceipt() as unknown as Record<string, unknown>;
    delete missing.candidateIdentity;
    expect(resolveDomainCoreRuntimeMode("pricing", {}, missing)).toBe("legacy");

    const populated = developerReceipt() as unknown as Record<string, unknown>;
    populated.candidateIdentity = candidateIdentity();
    expect(resolveDomainCoreRuntimeMode("pricing", {}, populated)).toBe("legacy");
  });

  it("rejects malformed receipt modes instead of normalizing them", () => {
    const receipt = signedReceipt("internal", "shadow");
    (receipt.modes as Record<string, string>).pricing = "SHADOW";
    expect(resolveDomainCoreRuntimeMode("pricing", {}, receipt)).toBe("legacy");
  });
});
