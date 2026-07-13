export function domainCoreVersion(): string;
export function cloudVaultAadV1(uid: string, collection: string, doc_id: string, field: string, schema_version: number, purpose?: string | null): string;
export function cloudVaultKeyId(key: Uint8Array): string;
export function legacyKimiWireModel(): string;
export function cloudVaultSha256Hex(data: Uint8Array): string;
/**
 * Returns `[total_tokens, cost_usd]`; the canonical model is exported separately.
 */
export function priceLegacyKimiWireEvent(input_tokens: number, output_tokens: number, cache_creation_tokens: number, cache_read_tokens: number): Float64Array;
export function isLegacyKimiWireEvent(provider: string, model: string): boolean;
export function cloudVaultExpectedSessionBodyHash(data: Uint8Array, key: Uint8Array, body_hash_version: number): string;
export function cloudVaultKeyedHashHex(data: Uint8Array, key: Uint8Array, purpose: CloudVaultHashPurpose): string;
export function cloudVaultAadV2(uid: string, collection: string, doc_id: string, field: string, schema_version: number, purpose?: string | null): string;
export function calculateTokenCost(rates: Float64Array, buckets: Float64Array): number;
export enum CloudVaultHashPurpose {
  BlobIntegrity = 0,
  SessionBody = 1,
  SessionChunk = 2,
  ProjectMemoryContent = 3,
}
