import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export type DomainCoreCloudVaultMode = "legacy" | "shadow" | "rust";
export type DomainCoreCloudVaultSearchOperation = 0 | 1 | 2 | 3;

export interface DomainCoreCloudVaultSearchResult {
  readonly hashCount: number;
  hashAt(index: number): string | undefined;
  free(): void;
}

export interface DomainCoreCloudVaultModule {
  cloudVaultAadV2(
    uid: string,
    collection: string,
    docID: string,
    field: string,
    schemaVersion: number,
    purpose?: string | null,
  ): string;
  cloudVaultAesGcmOpenCombined(
    combined: Uint8Array,
    key: Uint8Array,
    aad: Uint8Array,
  ): Uint8Array;
  cloudVaultAesGcmSealCombined(
    plaintext: Uint8Array,
    key: Uint8Array,
    nonce: Uint8Array,
    aad: Uint8Array,
  ): Uint8Array;
  cloudVaultSearch(
    operation: DomainCoreCloudVaultSearchOperation,
    text: string,
    vaultKey: Uint8Array,
    limit: number,
  ): DomainCoreCloudVaultSearchResult;
  pensieveVectorCloak(vector: Float64Array, vaultKey: Uint8Array, modelVersion: string): Float64Array;
  pensieveDeterministicEmbed(text: string, dimensions: number, isQuery: boolean): Float64Array;
  pensieveDeterministicEmbedAndCloak(
    text: string,
    dimensions: number,
    isQuery: boolean,
    vaultKey: Uint8Array,
    modelVersion: string,
  ): Float64Array;
  domainCoreAbiVersion(): number;
  domainCoreSourceFingerprint(): string;
  domainCoreVersion(): string;
}

export interface DomainCoreCloudVaultReceipt {
  schemaVersion: 1;
  coreVersion: string;
  abiVersion: number;
  sourceSha256: string;
  wasmSha256: string;
}

export interface DomainCoreCloudVaultLoadedPackageForTest {
  module: DomainCoreCloudVaultModule;
  receipt: DomainCoreCloudVaultReceipt;
  sourceFingerprint: string;
  wasmSha256: string;
}

export interface DomainCoreCloudVaultAdapter {
  aadV2(
    uid: string,
    collection: string,
    docID: string,
    field: string,
    schemaVersion: number,
    purpose: string,
    legacy: () => string,
  ): string;
  aesGcmOpenCombined(
    combined: Uint8Array,
    key: Uint8Array,
    aad: Uint8Array,
    legacy: () => Uint8Array,
  ): Uint8Array;
  aesGcmSealCombined(
    plaintext: Uint8Array,
    key: Uint8Array,
    nonce: Uint8Array,
    aad: Uint8Array,
    legacy: () => Uint8Array,
  ): Uint8Array;
  search(
    operation: DomainCoreCloudVaultSearchOperation,
    text: string,
    vaultKey: Uint8Array,
    limit: number,
    legacy: () => string[],
  ): string[];
  vectorCloak(
    vector: ArrayLike<number>,
    vaultKey: Uint8Array,
    modelVersion: string,
    legacy: () => Float64Array,
  ): Float64Array;
  deterministicEmbed(
    text: string,
    dimensions: number,
    isQuery: boolean,
    legacy: () => number[],
  ): number[];
  deterministicEmbedAndCloak(
    text: string,
    dimensions: number,
    isQuery: boolean,
    vaultKey: Uint8Array,
    modelVersion: string,
    legacy: () => number[],
  ): number[];
}

const DOMAIN_CORE_ABI_VERSION = 3;
const MODE_ENVIRONMENT_VARIABLE = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE";
const SEARCH_MODE_ENVIRONMENT_VARIABLE = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE";
const packageDirectory = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../vendor/openburnbar-domain-core-wasm",
);
const require = createRequire(import.meta.url);

function configuredMode(environment: NodeJS.ProcessEnv = process.env): DomainCoreCloudVaultMode {
  const value = environment[MODE_ENVIRONMENT_VARIABLE]?.trim().toLowerCase();
  if (value === "shadow" || value === "rust") {
    return value;
  }
  return "legacy";
}

function configuredSearchMode(environment: NodeJS.ProcessEnv = process.env): DomainCoreCloudVaultMode {
  const value = environment[SEARCH_MODE_ENVIRONMENT_VARIABLE]?.trim().toLowerCase();
  if (value === "shadow" || value === "rust") {
    return value;
  }
  return "legacy";
}

function isSha256(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
}

function parseReceipt(value: unknown): DomainCoreCloudVaultReceipt {
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
  return value as DomainCoreCloudVaultReceipt;
}

function validateModule(candidate: Partial<DomainCoreCloudVaultModule>): DomainCoreCloudVaultModule {
  if (
    typeof candidate.cloudVaultAadV2 !== "function" ||
    typeof candidate.cloudVaultAesGcmOpenCombined !== "function" ||
    typeof candidate.cloudVaultAesGcmSealCombined !== "function" ||
    typeof candidate.cloudVaultSearch !== "function" ||
    typeof candidate.pensieveVectorCloak !== "function" ||
    typeof candidate.pensieveDeterministicEmbed !== "function" ||
    typeof candidate.pensieveDeterministicEmbedAndCloak !== "function" ||
    typeof candidate.domainCoreAbiVersion !== "function" ||
    typeof candidate.domainCoreSourceFingerprint !== "function" ||
    typeof candidate.domainCoreVersion !== "function"
  ) {
    throw new Error("OpenBurnBar domain-core CloudVault API is incomplete");
  }
  return candidate as DomainCoreCloudVaultModule;
}

function verifyLoadedIdentity(loaded: DomainCoreCloudVaultLoadedPackageForTest): void {
  const { module, receipt, sourceFingerprint, wasmSha256 } = loaded;
  if (
    module.domainCoreAbiVersion() !== receipt.abiVersion ||
    module.domainCoreVersion() !== receipt.coreVersion ||
    module.domainCoreSourceFingerprint() !== receipt.sourceSha256 ||
    sourceFingerprint !== receipt.sourceSha256 ||
    wasmSha256 !== receipt.wasmSha256
  ) {
    throw new Error("OpenBurnBar domain-core CloudVault identity mismatch");
  }
}

function loadProductionPackage(): DomainCoreCloudVaultLoadedPackageForTest {
  const module = validateModule(require(
    "../vendor/openburnbar-domain-core-wasm/openburnbar_domain_core.js",
  ) as Partial<DomainCoreCloudVaultModule>);
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
  mode: () => DomainCoreCloudVaultMode,
  searchMode: () => DomainCoreCloudVaultMode,
  load: () => DomainCoreCloudVaultLoadedPackageForTest,
  warning: (message: string) => void,
): DomainCoreCloudVaultAdapter {
  let loadedModule: DomainCoreCloudVaultModule | undefined;

  const requireDomainCore = (): DomainCoreCloudVaultModule => {
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

  const select = <T>(
    selectedMode: () => DomainCoreCloudVaultMode,
    operation: string,
    legacy: () => T,
    rust: (core: DomainCoreCloudVaultModule) => T,
    equal: (left: T, right: T) => boolean,
  ): T => {
    const authority = selectedMode();
    if (authority === "legacy") {
      return legacy();
    }
    if (authority === "rust") {
      return rust(requireDomainCore());
    }

    const legacyValue = legacy();
    try {
      const rustValue = rust(requireDomainCore());
      if (!equal(legacyValue, rustValue)) {
        warn(operation, "shadow_mismatch");
      }
    } catch {
      warn(operation, "native_error");
    }
    return legacyValue;
  };

  const bytesEqual = (left: Uint8Array, right: Uint8Array): boolean =>
    Buffer.from(left).equals(Buffer.from(right));
  const stringsEqual = (left: string[], right: string[]): boolean =>
    left.length === right.length && left.every((value, index) => value === right[index]);

  return {
    aadV2: (uid, collection, docID, field, schemaVersion, purpose, legacy) => select(
      mode,
      "aad_v2",
      legacy,
      (core) => core.cloudVaultAadV2(uid, collection, docID, field, schemaVersion, purpose),
      (left, right) => left === right,
    ),
    aesGcmOpenCombined: (combined, key, aad, legacy) => select(
      mode,
      "aes_gcm_open_combined",
      legacy,
      (core) => core.cloudVaultAesGcmOpenCombined(combined, key, aad),
      bytesEqual,
    ),
    aesGcmSealCombined: (plaintext, key, nonce, aad, legacy) => select(
      mode,
      "aes_gcm_seal_combined",
      legacy,
      (core) => core.cloudVaultAesGcmSealCombined(plaintext, key, nonce, aad),
      bytesEqual,
    ),
    search: (operation, text, vaultKey, limit, legacy) => select(
      searchMode,
      operation === 3 ? "search_semantic" : "search_token",
      legacy,
      (core) => {
        const result = core.cloudVaultSearch(operation, text, vaultKey, limit);
        try {
          return Array.from({ length: result.hashCount }, (_, index) => {
            const hash = result.hashAt(index);
            if (hash === undefined) {
              throw new Error("OpenBurnBar domain-core CloudVault search result is incomplete");
            }
            return hash;
          });
        } finally {
          result.free();
        }
      },
      stringsEqual,
    ),
    vectorCloak: (vector, vaultKey, modelVersion, legacy) => select(
      mode,
      "pensieve_vector_cloak",
      legacy,
      (core) => core.pensieveVectorCloak(Float64Array.from(vector), vaultKey, modelVersion),
      (left, right) => left.length === right.length && left.every(
        (value, index) => Math.abs(value - right[index]) < 1e-12,
      ),
    ),
    deterministicEmbed: (text, dimensions, isQuery, legacy) => select(
      mode,
      "pensieve_deterministic_embed",
      legacy,
      (core) => Array.from(core.pensieveDeterministicEmbed(text, dimensions, isQuery)),
      (left, right) => left.length === right.length && left.every((value, index) => value === right[index]),
    ),
    deterministicEmbedAndCloak: (text, dimensions, isQuery, vaultKey, modelVersion, legacy) => select(
      mode,
      "pensieve_deterministic_embed_and_cloak",
      legacy,
      (core) => Array.from(core.pensieveDeterministicEmbedAndCloak(
        text,
        dimensions,
        isQuery,
        vaultKey,
        modelVersion,
      )),
      (left, right) => left.length === right.length && left.every(
        (value, index) => Math.abs(value - right[index]) < 1e-12,
      ),
    ),
  };
}

const productionAdapter = createAdapter(
  configuredMode,
  configuredSearchMode,
  loadProductionPackage,
  (message) => console.warn(message),
);

export function domainCoreCloudVaultAADContext(
  uid: string,
  collection: string,
  docID: string,
  field: string,
  schemaVersion: number,
  purpose: string,
  legacy: () => string,
): string {
  return productionAdapter.aadV2(uid, collection, docID, field, schemaVersion, purpose, legacy);
}

export function domainCoreAesGcmSealCombined(
  plaintext: Uint8Array,
  key: Uint8Array,
  nonce: Uint8Array,
  aad: Uint8Array,
  legacy: () => Uint8Array,
): Uint8Array {
  return productionAdapter.aesGcmSealCombined(plaintext, key, nonce, aad, legacy);
}

export function domainCoreAesGcmOpenCombined(
  combined: Uint8Array,
  key: Uint8Array,
  aad: Uint8Array,
  legacy: () => Uint8Array,
): Uint8Array {
  return productionAdapter.aesGcmOpenCombined(combined, key, aad, legacy);
}

export function domainCoreCloudVaultSearch(
  operation: DomainCoreCloudVaultSearchOperation,
  text: string,
  vaultKey: Uint8Array,
  limit: number,
  legacy: () => string[],
): string[] {
  return productionAdapter.search(operation, text, vaultKey, limit, legacy);
}

export function domainCorePensieveVectorCloak(
  vector: ArrayLike<number>,
  vaultKey: Uint8Array,
  modelVersion: string,
  legacy: () => Float64Array,
): Float64Array {
  return productionAdapter.vectorCloak(vector, vaultKey, modelVersion, legacy);
}

export function domainCorePensieveDeterministicEmbed(
  text: string,
  dimensions: number,
  isQuery: boolean,
  legacy: () => number[],
): number[] {
  return productionAdapter.deterministicEmbed(text, dimensions, isQuery, legacy);
}

export function domainCorePensieveDeterministicEmbedAndCloak(
  text: string,
  dimensions: number,
  isQuery: boolean,
  vaultKey: Uint8Array,
  modelVersion: string,
  legacy: () => number[],
): number[] {
  return productionAdapter.deterministicEmbedAndCloak(
    text, dimensions, isQuery, vaultKey, modelVersion, legacy,
  );
}

export function createDomainCoreCloudVaultAdapterForTest(
  selectedMode: DomainCoreCloudVaultMode,
  selectedSearchMode: DomainCoreCloudVaultMode,
  loaded: DomainCoreCloudVaultLoadedPackageForTest,
  warning: (message: string) => void = () => undefined,
): DomainCoreCloudVaultAdapter {
  return createAdapter(() => selectedMode, () => selectedSearchMode, () => loaded, warning);
}
