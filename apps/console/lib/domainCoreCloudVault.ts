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
  domainCoreVersion,
  initSync,
  type InitInput,
  type SyncInitInput,
} from "../vendor/openburnbar-domain-core-wasm/openburnbar_domain_core.js";
import { resolveDomainCoreWebMode } from "./domainCoreBuildProfile";
import { recordConsoleCloudVaultShadowComparison } from "./domainCoreShadowEvidence";

export type CloudVaultDomainCoreMode = "legacy" | "shadow" | "rust";

let initialized = false;
let initialization: Promise<void> | undefined;
let testMode: CloudVaultDomainCoreMode | undefined;
let requireCoreForTests = false;
let shadowCollector: ((comparison: CloudVaultShadowComparison) => void) | undefined;

export interface CloudVaultShadowComparison {
  domain: "cloudvault";
  slice: "foundation" | "aes" | "escrow";
  consumer: "console";
  operation: string;
  coreVersion: string;
  outcome: "match" | "mismatch";
  mismatchCategory: "result_mismatch" | "native_unavailable" | "native_error" | null;
  legacyMicros: number;
  rustMicros: number;
}

export function configureCloudVaultShadowCollector(
  collector: ((comparison: CloudVaultShadowComparison) => void) | undefined,
): void {
  shadowCollector = collector;
}

function configuredMode(): CloudVaultDomainCoreMode {
  if (testMode) return testMode;
  return resolveDomainCoreWebMode("cloudVault");
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

function warn(
  operation: string,
  category: "native_unavailable" | "shadow_mismatch" | "rust_error",
): void {
  console.warn(
    `domain_core.cloudvault.${category} operation=${operation} core=abi3`,
  );
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

  const legacyStarted = performance.now();
  const legacyValue = await legacy();
  const legacyMicros = elapsedMicros(legacyStarted);
  let rustValue: T;
  const rustStarted = performance.now();
  try {
    rustValue = rust();
  } catch {
    warn(operation, "rust_error");
    collect(operation, false, "native_error", legacyMicros, elapsedMicros(rustStarted));
    return legacyValue;
  }
  const rustMicros = elapsedMicros(rustStarted);
  const matches = equivalent(legacyValue, rustValue);
  if (!matches) warn(operation, "shadow_mismatch");
  collect(operation, matches, matches ? null : "result_mismatch", legacyMicros, rustMicros);
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
  const legacyStarted = performance.now();
  const legacyValue = legacy();
  const legacyMicros = elapsedMicros(legacyStarted);
  let rustValue: T;
  const rustStarted = performance.now();
  try {
    rustValue = rust();
  } catch {
    warn(operation, "rust_error");
    collect(operation, false, "native_error", legacyMicros, elapsedMicros(rustStarted));
    return legacyValue;
  }
  const rustMicros = elapsedMicros(rustStarted);
  const matches = equivalent(legacyValue, rustValue);
  if (!matches) warn(operation, "shadow_mismatch");
  collect(operation, matches, matches ? null : "result_mismatch", legacyMicros, rustMicros);
  return legacyValue;
}

function elapsedMicros(startedMillis: number): number {
  return Math.min(600_000_000, Math.max(0, Math.round((performance.now() - startedMillis) * 1_000)));
}

function sliceFor(operation: string): CloudVaultShadowComparison["slice"] {
  if (operation.includes("escrow")) return "escrow";
  if (operation.includes("aes") || operation.includes("seal") || operation.includes("open")) return "aes";
  return "foundation";
}

function collect(
  operation: string,
  matches: boolean,
  mismatchCategory: CloudVaultShadowComparison["mismatchCategory"],
  legacyMicros: number,
  rustMicros: number,
): void {
  const comparison: CloudVaultShadowComparison = {
    domain: "cloudvault",
    slice: sliceFor(operation),
    consumer: "console",
    operation,
    coreVersion: domainCoreVersion(),
    outcome: matches ? "match" : "mismatch",
    mismatchCategory,
    legacyMicros,
    rustMicros,
  };
  try {
    (shadowCollector ?? recordConsoleCloudVaultShadowComparison)(comparison);
  } catch {
    warn(operation, "rust_error");
  }
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
  await applyCloudVaultDomainCore(
    "initialize",
    () => undefined,
    () => undefined,
  );
}

export function initializeCloudVaultDomainCoreForTests(
  module: SyncInitInput,
): void {
  initSync({ module });
  initialized = true;
}

export function configureCloudVaultDomainCoreForTests(
  mode: CloudVaultDomainCoreMode | undefined,
  requireCore = false,
): void {
  testMode = mode;
  requireCoreForTests = requireCore;
  if (mode === undefined) shadowCollector = undefined;
}
