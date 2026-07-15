export function domainCoreVersion(): string;
export function cloudVaultEscrowSeal(plaintext: Uint8Array, ephemeral_public_key: Uint8Array, shared_secret: Uint8Array, nonce: Uint8Array): Uint8Array;
export function cloudVaultNormalizeRecoveryKey(recovery_key: string): string;
export function calculateTokenCostNanoUsd(rates: BigUint64Array, buckets: BigUint64Array, has_cache_creation_rate: boolean): bigint;
export function cloudVaultAesGcmOpenCombined(combined: Uint8Array, key: Uint8Array, aad: Uint8Array): Uint8Array;
export function isLegacyKimiWireEvent(provider: string, model: string): boolean;
export function cloudVaultEscrowWrappingKey(shared_secret: Uint8Array): Uint8Array;
export function cloudVaultEscrowSplitWire(wire: Uint8Array): CloudVaultEscrowWireParts;
export function cloudVaultBase64Encode(data: Uint8Array): string;
export function cloudVaultKeyedHashHex(data: Uint8Array, key: Uint8Array, purpose: CloudVaultHashPurpose): string;
export function cloudVaultRecoveryOpenVaultKey(combined: Uint8Array, recovery_key: string): Uint8Array;
export function cloudVaultAadV1(uid: string, collection: string, doc_id: string, field: string, schema_version: number, purpose?: string | null): string;
export function cloudVaultExpectedSessionBodyHash(data: Uint8Array, key: Uint8Array, body_hash_version: number): string;
export function cloudVaultSearch(operation: CloudVaultSearchOperation, text: string, vault_key: Uint8Array, limit: number): CloudVaultSearchResult;
export function legacyKimiWireModel(): string;
/**
 * Whole-document rewrap for browser/Tauri consumers. `request_json` is the
 * strict camelCase serialization of `CloudVaultDocumentRewrapRequest`; unknown
 * fields and malformed envelope variants are rejected by serde.
 */
export function cloudVaultRewrapDocumentJson(request_json: string, old_key: Uint8Array, new_key: Uint8Array, new_vault_key_id: string): string;
export function cloudVaultRecoveryWrapVaultKey(vault_key: Uint8Array, recovery_key: string, nonce: Uint8Array): CloudVaultRecoveryWrappedVaultKey;
export function cloudVaultAadV2(uid: string, collection: string, doc_id: string, field: string, schema_version: number, purpose?: string | null): string;
export function cloudVaultEscrowOpen(wire: Uint8Array, shared_secret: Uint8Array): Uint8Array;
export function cloudVaultValidateP256X963PublicKey(public_key: Uint8Array): void;
export function cloudVaultSha256Hex(data: Uint8Array): string;
export function domainCoreAbiVersion(): number;
export function domainCoreSourceFingerprint(): string;
export function cloudVaultSearchAnalyze(text: string): CloudVaultSearchAnalysis;
/**
 * Returns `[total_tokens, cost_nano_usd]`; the canonical model is exported separately.
 */
export function priceLegacyKimiWireEvent(input_tokens: bigint, output_tokens: bigint, cache_creation_tokens: bigint, cache_read_tokens: bigint): BigUint64Array;
export function cloudVaultAesGcmSealCombined(plaintext: Uint8Array, key: Uint8Array, nonce: Uint8Array, aad: Uint8Array): Uint8Array;
export function cloudVaultRecoveryVerificationHash(recovery_key: string): string;
export function cloudVaultRecoveryWrappingKey(recovery_key: string): Uint8Array;
export function cloudVaultEscrowAssembleWire(ephemeral_public_key: Uint8Array, aes_gcm_combined: Uint8Array): Uint8Array;
export function cloudVaultKeyId(key: Uint8Array): string;
export function cloudVaultBase64DecodeStrict(value: string): Uint8Array;
export enum CloudVaultHashPurpose {
  BlobIntegrity = 0,
  SessionBody = 1,
  SessionChunk = 2,
  ProjectMemoryContent = 3,
}
export enum CloudVaultSearchOperation {
  Token = 0,
  Index = 1,
  Query = 2,
  Semantic = 3,
}
export class CloudVaultEscrowWireParts {
  private constructor();
  free(): void;
  [Symbol.dispose](): void;
  readonly aesGcmCombined: Uint8Array;
  readonly ephemeralPublicKey: Uint8Array;
}
export class CloudVaultRecoveryWrappedVaultKey {
  private constructor();
  free(): void;
  [Symbol.dispose](): void;
  readonly verificationHash: string;
  readonly combined: Uint8Array;
}
export class CloudVaultSearchAnalysis {
  private constructor();
  free(): void;
  [Symbol.dispose](): void;
  normalizedTokenAt(index: number): string | undefined;
  semanticFeatureAt(index: number): string | undefined;
  exactPhraseTokenAt(index: number): string | undefined;
  readonly normalizedTokenCount: number;
  readonly semanticFeatureCount: number;
  readonly exactPhraseTokenCount: number;
}
export class CloudVaultSearchResult {
  private constructor();
  free(): void;
  [Symbol.dispose](): void;
  hashAt(index: number): string | undefined;
  readonly hashCount: number;
  readonly operation: CloudVaultSearchOperation;
}

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
  readonly memory: WebAssembly.Memory;
  readonly __wbg_cloudvaultescrowwireparts_free: (a: number, b: number) => void;
  readonly __wbg_cloudvaultsearchanalysis_free: (a: number, b: number) => void;
  readonly __wbg_cloudvaultsearchresult_free: (a: number, b: number) => void;
  readonly calculateTokenCostNanoUsd: (a: number, b: number, c: number, d: number, e: number, f: number) => void;
  readonly cloudVaultAadV1: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number, k: number, l: number) => void;
  readonly cloudVaultAadV2: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number, k: number, l: number) => void;
  readonly cloudVaultAesGcmOpenCombined: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => void;
  readonly cloudVaultAesGcmSealCombined: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number) => void;
  readonly cloudVaultBase64DecodeStrict: (a: number, b: number, c: number) => void;
  readonly cloudVaultBase64Encode: (a: number, b: number, c: number) => void;
  readonly cloudVaultEscrowAssembleWire: (a: number, b: number, c: number, d: number, e: number) => void;
  readonly cloudVaultEscrowOpen: (a: number, b: number, c: number, d: number, e: number) => void;
  readonly cloudVaultEscrowSeal: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number) => void;
  readonly cloudVaultEscrowSplitWire: (a: number, b: number, c: number) => void;
  readonly cloudVaultEscrowWrappingKey: (a: number, b: number, c: number) => void;
  readonly cloudVaultExpectedSessionBodyHash: (a: number, b: number, c: number, d: number, e: number, f: number) => void;
  readonly cloudVaultKeyId: (a: number, b: number, c: number) => void;
  readonly cloudVaultKeyedHashHex: (a: number, b: number, c: number, d: number, e: number, f: number) => void;
  readonly cloudVaultNormalizeRecoveryKey: (a: number, b: number, c: number) => void;
  readonly cloudVaultRecoveryOpenVaultKey: (a: number, b: number, c: number, d: number, e: number) => void;
  readonly cloudVaultRecoveryVerificationHash: (a: number, b: number, c: number) => void;
  readonly cloudVaultRecoveryWrapVaultKey: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => void;
  readonly cloudVaultRecoveryWrappingKey: (a: number, b: number, c: number) => void;
  readonly cloudVaultRewrapDocumentJson: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number) => void;
  readonly cloudVaultSearch: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => void;
  readonly cloudVaultSearchAnalyze: (a: number, b: number, c: number) => void;
  readonly cloudVaultSha256Hex: (a: number, b: number, c: number) => void;
  readonly cloudVaultValidateP256X963PublicKey: (a: number, b: number, c: number) => void;
  readonly cloudvaultescrowwireparts_aesGcmCombined: (a: number, b: number) => void;
  readonly cloudvaultescrowwireparts_ephemeralPublicKey: (a: number, b: number) => void;
  readonly cloudvaultrecoverywrappedvaultkey_verificationHash: (a: number, b: number) => void;
  readonly cloudvaultsearchanalysis_exactPhraseTokenAt: (a: number, b: number, c: number) => void;
  readonly cloudvaultsearchanalysis_exactPhraseTokenCount: (a: number) => number;
  readonly cloudvaultsearchanalysis_normalizedTokenAt: (a: number, b: number, c: number) => void;
  readonly cloudvaultsearchanalysis_normalizedTokenCount: (a: number) => number;
  readonly cloudvaultsearchanalysis_semanticFeatureAt: (a: number, b: number, c: number) => void;
  readonly cloudvaultsearchanalysis_semanticFeatureCount: (a: number) => number;
  readonly cloudvaultsearchresult_hashAt: (a: number, b: number, c: number) => void;
  readonly cloudvaultsearchresult_hashCount: (a: number) => number;
  readonly cloudvaultsearchresult_operation: (a: number) => number;
  readonly domainCoreAbiVersion: () => number;
  readonly domainCoreSourceFingerprint: (a: number) => void;
  readonly domainCoreVersion: (a: number) => void;
  readonly isLegacyKimiWireEvent: (a: number, b: number, c: number, d: number) => number;
  readonly legacyKimiWireModel: (a: number) => void;
  readonly priceLegacyKimiWireEvent: (a: number, b: bigint, c: bigint, d: bigint, e: bigint) => void;
  readonly __wbg_cloudvaultrecoverywrappedvaultkey_free: (a: number, b: number) => void;
  readonly cloudvaultrecoverywrappedvaultkey_combined: (a: number, b: number) => void;
  readonly __wbindgen_add_to_stack_pointer: (a: number) => number;
  readonly __wbindgen_export: (a: number, b: number, c: number) => void;
  readonly __wbindgen_export2: (a: number, b: number) => number;
  readonly __wbindgen_export3: (a: number, b: number, c: number, d: number) => number;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;
/**
* Instantiates the given `module`, which can either be bytes or
* a precompiled `WebAssembly.Module`.
*
* @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
*
* @returns {InitOutput}
*/
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
* If `module_or_path` is {RequestInfo} or {URL}, makes a request and
* for everything else, calls `WebAssembly.instantiate` directly.
*
* @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
*
* @returns {Promise<InitOutput>}
*/
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
