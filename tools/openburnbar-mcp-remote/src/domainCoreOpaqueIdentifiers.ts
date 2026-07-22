import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export type DomainCoreOpaqueIdentifierMode = "legacy" | "shadow" | "rust";

export interface DomainCoreOpaqueIdentifierModule {
  cloudVaultPensieveDedupHash(value: string, key: Uint8Array): string;
  cloudVaultPensieveProvenanceHash(value: string, key: Uint8Array): string;
  cloudVaultPensieveSlugHmac(value: string, key: Uint8Array): string;
  domainCoreAbiVersion(): number;
  domainCoreSourceFingerprint(): string;
  domainCoreVersion(): string;
}

export interface DomainCoreOpaqueIdentifierReceipt {
  schemaVersion: 1;
  coreVersion: string;
  abiVersion: number;
  sourceSha256: string;
  wasmSha256: string;
}

export interface DomainCoreOpaqueIdentifierLoadedPackageForTest {
  module: DomainCoreOpaqueIdentifierModule;
  receipt: DomainCoreOpaqueIdentifierReceipt;
  sourceFingerprint: string;
  wasmSha256: string;
}

export interface DomainCoreOpaqueIdentifierAdapter {
  pensieveDedupHash(value: string, vaultKey: Buffer, legacy: () => string): string;
  pensieveProvenanceHash(value: string, vaultKey: Buffer, legacy: () => string): string;
  pensieveSlugHmac(value: string, vaultKey: Buffer, legacy: () => string): string;
}

const DOMAIN_CORE_ABI_VERSION = 3;
const MODE_ENVIRONMENT_VARIABLE = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE";
const packageDirectory = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../vendor/openburnbar-domain-core-wasm",
);
const require = createRequire(import.meta.url);

function configuredMode(environment: NodeJS.ProcessEnv = process.env): DomainCoreOpaqueIdentifierMode {
  const value = environment[MODE_ENVIRONMENT_VARIABLE]?.trim().toLowerCase();
  if (value === "shadow" || value === "rust") {
    return value;
  }
  return "legacy";
}

function parseReceipt(value: unknown): DomainCoreOpaqueIdentifierReceipt {
  if (
    typeof value !== "object" || value === null ||
    (value as { schemaVersion?: unknown }).schemaVersion !== 1 ||
    typeof (value as { coreVersion?: unknown }).coreVersion !== "string" ||
    (value as { abiVersion?: unknown }).abiVersion !== DOMAIN_CORE_ABI_VERSION ||
    !isSha256((value as { sourceSha256?: unknown }).sourceSha256) ||
    !isSha256((value as { wasmSha256?: unknown }).wasmSha256)
  ) {
    throw new Error("OpenBurnBar domain-core package receipt is invalid");
  }
  return value as DomainCoreOpaqueIdentifierReceipt;
}

function isSha256(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
}

function verifyLoadedIdentity(loaded: DomainCoreOpaqueIdentifierLoadedPackageForTest): void {
  const { module, receipt, sourceFingerprint, wasmSha256 } = loaded;
  if (
    module.domainCoreAbiVersion() !== receipt.abiVersion ||
    module.domainCoreVersion() !== receipt.coreVersion ||
    module.domainCoreSourceFingerprint() !== receipt.sourceSha256 ||
    sourceFingerprint !== receipt.sourceSha256 ||
    wasmSha256 !== receipt.wasmSha256
  ) {
    throw new Error("OpenBurnBar domain-core opaque-identifier identity mismatch");
  }
}

function validateModule(candidate: Partial<DomainCoreOpaqueIdentifierModule>): DomainCoreOpaqueIdentifierModule {
  if (
    typeof candidate.cloudVaultPensieveDedupHash !== "function" ||
    typeof candidate.cloudVaultPensieveProvenanceHash !== "function" ||
    typeof candidate.cloudVaultPensieveSlugHmac !== "function" ||
    typeof candidate.domainCoreAbiVersion !== "function" ||
    typeof candidate.domainCoreSourceFingerprint !== "function" ||
    typeof candidate.domainCoreVersion !== "function"
  ) {
    throw new Error("OpenBurnBar domain-core opaque-identifier API is incomplete");
  }
  return candidate as DomainCoreOpaqueIdentifierModule;
}

function loadProductionPackage(): DomainCoreOpaqueIdentifierLoadedPackageForTest {
  const module = validateModule(require(
    "../vendor/openburnbar-domain-core-wasm/openburnbar_domain_core.js",
  ) as Partial<DomainCoreOpaqueIdentifierModule>);
  const receipt = parseReceipt(JSON.parse(readFileSync(
    resolve(packageDirectory, "openburnbar-domain-core-package-receipt.json"),
    "utf8",
  )) as unknown);
  const sourceFingerprint = readFileSync(
    resolve(packageDirectory, "openburnbar-domain-core-source.sha256"),
    "utf8",
  ).trim();
  const wasmSha256 = createHash("sha256").update(readFileSync(
    resolve(packageDirectory, "openburnbar_domain_core_bg.wasm"),
  )).digest("hex");
  return { module, receipt, sourceFingerprint, wasmSha256 };
}

function createAdapter(
  mode: () => DomainCoreOpaqueIdentifierMode,
  load: () => DomainCoreOpaqueIdentifierLoadedPackageForTest,
  warning: (message: string) => void,
): DomainCoreOpaqueIdentifierAdapter {
  let loadedModule: DomainCoreOpaqueIdentifierModule | undefined;

  const requireDomainCore = (): DomainCoreOpaqueIdentifierModule => {
    if (loadedModule) {
      return loadedModule;
    }
    const loaded = load();
    verifyLoadedIdentity(loaded);
    loadedModule = loaded.module;
    return loadedModule;
  };

  const warn = (operation: string, category: "native_error" | "shadow_mismatch"): void => {
    warning(`domain_core.cloudvault.${category} operation=${operation} core=abi3`);
  };

  const select = (
    operation: string,
    legacy: () => string,
    rust: (core: DomainCoreOpaqueIdentifierModule) => string,
  ): string => {
    const selectedMode = mode();
    if (selectedMode === "legacy") {
      return legacy();
    }
    if (selectedMode === "rust") {
      return rust(requireDomainCore());
    }

    const legacyValue = legacy();
    try {
      const rustValue = rust(requireDomainCore());
      if (legacyValue !== rustValue) {
        warn(operation, "shadow_mismatch");
      }
    } catch {
      warn(operation, "native_error");
    }
    return legacyValue;
  };

  return {
    pensieveDedupHash: (value, vaultKey, legacy) => select(
      "pensieve_dedup_hash",
      legacy,
      (core) => core.cloudVaultPensieveDedupHash(value, vaultKey),
    ),
    pensieveProvenanceHash: (value, vaultKey, legacy) => select(
      "pensieve_provenance_hash",
      legacy,
      (core) => core.cloudVaultPensieveProvenanceHash(value, vaultKey),
    ),
    pensieveSlugHmac: (value, vaultKey, legacy) => select(
      "pensieve_slug_hmac",
      legacy,
      (core) => core.cloudVaultPensieveSlugHmac(value, vaultKey),
    ),
  };
}

const productionAdapter = createAdapter(
  configuredMode,
  loadProductionPackage,
  (message) => console.warn(message),
);

export function pensieveDedupHash(value: string, vaultKey: Buffer, legacy: () => string): string {
  return productionAdapter.pensieveDedupHash(value, vaultKey, legacy);
}

export function pensieveSlugHmac(value: string, vaultKey: Buffer, legacy: () => string): string {
  return productionAdapter.pensieveSlugHmac(value, vaultKey, legacy);
}

export function pensieveProvenanceHash(value: string, vaultKey: Buffer, legacy: () => string): string {
  return productionAdapter.pensieveProvenanceHash(value, vaultKey, legacy);
}

export function createDomainCoreOpaqueIdentifierAdapterForTest(
  selectedMode: DomainCoreOpaqueIdentifierMode,
  loaded: DomainCoreOpaqueIdentifierLoadedPackageForTest,
  warning: (message: string) => void = () => undefined,
): DomainCoreOpaqueIdentifierAdapter {
  return createAdapter(() => selectedMode, () => loaded, warning);
}
