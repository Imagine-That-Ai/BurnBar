import { afterEach, describe, expect, it, vi } from "vitest";

const wasmModule = "../vendor/openburnbar-domain-core-wasm/openburnbar_domain_core.js";
const buildProfileModule = "../lib/domainCoreBuildProfile";
const shadowEvidenceModule = "../lib/domainCoreShadowEvidence";

const loadedIdentity = {
  coreVersion: "0.1.0",
  abiVersion: 3,
  sourceSha256: "a".repeat(64),
};
const expectedIdentity = {
  coreVersion: loadedIdentity.coreVersion,
  abiVersion: loadedIdentity.abiVersion,
  sourceSha256: "b".repeat(64),
};

async function loadAdapter(mode: "rust" | "shadow") {
  vi.resetModules();
  vi.doMock(wasmModule, () => ({
    default: vi.fn(async () => undefined),
    initSync: vi.fn(),
    CloudVaultHashPurpose: {},
    cloudVaultAadV2: vi.fn(),
    cloudVaultAesGcmOpenCombined: vi.fn(),
    cloudVaultAesGcmSealCombined: vi.fn(),
    cloudVaultBase64DecodeStrict: vi.fn(),
    cloudVaultBase64Encode: vi.fn(),
    cloudVaultEscrowOpen: vi.fn(),
    cloudVaultEscrowSeal: vi.fn(),
    cloudVaultEscrowSplitWire: vi.fn(),
    cloudVaultKeyedHashHex: vi.fn(),
    cloudVaultSha256Hex: vi.fn(),
    domainCoreVersion: () => loadedIdentity.coreVersion,
    domainCoreAbiVersion: () => loadedIdentity.abiVersion,
    domainCoreSourceFingerprint: () => loadedIdentity.sourceSha256,
  }));
  vi.doMock(buildProfileModule, () => ({
    resolveDomainCoreCandidateIdentity: () => expectedIdentity,
    resolveDomainCoreWebMode: () => mode,
  }));
  vi.doMock(shadowEvidenceModule, () => ({
    recordConsoleCloudVaultShadowComparison: vi.fn(),
  }));
  return import("../lib/domainCoreCloudVault");
}

afterEach(() => {
  vi.doUnmock(wasmModule);
  vi.doUnmock(buildProfileModule);
  vi.doUnmock(shadowEvidenceModule);
  vi.restoreAllMocks();
  vi.resetModules();
});

describe("CloudVault domain-core candidate identity routing", () => {
  it("rejects a wrong-source candidate before Rust or legacy executes", async () => {
    const { applyCloudVaultDomainCore } = await loadAdapter("rust");
    const legacy = vi.fn(() => "legacy");
    const rust = vi.fn(() => "rust");

    await expect(
      applyCloudVaultDomainCore("candidate_identity_test", legacy, rust),
    ).rejects.toThrow("loaded domain core identity does not match candidate");
    expect(legacy).not.toHaveBeenCalled();
    expect(rust).not.toHaveBeenCalled();
  });

  it("falls back once with sanitized evidence for a wrong-source shadow candidate", async () => {
    const {
      applyCloudVaultDomainCore,
      configureCloudVaultShadowCollector,
    } = await loadAdapter("shadow");
    const comparisons: unknown[] = [];
    const legacyValue = { authority: "legacy" };
    const legacy = vi.fn(() => legacyValue);
    const rust = vi.fn(() => ({ authority: "rust" }));
    configureCloudVaultShadowCollector((comparison) => comparisons.push(comparison));
    const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined);

    const actual = await applyCloudVaultDomainCore(
      "candidate_identity_test",
      legacy,
      rust,
    );

    expect(actual).toBe(legacyValue);
    expect(legacy).toHaveBeenCalledOnce();
    expect(rust).not.toHaveBeenCalled();
    expect(warning).toHaveBeenCalledWith(
      "domain_core.cloudvault.native_unavailable operation=candidate_identity_test core=abi3",
    );
    expect(comparisons).toEqual([
      {
        domain: "cloudvault",
        slice: "foundation",
        consumer: "console",
        operation: "candidate_identity_test",
        loadedCoreVersion: null,
        loadedCoreAbiVersion: null,
        loadedCoreSourceSha256: null,
        outcome: "mismatch",
        mismatchCategory: "native_unavailable",
        legacyMicros: expect.any(Number),
        rustMicros: expect.any(Number),
      },
    ]);
    expect(JSON.stringify(comparisons)).not.toContain(loadedIdentity.sourceSha256);
    expect(JSON.stringify(comparisons)).not.toContain(expectedIdentity.sourceSha256);
  });
});
