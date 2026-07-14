import initDomainCore, {
  CloudVaultHashPurpose,
  cloudVaultAadV2,
  cloudVaultAesGcmOpenCombined,
  cloudVaultAesGcmSealCombined,
  cloudVaultBase64DecodeStrict,
  cloudVaultBase64Encode,
  cloudVaultEscrowOpen,
  cloudVaultEscrowSeal,
  cloudVaultEscrowSplitWire,
  cloudVaultKeyedHashHex,
  cloudVaultSha256Hex,
  initSync,
  type InitInput,
  type SyncInitInput,
} from "../vendor/openburnbar-domain-core-wasm/openburnbar_domain_core.js";

export type CloudVaultDomainCoreMode = "legacy" | "shadow" | "rust";

let initialized = false;
let initialization: Promise<void> | undefined;
let testMode: CloudVaultDomainCoreMode | undefined;
let requireCoreForTests = false;

function configuredMode(): CloudVaultDomainCoreMode {
  if (testMode) return testMode;
  const value = process.env.NEXT_PUBLIC_OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE;
  return value === "shadow" || value === "rust" ? value : "legacy";
}

export function cloudVaultDomainCoreMode(): CloudVaultDomainCoreMode {
  return configuredMode();
}

export function isCloudVaultDomainCoreInitialized(): boolean {
  return initialized;
}

async function ensureInitialized(input?: InitInput): Promise<void> {
  if (initialized) return;
  initialization ??= initDomainCore(input).then(() => {
    initialized = true;
  });
  await initialization;
}

function warn(operation: string, category: "native_unavailable" | "shadow_mismatch" | "rust_error"): void {
  console.warn(`domain_core.cloudvault.${category} operation=${operation} core=abi3`);
}

export async function applyCloudVaultDomainCore<T>(
  operation: string,
  legacy: () => T | Promise<T>,
  rust: () => T,
  equivalent: (legacyValue: T, rustValue: T) => boolean = Object.is,
): Promise<T> {
  const mode = configuredMode();
  if (mode === "legacy") return legacy();

  try {
    await ensureInitialized();
  } catch (error) {
    if (mode === "rust" || requireCoreForTests) throw error;
    warn(operation, "native_unavailable");
    return legacy();
  }

  if (mode === "rust") return rust();

  const legacyValue = await legacy();
  let rustValue: T;
  try {
    rustValue = rust();
  } catch {
    warn(operation, "rust_error");
    return legacyValue;
  }
  if (!equivalent(legacyValue, rustValue)) warn(operation, "shadow_mismatch");
  return legacyValue;
}

export function applyCloudVaultDomainCoreSync<T>(
  operation: string,
  legacy: () => T,
  rust: () => T,
  equivalent: (legacyValue: T, rustValue: T) => boolean = Object.is,
): T {
  const mode = configuredMode();
  if (mode === "legacy") return legacy();
  if (!initialized) {
    if (mode === "rust" || requireCoreForTests) {
      throw new Error("domain core Wasm is required but not initialized");
    }
    void ensureInitialized().catch(() => undefined);
    warn(operation, "native_unavailable");
    return legacy();
  }
  if (mode === "rust") return rust();
  const legacyValue = legacy();
  let rustValue: T;
  try {
    rustValue = rust();
  } catch {
    warn(operation, "rust_error");
    return legacyValue;
  }
  if (!equivalent(legacyValue, rustValue)) warn(operation, "shadow_mismatch");
  return legacyValue;
}

export const domainCoreCloudVault = {
  aadV2: cloudVaultAadV2,
  aesOpenCombined: cloudVaultAesGcmOpenCombined,
  aesSealCombined: cloudVaultAesGcmSealCombined,
  base64DecodeStrict: cloudVaultBase64DecodeStrict,
  base64Encode: cloudVaultBase64Encode,
  escrowOpen: cloudVaultEscrowOpen,
  escrowSeal: cloudVaultEscrowSeal,
  escrowSplitWire(wire: Uint8Array): {
    ephemeralPublicKey: Uint8Array;
    aesGcmCombined: Uint8Array;
  } {
    const parts = cloudVaultEscrowSplitWire(wire);
    try {
      return {
        ephemeralPublicKey: parts.ephemeralPublicKey.slice(),
        aesGcmCombined: parts.aesGcmCombined.slice(),
      };
    } finally {
      parts.free();
    }
  },
  sha256Hex: cloudVaultSha256Hex,
  keyedHashHex: cloudVaultKeyedHashHex,
  hashPurpose: CloudVaultHashPurpose,
};

export async function prepareCloudVaultDomainCore(): Promise<void> {
  await applyCloudVaultDomainCore("initialize", () => undefined, () => undefined);
}

export function initializeCloudVaultDomainCoreForTests(module: SyncInitInput): void {
  initSync({ module });
  initialized = true;
}

export function configureCloudVaultDomainCoreForTests(
  mode: CloudVaultDomainCoreMode | undefined,
  requireCore = false,
): void {
  testMode = mode;
  requireCoreForTests = requireCore;
}
