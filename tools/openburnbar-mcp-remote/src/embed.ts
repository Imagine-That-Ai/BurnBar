/**
 * Pensieve on-device embedding + vault-key vector cloaking.
 *
 * This module is the client-side half of the Pensieve E2EE semantic memory: it
 * turns text into a 384-dim embedding and then applies a per-user, vault-key
 * derived ORTHONORMAL transform Q ("cloaking") to that vector before it ever
 * leaves the device.
 *
 * What the cloak PROVABLY does (claim only these — see
 * docs/pensieve-leakage-analysis.md):
 *
 *   - Hides the public-model (bge) basis. Stored vectors are no longer in the
 *     raw bge coordinate frame, so off-the-shelf embedding-inversion models
 *     (which expect raw bge-space inputs) cannot be applied DIRECTLY to the
 *     stored vectors. This raises the bar; it is NOT a proof of
 *     non-invertibility.
 *   - Per-user distinct stored bytes (PARTIAL cross-tenant resistance). Q is
 *     per-user, so the SAME plaintext under two members' keys yields DIFFERENT
 *     stored vectors (relative L2 distance ≈ 0.74), defeating an exact-match
 *     cross-tenant join. NOT full unlinkability: with only CLOAK_REFLECTIONS=24
 *     in 384-dim, cross-tenant cosine ≈ 0.77, so a server can still correlate
 *     the same plaintext across tenants by SIMILARITY. Full decorrelation needs
 *     ~dim reflections (a versioned re-cloak).
 *
 * What the cloak DOES NOT do (accepted, documented leakage):
 *
 *   - It does NOT hide relative geometry. Because Q is orthonormal,
 *     <Qx, Qy> = <x, y> and ||Qx|| = ||x||, so cosine similarity is preserved
 *     EXACTLY. The server can therefore compute the full pairwise cosine matrix,
 *     k-NN graph, clusters, and similarity-dedup over the cloaked vectors WITHOUT
 *     the key — within one user AND (per the caveat above) across users. (This
 *     identity is also the feature: it lets server-side findNearest recall work
 *     over cloaked vectors.)
 *
 * Q is built deterministically from the device vault key (same HKDF-from-vault-
 * key pattern as resume.ts) and the embedding model version, so re-embedding is
 * reproducible and a model bump triggers a clean re-cloak migration. It is a
 * product of Householder reflections (each Hᵢ = I − 2·vᵢvᵢᵀ with ||vᵢ|| = 1):
 * exactly orthogonal, mixes every coordinate (unlike a signed permutation that
 * only shuffles/flips values), and O(count·dim) to apply. The proven properties
 * above are asserted in cloakLeakage.test.ts.
 *
 * The embedding model itself (bge-small-en-v1.5 via Transformers.js/ONNX) is
 * loaded lazily from the user's environment so the published shim stays
 * zero-dependency; Pensieve users opt into the embedding runtime explicitly.
 */

import { createHash, createHmac } from "node:crypto";
import { readVaultKey } from "./vaultStore.js";

/** Pinned production embedding model. Stored on every vector; index- and query-time must match. */
export const EMBEDDING_MODEL_VERSION = "bge-small-en-v1.5";
export const EMBEDDING_DIM = 384;

/** bge retrieval asymmetry: queries get an instruction prefix, documents do not. */
export const BGE_QUERY_INSTRUCTION = "Represent this sentence for searching relevant passages: ";

const CLOAK_SALT = Buffer.from("OpenBurnBar-Pensieve-Cloak-Salt-v1");
/**
 * Number of Householder reflections composed into the cloak. 24 > log2(384) for
 * thorough WITHIN-vector coordinate mixing (basis hiding; defeats signed-
 * permutation structure). NOTE: this is NOT sized for cross-user decorrelation —
 * two per-user Qs leave cross-tenant cosine ≈ 0.77 here; full unlinkability would
 * need ~dim reflections. See docs/pensieve-leakage-analysis.md. Changing this
 * value re-cloaks every stored vector and must stay in lockstep with
 * PensieveVectorCloak.swift, so treat it as a versioned migration.
 */
const CLOAK_REFLECTIONS = 24;

// -- HKDF (identical construction to resume.ts, kept local to avoid cross-module coupling) --

function hkdfSha256(input: Buffer, salt: Buffer, info: Buffer, length: number): Buffer {
  const prk = createHmac("sha256", salt.length > 0 ? salt : Buffer.alloc(32)).update(input).digest();
  const chunks: Buffer[] = [];
  let previous = Buffer.alloc(0);
  let written = 0;
  let counter = 1;
  while (written < length) {
    previous = createHmac("sha256", prk).update(previous).update(info).update(Buffer.from([counter])).digest();
    chunks.push(previous);
    written += previous.length;
    counter += 1;
  }
  return Buffer.concat(chunks).subarray(0, length);
}

// -- Vault key access ---------------------------------------------------------

export class VaultKeyUnavailableError extends Error {
  constructor() {
    super("Pensieve vault key unavailable — run `openburnbar mcp login` to link your device vault key.");
    this.name = "VaultKeyUnavailableError";
  }
}

/** Returns the 32-byte vault key, or undefined when absent (callers may fail open). */
export function loadVaultKeyBytes(): Buffer | undefined {
  const raw = readVaultKey();
  if (!raw) return undefined;
  const key = Buffer.from(raw, "base64");
  return key.length === 32 ? key : undefined;
}

function requireVaultKeyBytes(): Buffer {
  const key = loadVaultKeyBytes();
  if (!key) throw new VaultKeyUnavailableError();
  return key;
}

// -- Cloaking (vault-key orthonormal transform) -------------------------------

/** Deterministic uniform-(0,1) float stream read 4 bytes at a time from an HKDF keystream. */
function makeUniformStream(bytes: Buffer): () => number {
  let offset = 0;
  return () => {
    if (offset + 4 > bytes.length) offset = 0; // defensive; we always derive enough
    const u = bytes.readUInt32BE(offset);
    offset += 4;
    // Map to (0,1): keep strictly positive so log() in Box-Muller is finite.
    return (u + 0.5) / 4294967296;
  };
}

/** One standard-normal sample via Box-Muller from two uniforms. */
function nextGaussian(uniform: () => number): number {
  const u1 = uniform();
  const u2 = uniform();
  return Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
}

interface CloakReflections {
  dim: number;
  vectors: Float64Array[];
}

const reflectionCache = new Map<string, CloakReflections>();

function cacheKey(vaultKey: Buffer, modelVersion: string, dim: number): string {
  // Hash the key (never use raw key bytes as a map key) + transform parameters.
  const keyHash = createHash("sha256").update(vaultKey).digest("hex").slice(0, 32);
  return `${keyHash}:${modelVersion}:${dim}:${CLOAK_REFLECTIONS}`;
}

function deriveReflections(vaultKey: Buffer, modelVersion: string, dim: number): CloakReflections {
  const key = cacheKey(vaultKey, modelVersion, dim);
  const cached = reflectionCache.get(key);
  if (cached) return cached;

  const info = Buffer.from(`OpenBurnBar-Pensieve-Cloak-${modelVersion}-v1`);
  // 2 uniforms per gaussian, 4 bytes per uniform, CLOAK_REFLECTIONS * dim gaussians, + slack.
  const byteLen = CLOAK_REFLECTIONS * dim * 2 * 4 + 64;
  const keystream = hkdfSha256(vaultKey, CLOAK_SALT, info, byteLen);
  const uniform = makeUniformStream(keystream);

  const vectors: Float64Array[] = [];
  for (let r = 0; r < CLOAK_REFLECTIONS; r += 1) {
    const v = new Float64Array(dim);
    let normSq = 0;
    for (let i = 0; i < dim; i += 1) {
      const g = nextGaussian(uniform);
      v[i] = g;
      normSq += g * g;
    }
    const norm = Math.sqrt(normSq);
    if (norm === 0) {
      v[0] = 1; // degenerate guard; keeps Hᵢ orthogonal
    } else {
      for (let i = 0; i < dim; i += 1) v[i] /= norm;
    }
    vectors.push(v);
  }
  const result: CloakReflections = { dim, vectors };
  reflectionCache.set(key, result);
  return result;
}

/**
 * Apply the per-user orthonormal cloak to a single embedding.
 * Pass the same `modelVersion` at index time and query time. The returned vector
 * is a fresh Float64Array; the input is not mutated.
 */
export function cloakVector(
  vector: ArrayLike<number>,
  options: { vaultKey?: Buffer; modelVersion?: string } = {},
): Float64Array {
  const vaultKey = options.vaultKey ?? requireVaultKeyBytes();
  const modelVersion = options.modelVersion ?? EMBEDDING_MODEL_VERSION;
  const dim = vector.length;
  const { vectors } = deriveReflections(vaultKey, modelVersion, dim);

  const x = Float64Array.from(vector as ArrayLike<number>);
  for (const v of vectors) {
    let dot = 0;
    for (let i = 0; i < dim; i += 1) dot += v[i] * x[i];
    const c = 2 * dot;
    for (let i = 0; i < dim; i += 1) x[i] -= c * v[i];
  }
  return x;
}

// -- Vector math helpers ------------------------------------------------------

export function l2normalize(vector: ArrayLike<number>): Float64Array {
  let normSq = 0;
  for (let i = 0; i < vector.length; i += 1) normSq += vector[i] * vector[i];
  const norm = Math.sqrt(normSq) || 1;
  const out = new Float64Array(vector.length);
  for (let i = 0; i < vector.length; i += 1) out[i] = vector[i] / norm;
  return out;
}

export function cosineSimilarity(a: ArrayLike<number>, b: ArrayLike<number>): number {
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i += 1) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  const denom = Math.sqrt(na) * Math.sqrt(nb);
  return denom === 0 ? 0 : dot / denom;
}

// -- Embedder interface + implementations -------------------------------------

export interface Embedder {
  /** Version tag stored on every vector; vectors are only comparable within one version. */
  readonly modelVersion: string;
  readonly dim: number;
  /** Returns one normalized vector per input text. `isQuery` enables the bge query instruction. */
  embed(texts: string[], opts?: { isQuery?: boolean }): Promise<number[][]>;
}

/** Candidate Transformers.js package names, newest first. Imported lazily from the user's env. */
const TRANSFORMERS_PACKAGES = ["@huggingface/transformers", "@xenova/transformers"];

/**
 * Load the production bge-small-en-v1.5 embedder via Transformers.js/ONNX.
 * The library is imported lazily from the user's environment so the published
 * shim stays zero-dependency. Throws an actionable error if it is not installed.
 */
export async function loadDefaultEmbedder(): Promise<Embedder> {
  let transformers: unknown;
  const errors: string[] = [];
  for (const name of TRANSFORMERS_PACKAGES) {
    try {
      // Non-literal specifier: tsc treats this as Promise<any> and does not
      // resolve the module at build time, keeping the dependency optional.
      transformers = await import(name);
      break;
    } catch (err) {
      errors.push(`${name}: ${(err as Error).message}`);
    }
  }
  if (!transformers) {
    throw new Error(
      "Pensieve embedding model unavailable. Install the on-device embedder:\n" +
        "  npm install -g @huggingface/transformers\n" +
        `(tried ${TRANSFORMERS_PACKAGES.join(", ")})\n` +
        errors.join("\n"),
    );
  }
  const { pipeline } = transformers as { pipeline: (task: string, model: string, opts?: unknown) => Promise<unknown> };
  const extractor = (await pipeline("feature-extraction", "Xenova/bge-small-en-v1.5")) as (
    input: string[],
    opts: { pooling: "mean"; normalize: boolean },
  ) => Promise<{ tolist(): number[][] }>;

  return {
    modelVersion: EMBEDDING_MODEL_VERSION,
    dim: EMBEDDING_DIM,
    async embed(texts, opts) {
      const prepared = opts?.isQuery ? texts.map((t) => BGE_QUERY_INSTRUCTION + t) : texts;
      const output = await extractor(prepared, { pooling: "mean", normalize: true });
      return output.tolist();
    },
  };
}

/**
 * Deterministic, dependency-free, OFFLINE/TEST embedder. NOT semantic — it hashes
 * tokens into a fixed-dim bag-of-words vector. Tagged with a distinct
 * `modelVersion` ("hashing-bow-v1") so its vectors can never be mixed with real
 * bge vectors by the version-match guard. Use for plumbing tests and offline dev
 * of the encrypt/cloak/commit/search loop, never for production recall.
 */
export function createDeterministicHashingEmbedder(dim = EMBEDDING_DIM): Embedder {
  return {
    modelVersion: "hashing-bow-v1",
    dim,
    async embed(texts, opts) {
      const prefix = opts?.isQuery ? BGE_QUERY_INSTRUCTION : "";
      return texts.map((text) => {
        const acc = new Float64Array(dim);
        const tokens = (prefix + text).toLowerCase().split(/[^a-z0-9]+/u).filter((t) => t.length >= 2);
        for (const token of tokens) {
          const digest = createHash("sha256").update(token).digest();
          const index = ((digest[0] << 8) | digest[1]) % dim;
          const sign = (digest[2] & 1) === 0 ? 1 : -1;
          acc[index] += sign;
        }
        return Array.from(l2normalize(acc));
      });
    },
  };
}

/**
 * Convenience: embed texts and cloak each vector for upload. Returns plain
 * number[] vectors (JSON-serialisable for commitKnowledgeBatch / the MCP query).
 */
export async function embedAndCloak(
  texts: string[],
  embedder: Embedder,
  opts: { isQuery?: boolean; vaultKey?: Buffer } = {},
): Promise<{ modelVersion: string; vectors: number[][] }> {
  const raw = await embedder.embed(texts, { isQuery: opts.isQuery });
  const vaultKey = opts.vaultKey ?? requireVaultKeyBytes();
  const vectors = raw.map((v) => Array.from(cloakVector(v, { vaultKey, modelVersion: embedder.modelVersion })));
  return { modelVersion: embedder.modelVersion, vectors };
}
