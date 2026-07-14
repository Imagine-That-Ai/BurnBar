import { afterEach, describe, expect, it, vi } from "vitest";
import { base64ToBytes, bytesToBase64 } from "../lib/escrow";
import {
  configureCloudVaultDomainCoreForTests,
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

  it("keeps the synchronous legacy helper authoritative in shadow mode", () => {
    expect(isCloudVaultDomainCoreInitialized()).toBe(false);
    configureCloudVaultDomainCoreForTests("shadow");
    const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined);

    expect(bytesToBase64(Uint8Array.of(0))).toBe("AA==");
    expect(base64ToBytes("AA==")).toEqual(Uint8Array.of(0));
    expect(warning).toHaveBeenCalledWith(
      "domain_core.cloudvault.native_unavailable operation=base64_encode core=abi3",
    );
    expect(warning).toHaveBeenCalledWith(
      "domain_core.cloudvault.native_unavailable operation=base64_decode core=abi3",
    );
  });
});
