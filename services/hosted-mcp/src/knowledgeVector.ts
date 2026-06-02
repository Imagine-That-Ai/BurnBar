/**
 * Pensieve vector store — shared types + a dependency-free in-memory store.
 *
 * Production retrieval runs on Firestore native vector search (findNearest +
 * FieldValue.vector) per member namespace, implemented in `knowledge.ts`. This
 * module holds the value types both sides agree on, the cosine helper, and an
 * in-memory store that exercises the exact isolation + ranking + filter contract
 * so the MCP tools can be unit-tested without a live Firestore (it also backs
 * the findNearest stub in knowledge.test.ts, and is a valid Functions-emulator
 * fallback).
 *
 * Why Firestore vector search and not Cloud SQL pgvector: the plan's residual
 * open decision #1 leaves the engine open (pgvector was only the default).
 * Firestore reuses the existing owner-only `users/{uid}/...` isolation rules,
 * needs no separate instance to provision, keeps commit writing a single store,
 * and ships its index declaratively via firestore.indexes.json. pgvector remains
 * a documented future scale lever (see docs/PENSIEVE.md).
 *
 * Isolation invariant: every query is scoped to a single `namespaceUid` taken
 * from the verified bearer token (claims.sub). A client-supplied namespace is
 * NEVER accepted. The server returns only ciphertext + opaque cloaked vectors;
 * it never decrypts. Server-honoured filters are limited to PLAINTEXT columns
 * (sourceKind, sourceSlug, embeddingModelVersion); richer filters (sourcePath /
 * section / category) live in sealed metadata and are applied on-device.
 */

export const KNOWLEDGE_VECTOR_DIM = 384;

/** One stored chunk. `embedding` is already cloaked; ciphertext/sealedMetadata are opaque. */
export interface KnowledgeVectorRecord {
  vectorId: string;
  embedding: number[]; // cloaked, length KNOWLEDGE_VECTOR_DIM
  embeddingModelVersion: string;
  ciphertext: string; // AES-256-GCM envelope JSON (opaque to server)
  sealedMetadata: string; // AES-256-GCM envelope JSON (opaque to server)
  sourceKind: string; // repo_docs | notes | chat_memory
  sourceSlug: string;
  contentHash: string;
  updatedAt: string; // ISO-8601
}

/** Filters honoured server-side. Only plaintext fields — never sealed metadata. */
export interface KnowledgeSearchFilters {
  sourceKind?: string;
  sourceSlug?: string;
  embeddingModelVersion?: string;
}

export interface KnowledgeSearchHit {
  vectorId: string;
  ciphertext: string;
  sealedMetadata: string;
  sourceKind: string;
  sourceSlug: string;
  score: number; // cosine similarity in [-1, 1]
  updatedAt: string;
}

export interface KnowledgeSearchResult {
  hits: KnowledgeSearchHit[];
}

export interface KnowledgeVectorStore {
  upsert(namespaceUid: string, records: KnowledgeVectorRecord[]): Promise<{ written: number }>;
  search(
    namespaceUid: string,
    queryVector: number[],
    filters: KnowledgeSearchFilters,
    limit: number,
  ): Promise<KnowledgeSearchResult>;
  getById(namespaceUid: string, vectorId: string): Promise<KnowledgeSearchHit | undefined>;
  deleteBySlug(namespaceUid: string, sourceSlug: string): Promise<{ deleted: number }>;
  purge(namespaceUid: string): Promise<{ deleted: number }>;
  count(namespaceUid: string): Promise<number>;
}

// -- math --------------------------------------------------------------------

export function cosineSimilarity(a: number[], b: number[]): number {
  let dot = 0;
  let na = 0;
  let nb = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i += 1) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  const denom = Math.sqrt(na) * Math.sqrt(nb);
  return denom === 0 ? 0 : dot / denom;
}

function matchesFilters(record: KnowledgeVectorRecord, filters: KnowledgeSearchFilters): boolean {
  if (filters.sourceKind && record.sourceKind !== filters.sourceKind) return false;
  if (filters.sourceSlug && record.sourceSlug !== filters.sourceSlug) return false;
  if (filters.embeddingModelVersion && record.embeddingModelVersion !== filters.embeddingModelVersion) return false;
  return true;
}

function toHit(record: KnowledgeVectorRecord, score: number): KnowledgeSearchHit {
  return {
    vectorId: record.vectorId,
    ciphertext: record.ciphertext,
    sealedMetadata: record.sealedMetadata,
    sourceKind: record.sourceKind,
    sourceSlug: record.sourceSlug,
    score,
    updatedAt: record.updatedAt,
  };
}

// -- in-memory store (emulator / tests) --------------------------------------

/**
 * Dependency-free store keyed by `${namespaceUid} ${vectorId}`. Brute-force
 * cosine search. Exercises the exact isolation + ranking + filter contract the
 * production Firestore path must honour.
 */
export function createInMemoryKnowledgeVectorStore(): KnowledgeVectorStore & {
  /** test/debug only: total rows across all namespaces */
  size(): number;
} {
  const rows = new Map<string, { ns: string; record: KnowledgeVectorRecord }>();
  const key = (ns: string, id: string) => `${ns} ${id}`;

  return {
    async upsert(namespaceUid, records) {
      for (const record of records) rows.set(key(namespaceUid, record.vectorId), { ns: namespaceUid, record });
      return { written: records.length };
    },
    async search(namespaceUid, queryVector, filters, limit) {
      const scored: KnowledgeSearchHit[] = [];
      for (const { ns, record } of rows.values()) {
        if (ns !== namespaceUid) continue; // isolation: never cross namespaces
        if (!matchesFilters(record, filters)) continue;
        scored.push(toHit(record, cosineSimilarity(queryVector, record.embedding)));
      }
      scored.sort((a, b) => b.score - a.score);
      return { hits: scored.slice(0, Math.max(0, limit)) };
    },
    async getById(namespaceUid, vectorId) {
      const found = rows.get(key(namespaceUid, vectorId));
      return found ? toHit(found.record, 1) : undefined;
    },
    async deleteBySlug(namespaceUid, sourceSlug) {
      let deleted = 0;
      for (const [k, { ns, record }] of rows) {
        if (ns === namespaceUid && record.sourceSlug === sourceSlug) {
          rows.delete(k);
          deleted += 1;
        }
      }
      return { deleted };
    },
    async purge(namespaceUid) {
      let deleted = 0;
      for (const [k, { ns }] of rows) {
        if (ns === namespaceUid) {
          rows.delete(k);
          deleted += 1;
        }
      }
      return { deleted };
    },
    async count(namespaceUid) {
      let n = 0;
      for (const { ns } of rows.values()) if (ns === namespaceUid) n += 1;
      return n;
    },
    size() {
      return rows.size;
    },
  };
}
