/* tslint:disable */
/* eslint-disable */
export function cloudVaultKeyedHashHex(data: Uint8Array, key: Uint8Array, purpose: CloudVaultHashPurpose): string;
export function cloudVaultSha256Hex(data: Uint8Array): string;
export function cloudVaultAadV2(uid: string, collection: string, doc_id: string, field: string, schema_version: number, purpose?: string | null): string;
export function cloudVaultKeyId(key: Uint8Array): string;
export function cloudVaultAadV1(uid: string, collection: string, doc_id: string, field: string, schema_version: number, purpose?: string | null): string;
export function cloudVaultExpectedSessionBodyHash(data: Uint8Array, key: Uint8Array, body_hash_version: number): string;
export enum CloudVaultHashPurpose {
  BlobIntegrity = 0,
  SessionBody = 1,
  SessionChunk = 2,
  ProjectMemoryContent = 3,
}

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
  readonly memory: WebAssembly.Memory;
  readonly cloudVaultAadV1: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number, k: number, l: number) => void;
  readonly cloudVaultAadV2: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number, k: number, l: number) => void;
  readonly cloudVaultExpectedSessionBodyHash: (a: number, b: number, c: number, d: number, e: number, f: number) => void;
  readonly cloudVaultKeyId: (a: number, b: number, c: number) => void;
  readonly cloudVaultKeyedHashHex: (a: number, b: number, c: number, d: number, e: number, f: number) => void;
  readonly cloudVaultSha256Hex: (a: number, b: number, c: number) => void;
  readonly __wbindgen_add_to_stack_pointer: (a: number) => number;
  readonly __wbindgen_export: (a: number, b: number) => number;
  readonly __wbindgen_export2: (a: number, b: number, c: number) => void;
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
