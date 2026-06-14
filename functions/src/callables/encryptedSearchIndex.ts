import { createHash } from "node:crypto";

export type CloudSearchPostingKind = "token" | "semantic";

export interface CloudSearchPostingSource {
  uid: string;
  chunkID: string;
  documentID: string;
  sourceKind: string;
  sourceID: string;
  provider?: string;
  ordinal: number;
  bodyHash: string;
  bodyHashVersion?: number;
  storagePath: string;
  sealedSnippet: unknown;
  indexVersion: number;
  commitID: string;
  updatedAt: unknown;
}

export interface CloudSearchPostingEdge {
  edgeID: string;
  data: Record<string, unknown>;
}

const MAX_TOKEN_POSTING_EDGES_PER_CHUNK = 96;

/**
 * T-PRV-05: the *number* of real token postings a chunk emits leaks how many
 * distinct indexed terms it contains (a co-occurrence / size signal an observer
 * with only the encrypted index could correlate across chunks). To blunt that,
 * the real token-posting count is padded with deterministic DUMMY postings up to
 * the next bucket boundary, so the on-disk count only reveals which coarse bucket
 * a chunk falls in, not its exact term count. Dummy postings carry
 * `isPadding: true` and a hash that can never collide with a real query term, so
 * the read path filters them out and they never produce a false match.
 */
export const CLOUD_SEARCH_TOKEN_POSTING_BUCKET = 16;
/** Marker prefix for deterministic padding hashes — never a real token hash. */
const PADDING_HASH_PREFIX = "pad_";

function uniqueHashes(hashes: string[]): string[] {
  return Array.from(new Set(hashes));
}

/** Round `count` up to the next multiple of `bucket` (the padded posting count). */
export function paddedPostingCount(count: number, bucket = CLOUD_SEARCH_TOKEN_POSTING_BUCKET): number {
  if (count <= 0) return 0;
  return Math.ceil(count / bucket) * bucket;
}

/**
 * Deterministic dummy token hashes for a chunk. Derived by HMAC-free SHA-256 over
 * `chunkID:index` so the SAME chunk always pads to the SAME hashes (idempotent
 * re-indexing produces identical edges, no churn), while different chunks pad to
 * different hashes (padding itself does not become a cross-chunk correlator).
 */
export function deterministicPaddingHashes(chunkID: string, count: number): string[] {
  const hashes: string[] = [];
  for (let index = 0; index < count; index += 1) {
    const digest = createHash("sha256").update(`${chunkID}:${index}`).digest("hex").slice(0, 32);
    hashes.push(`${PADDING_HASH_PREFIX}${digest}`);
  }
  return hashes;
}

export function buildCloudSearchPostingEdges(params: {
  source: CloudSearchPostingSource;
  tokenHashes: string[];
  semanticHashes: string[];
}): CloudSearchPostingEdge[] {
  const edges: CloudSearchPostingEdge[] = [];

  const emit = (kind: CloudSearchPostingKind, hashes: string[], isPadding = false) => {
    const boundedHashes =
      kind === "token" ? uniqueHashes(hashes).slice(0, MAX_TOKEN_POSTING_EDGES_PER_CHUNK) : uniqueHashes(hashes);
    for (const hash of boundedHashes) {
      const postingKey = `${kind}_${hash}`;
      const edgeID = `${postingKey}_${params.source.chunkID}`;
      edges.push({
        edgeID,
        data: stripUndefinedPostingFields({
          uid: params.source.uid,
          postingKey,
          edgeID,
          kind,
          hash,
          chunkID: params.source.chunkID,
          documentID: params.source.documentID,
          sourceKind: params.source.sourceKind,
          sourceID: params.source.sourceID,
          // T-PRV-05: `provider` is the ONLY cleartext facet on a posting and it
          // is gated here — padding postings carry NO provider (so they cannot be
          // facet-correlated), and the real value is omitted entirely when the
          // source did not supply one rather than written as an empty string.
          provider: isPadding ? undefined : params.source.provider,
          ordinal: params.source.ordinal,
          bodyHash: params.source.bodyHash,
          bodyHashVersion: params.source.bodyHashVersion,
          storagePath: params.source.storagePath,
          sealedSnippet: params.source.sealedSnippet,
          updatedAt: params.source.updatedAt,
          indexVersion: params.source.indexVersion,
          commitID: params.source.commitID,
          // Read path filters padding out; never produces a real match.
          isPadding: isPadding ? true : undefined,
          schemaVersion: 1,
        }),
      });
    }
  };

  const realTokenHashes = uniqueHashes(params.tokenHashes).slice(0, MAX_TOKEN_POSTING_EDGES_PER_CHUNK);
  emit("token", realTokenHashes);
  // Pad the real token-posting count up to the next bucket with deterministic
  // dummy postings so the stored count only reveals a coarse bucket, not the
  // exact distinct-term count of the chunk.
  const paddingNeeded = paddedPostingCount(realTokenHashes.length) - realTokenHashes.length;
  if (paddingNeeded > 0) {
    emit("token", deterministicPaddingHashes(params.source.chunkID, paddingNeeded), true);
  }
  emit("semantic", params.semanticHashes);
  return edges;
}

/** Drop `undefined` fields so omitted facets (e.g. provider on padding) are truly absent. */
function stripUndefinedPostingFields(data: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(data)) {
    if (value !== undefined) out[key] = value;
  }
  return out;
}

export function cloudSearchFallbackHashes(requestedHashes: string[], postingMatchedHashes: Iterable<string>): string[] {
  const matched = new Set(postingMatchedHashes);
  return uniqueHashes(requestedHashes).filter((hash) => !matched.has(hash));
}
