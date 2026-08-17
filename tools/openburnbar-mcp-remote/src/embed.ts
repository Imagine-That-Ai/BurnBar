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

import {
  domainCorePensieveDeterministicEmbed,
  domainCorePensieveVectorCloak,
} from "./domainCoreCloudVault.js";
import {
  legacyCloakVector,
  legacyDeterministicEmbed,
} from "./legacy/pensieveVectorLegacy.js";
import { readVaultKey } from "./vaultStore.js";

/**
 * Pinned production embedding model. Stored on every vector; index- and
 * query-time must match.
 *
 * FLAG-DAY (dedup-v0 retirement): bumped from "bge-small-en-v1.5" to the
 * "-vault-dedup-v1" tag so a re-ingest lands every vector under a NEW tag. The
 * server search floors `dedupHashVersion == 1` AND filters this tag, so stranded
 * legacy v0 rows (still on the old "bge-small-en-v1.5" tag) become unreachable by
 * recall and are deleted by `purgeLegacyKnowledgeVectors`. MUST stay
 * byte-identical to `PensieveVectorCloak.embeddingModelVersion` (Swift).
 */
export const EMBEDDING_MODEL_VERSION = "bge-small-en-v1.5-vault-dedup-v1";
export const EMBEDDING_DIM = 384;

/** bge retrieval asymmetry: queries get an instruction prefix, documents do not. */
export const BGE_QUERY_INSTRUCTION = "Represent this sentence for searching relevant passages: ";

/**
 * Number of Householder reflections composed into the cloak. 24 > log2(384) for
 * thorough WITHIN-vector coordinate mixing (basis hiding; defeats signed-
 * permutation structure). NOTE: this is NOT sized for cross-user decorrelation —
 * two per-user Qs leave cross-tenant cosine ≈ 0.77 here; full unlinkability would
 * need ~dim reflections. See docs/pensieve-leakage-analysis.md. Changing this
 * value re-cloaks every stored vector and must stay in lockstep with
 * PensieveVectorCloak.swift, so treat it as a versioned migration.
 */

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
  if (!raw) {return undefined;}
  const key = Buffer.from(raw, "base64");
  return key.length === 32 ? key : undefined;
}

function requireVaultKeyBytes(): Buffer {
  const key = loadVaultKeyBytes();
  if (!key) {throw new VaultKeyUnavailableError();}
  return key;
}

// -- Cloaking (vault-key orthonormal transform) -------------------------------

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
  return domainCorePensieveVectorCloak(
    vector,
    vaultKey,
    modelVersion,
    () => legacyCloakVector(vector, vaultKey, modelVersion),
  );
}

// -- Vector math helpers ------------------------------------------------------

export function l2normalize(vector: ArrayLike<number>): Float64Array {
  let normSq = 0;
  for (let i = 0; i < vector.length; i += 1) {normSq += vector[i] * vector[i];}
  const norm = Math.sqrt(normSq) || 1;
  const out = new Float64Array(vector.length);
  for (let i = 0; i < vector.length; i += 1) {out[i] = vector[i] / norm;}
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
      "Pensieve embedding model unavailable. The openburnbar package ships zero runtime\n" +
        "dependencies, so the on-device embedder is a separate one-time global install:\n" +
        "  npm install -g @huggingface/transformers\n" +
        "Then rerun the command. The bge-small-en-v1.5 model itself downloads from\n" +
        "Hugging Face on first use.\n" +
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
      return texts.map((text) => domainCorePensieveDeterministicEmbed(
        text,
        dim,
        prefix.length > 0,
        () => legacyDeterministicEmbed(text, dim, prefix.length > 0),
      ));
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
