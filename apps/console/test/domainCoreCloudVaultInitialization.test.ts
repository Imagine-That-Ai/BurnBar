import { afterEach, describe, expect, it, vi } from "vitest";
import { base64ToBytes, bytesToBase64 } from "../lib/escrow";
import {
  applyCloudVaultDomainCore,
  configureCloudVaultDomainCoreForTests,
  configureCloudVaultShadowCollector,
  isCloudVaultDomainCoreInitialized,
} from "../lib/domainCoreCloudVault";

afterEach(() => {
  configureCloudVaultDomainCoreForTests(undefined);
  vi.restoreAllMocks();
});

describe("CloudVault domain-core initialization boundary", () => {
  it("fails closed before Wasm initialization in explicit rust mode", () => {
    expect(isCloudVaultDomainCoreInitialized()).toBe(false);
    configureCloudVaultDomainCoreForTests("rust");

    expect(() => bytesToBase64(Uint8Array.of(0))).toThrow(
      "domain core Wasm is required but not initialized",
    );
    expect(() => base64ToBytes("AA==")).toThrow(
      "domain core Wasm is required but not initialized",
    );
  });

  it("returns the exact legacy value and emits sanitized evidence when Wasm initialization fails", async () => {
    const comparisons: unknown[] = [];
    const legacyValue = { authority: "legacy" };
    vi.spyOn(globalThis, "fetch").mockRejectedValue(
      new Error("private loader failure"),
    );
    configureCloudVaultDomainCoreForTests("shadow");
    configureCloudVaultShadowCollector((comparison) =>
      comparisons.push(comparison),
    );
    vi.spyOn(console, "warn").mockImplementation(() => undefined);

    const actual = await applyCloudVaultDomainCore(
      "cloudvault_aes_open_combined",
      () => legacyValue,
      () => ({ authority: "rust" }),
    );

    expect(actual).toBe(legacyValue);
    expect(comparisons).toEqual([
      {
        domain: "cloudvault",
        slice: "aes",
        consumer: "console",
        operation: "cloudvault_aes_open_combined",
        loadedCoreVersion: null,
        loadedCoreAbiVersion: null,
        loadedCoreSourceSha256: null,
        outcome: "mismatch",
        mismatchCategory: "native_unavailable",
        legacyMicros: expect.any(Number),
        rustMicros: expect.any(Number),
      },
    ]);
  });

  it("keeps the synchronous legacy helper authoritative in shadow mode", () => {
    expect(isCloudVaultDomainCoreInitialized()).toBe(false);
    configureCloudVaultDomainCoreForTests("shadow");
    const comparisons: unknown[] = [];
    configureCloudVaultShadowCollector((comparison) =>
      comparisons.push(comparison),
    );
    const warning = vi
      .spyOn(console, "warn")
      .mockImplementation(() => undefined);

    expect(bytesToBase64(Uint8Array.of(0))).toBe("AA==");
    expect(base64ToBytes("AA==")).toEqual(Uint8Array.of(0));
    expect(warning).toHaveBeenCalledWith(
      "domain_core.cloudvault.native_unavailable operation=base64_encode core=abi3",
    );
    expect(warning).toHaveBeenCalledWith(
      "domain_core.cloudvault.native_unavailable operation=base64_decode core=abi3",
    );
    expect(comparisons).toEqual([
      expect.objectContaining({
        operation: "base64_encode",
        loadedCoreVersion: null,
        loadedCoreAbiVersion: null,
        loadedCoreSourceSha256: null,
        mismatchCategory: "native_unavailable",
        rustMicros: 0,
      }),
      expect.objectContaining({
        operation: "base64_decode",
        loadedCoreVersion: null,
        loadedCoreAbiVersion: null,
        loadedCoreSourceSha256: null,
        mismatchCategory: "native_unavailable",
        rustMicros: 0,
      }),
    ]);
  });
});
