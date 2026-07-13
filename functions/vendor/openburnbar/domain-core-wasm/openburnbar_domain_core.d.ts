export function domainCoreVersion(): string;
export function cloudVaultAadV1(uid: string, collection: string, doc_id: string, field: string, schema_version: number, purpose?: string | null): string;
export function cloudVaultKeyId(key: Uint8Array): string;
export function legacyKimiWireModel(): string;
export function cloudVaultSha256Hex(data: Uint8Array): string;
/**
 * Returns `[total_tokens, cost_nano_usd]`; the canonical model is exported separately.
 */
export function priceLegacyKimiWireEvent(input_tokens: bigint, output_tokens: bigint, cache_creation_tokens: bigint, cache_read_tokens: bigint): BigUint64Array;
export function isLegacyKimiWireEvent(provider: string, model: string): boolean;
export function cloudVaultExpectedSessionBodyHash(data: Uint8Array, key: Uint8Array, body_hash_version: number): string;
export function cloudVaultKeyedHashHex(data: Uint8Array, key: Uint8Array, purpose: CloudVaultHashPurpose): string;
export function cloudVaultAadV2(uid: string, collection: string, doc_id: string, field: string, schema_version: number, purpose?: string | null): string;
export function calculateTokenCostNanoUsd(rates: BigUint64Array, buckets: BigUint64Array, has_cache_creation_rate: boolean): bigint;
export enum CloudVaultHashPurpose {
  BlobIntegrity = 0,
  SessionBody = 1,
  SessionChunk = 2,
  ProjectMemoryContent = 3,
}
