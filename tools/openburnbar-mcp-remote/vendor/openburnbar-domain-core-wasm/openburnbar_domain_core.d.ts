export function cloudVaultPensieveProvenanceHash(value: string, key: Uint8Array): string;
export function cloudVaultRecoveryWrapVaultKey(vault_key: Uint8Array, recovery_key: string, nonce: Uint8Array): CloudVaultRecoveryWrappedVaultKey;
export function cloudVaultEscrowSplitWire(wire: Uint8Array): CloudVaultEscrowWireParts;
export function cloudVaultExpectedSessionBodyHash(data: Uint8Array, key: Uint8Array, body_hash_version: number): string;
export function cloudVaultBase64Encode(data: Uint8Array): string;
export function cloudVaultAadV2(uid: string, collection: string, doc_id: string, field: string, schema_version: number, purpose?: string | null): string;
export function cloudVaultEscrowAssembleWire(ephemeral_public_key: Uint8Array, aes_gcm_combined: Uint8Array): Uint8Array;
/**
 * Returns `[total_tokens, cost_nano_usd]`; the canonical model is exported separately.
 */
export function priceLegacyKimiWireEvent(input_tokens: bigint, output_tokens: bigint, cache_creation_tokens: bigint, cache_read_tokens: bigint): BigUint64Array;
export function cloudVaultRecoveryVerificationHash(recovery_key: string): string;
export function cloudVaultPensieveSlugHmac(slug: string, key: Uint8Array): string;
export function cloudVaultNormalizeRecoveryKey(recovery_key: string): string;
export function cloudVaultValidateP256X963PublicKey(public_key: Uint8Array): void;
export function cloudVaultRecoveryWrappingKey(recovery_key: string): Uint8Array;
export function cloudVaultBase64DecodeStrict(value: string): Uint8Array;
export function cloudVaultPensieveDedupHash(plaintext: string, key: Uint8Array): string;
export function cloudVaultSearch(operation: CloudVaultSearchOperation, text: string, vault_key: Uint8Array, limit: number): CloudVaultSearchResult;
export function legacyKimiWireModel(): string;
export function cloudVaultEscrowWrappingKey(shared_secret: Uint8Array): Uint8Array;
export function cloudVaultAadV1(uid: string, collection: string, doc_id: string, field: string, schema_version: number, purpose?: string | null): string;
export function cloudVaultEscrowOpen(wire: Uint8Array, shared_secret: Uint8Array): Uint8Array;
export function cloudVaultKeyId(key: Uint8Array): string;
export function domainCoreVersion(): string;
export function cloudVaultEscrowSeal(plaintext: Uint8Array, ephemeral_public_key: Uint8Array, shared_secret: Uint8Array, nonce: Uint8Array): Uint8Array;
export function cloudVaultKeyedHashHex(data: Uint8Array, key: Uint8Array, purpose: CloudVaultHashPurpose): string;
export function cloudVaultProjectMemoryDocId(slug: string, key: Uint8Array): string;
export function cloudVaultSearchAnalyze(text: string): CloudVaultSearchAnalysis;
export function cloudVaultAesGcmOpenCombined(combined: Uint8Array, key: Uint8Array, aad: Uint8Array): Uint8Array;
export function isLegacyKimiWireEvent(provider: string, model: string): boolean;
export function cloudVaultAesGcmSealCombined(plaintext: Uint8Array, key: Uint8Array, nonce: Uint8Array, aad: Uint8Array): Uint8Array;
export function domainCoreAbiVersion(): number;
export function cloudVaultSha256Hex(data: Uint8Array): string;
export function domainCoreSourceFingerprint(): string;
export function cloudVaultSubscriptionDocId(agent_uri: string, topic_id: string, key: Uint8Array): string;
export function calculateTokenCostNanoUsd(rates: BigUint64Array, buckets: BigUint64Array, has_cache_creation_rate: boolean): bigint;
export function cloudVaultRecoveryOpenVaultKey(combined: Uint8Array, recovery_key: string): Uint8Array;
/**
 * Whole-document rewrap for browser/Tauri consumers. `request_json` is the
 * strict camelCase serialization of `CloudVaultDocumentRewrapRequest`; unknown
 * fields and malformed envelope variants are rejected by serde.
 */
export function cloudVaultRewrapDocumentJson(request_json: string, old_key: Uint8Array, new_key: Uint8Array, new_vault_key_id: string): string;
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
