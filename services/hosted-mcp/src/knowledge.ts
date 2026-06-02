/**
 * Pensieve hosted MCP query surface — burnbar_search_knowledge +
 * burnbar_get_knowledge_document.
 *
 * Mirrors search.ts / resources.ts but retrieves from the member's E2EE
 * knowledge memory at `users/{uid}/cloud_search_knowledge` via Firestore native
 * vector search (findNearest, COSINE). The query arrives as an ALREADY-CLOAKED
 * 384-dim vector (the shim embeds + cloaks on device); the server returns only
 * ciphertext + opaque sealed metadata and NEVER decrypts. Plaintext recall
 * happens in the local shim (decryptMode: "local_decrypt_shim").
 *
 * Isolation: the namespace is `uid` = claims.sub from the verified bearer token,
 * threaded as the 2nd arg exactly like every other tool. No namespace/uid is
 * ever read from `args`.
 *
 * Server-honoured filters are PLAINTEXT only (sourceKind, sourceSlug,
 * embeddingModelVersion). sourcePath/section/category live in the sealed
 * metadata and are applied on-device after decrypt — the tool accepts them for
 * forward-compatible client post-filtering but the server cannot read them.
 */

import type { Firestore, Query } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { verifyCursor, signCursor } from "./cursors.js";
import { HttpError } from "./errors.js";
import { KNOWLEDGE_VECTOR_DIM } from "./knowledgeVector.js";

const KNOWLEDGE_RESOURCE_RE = /^burnbar:\/\/knowledge\/([A-Za-z0-9_.:-]+)$/u;
const SEARCH_READ_CAP = 150;
const CURSOR_TTL_MS = 15 * 60_000;
const LOCAL_DECRYPT_MODE = "local_decrypt_shim";
type KnowledgeQueryVector = ReturnType<typeof FieldValue.vector>;

export interface KnowledgeSearchArgs {
  queryVector?: unknown;
  filters?: Record<string, unknown>;
  sourceKind?: unknown;
  sourceSlug?: unknown;
  embeddingModelVersion?: unknown;
  // Sealed-only (applied on-device): present for forward-compat, ignored server-side.
  sourcePath?: unknown;
  section?: unknown;
  category?: unknown;
  limit?: unknown;
  cursor?: unknown;
}

export interface KnowledgeVectorDoc {
  id: string;
  get(field: string): unknown;
}

export interface KnowledgeVectorSnapshot {
  size: number;
  docs: KnowledgeVectorDoc[];
}

export interface KnowledgeVectorQuery {
  where(field: string, op: "==", value: unknown): KnowledgeVectorQuery;
  findNearest(options: {
    vectorField: string;
    queryVector: KnowledgeQueryVector;
    limit: number;
    distanceMeasure: "COSINE";
    distanceResultField: string;
  }): { get(): Promise<KnowledgeVectorSnapshot> };
}

export interface KnowledgeSearchFirestore {
  collection(collectionPath: string): KnowledgeVectorQuery;
}

export interface KnowledgeDocumentSnapshot {
  exists: boolean;
  data(): Record<string, unknown> | undefined;
}

export interface KnowledgeDocumentFirestore {
  doc(documentPath: string): { get(): Promise<KnowledgeDocumentSnapshot> };
}

export interface KnowledgeSearchHit {
  vectorId: string;
  resourceUri: string;
  ciphertext: unknown;
  sealedMetadata: unknown;
  sourceKind: unknown;
  sourceSlug: unknown;
  score: number;
  decryptMode: "local_decrypt_shim";
}

export interface KnowledgeSearchResult {
  hits: KnowledgeSearchHit[];
  nextCursor?: string;
  storageReads: 0;
  readBudget: {
    firestoreDocumentReads: number;
    storageReads: 0;
    searchReadCap: number;
    withinSearchReadBudget: boolean;
  };
}

function firestoreKnowledgeQuery(query: Query): KnowledgeVectorQuery {
  return {
    where(field, op, value) {
      return firestoreKnowledgeQuery(query.where(field, op, value));
    },
    findNearest(options) {
      return {
        async get() {
          const snap = await query.findNearest(options).get();
          return {
            size: snap.size,
            docs: snap.docs.map((doc) => ({
              id: doc.id,
              get: (field: string) => doc.get(field),
            })),
          };
        },
      };
    },
  };
}

export function knowledgeSearchFirestoreFrom(db: Firestore): KnowledgeSearchFirestore {
  return {
    collection(collectionPath) {
      return firestoreKnowledgeQuery(db.collection(collectionPath));
    },
  };
}

/** Validate the device-cloaked query vector: exactly KNOWLEDGE_VECTOR_DIM finite numbers. */
function requireQueryVector(raw: unknown): number[] {
  if (!Array.isArray(raw) || raw.length !== KNOWLEDGE_VECTOR_DIM) {
    throw new HttpError(400, `queryVector must be a ${KNOWLEDGE_VECTOR_DIM}-dimension array.`, "invalid_input");
  }
  const vec = raw.map((v) => Number(v));
  if (vec.some((v) => !Number.isFinite(v))) {
    throw new HttpError(400, "queryVector must contain only finite numbers.", "invalid_input");
  }
  return vec;
}

function boundedString(raw: unknown, max: number): string | undefined {
  if (typeof raw !== "string") return undefined;
  const trimmed = raw.trim();
  if (!trimmed) return undefined;
  return trimmed.slice(0, max);
}

export async function searchKnowledge(db: KnowledgeSearchFirestore, uid: string, args: KnowledgeSearchArgs): Promise<KnowledgeSearchResult> {
  const queryVector = requireQueryVector(args.queryVector);
  const limit = Math.max(1, Math.min(Math.floor(Number(args.limit ?? 10)), 50));
  const offset = args.cursor
    ? verifyCursor(String(args.cursor), uid, "burnbar_search_knowledge").offset
    : 0;

  // Plaintext-only server filters. Accept both top-level and nested `filters`.
  const filters = args.filters ?? {};
  const sourceKind = boundedString(args.sourceKind ?? filters.sourceKind, 64);
  const sourceSlug = boundedString(args.sourceSlug ?? filters.sourceSlug, 256);
  const embeddingModelVersion = boundedString(args.embeddingModelVersion ?? filters.embeddingModelVersion, 120);

  let query: KnowledgeVectorQuery = db.collection(`users/${uid}/cloud_search_knowledge`);
  if (sourceKind) query = query.where("sourceKind", "==", sourceKind);
  if (sourceSlug) query = query.where("sourceSlug", "==", sourceSlug);
  if (embeddingModelVersion) query = query.where("embeddingModelVersion", "==", embeddingModelVersion);

  // Fetch one extra beyond the page so we can tell whether a nextCursor is warranted
  // (findNearest caps the result set, so "is there more?" must be probed explicitly).
  const fetchLimit = Math.min(offset + limit + 1, SEARCH_READ_CAP);
  const snap = await query
    .findNearest({
      vectorField: "embedding",
      queryVector: FieldValue.vector(queryVector),
      limit: fetchLimit,
      distanceMeasure: "COSINE",
      distanceResultField: "_distance",
    })
    .get();

  const firestoreDocumentReads = snap.size;
  const ranked: KnowledgeSearchHit[] = snap.docs.map((doc) => {
    const distance = Number(doc.get("_distance") ?? 1);
    return {
      vectorId: doc.id,
      resourceUri: `burnbar://knowledge/${doc.id}`,
      ciphertext: doc.get("sealedCiphertext"),
      sealedMetadata: doc.get("sealedMetadata"),
      sourceKind: doc.get("sourceKind"),
      sourceSlug: doc.get("sourceSlug"),
      score: 1 - distance, // COSINE distance -> similarity (higher = closer)
      decryptMode: LOCAL_DECRYPT_MODE,
    };
  });
  const hits = ranked.slice(offset, offset + limit);
  const hasMore = ranked.length > offset + limit;

  return {
    hits,
    nextCursor: hasMore
      ? signCursor({ uid, tool: "burnbar_search_knowledge", offset: offset + limit, exp: Date.now() + CURSOR_TTL_MS })
      : undefined,
    storageReads: 0,
    readBudget: {
      firestoreDocumentReads,
      storageReads: 0,
      searchReadCap: SEARCH_READ_CAP,
      withinSearchReadBudget: firestoreDocumentReads <= SEARCH_READ_CAP,
    },
  };
}

export async function readKnowledgeDocument(
  db: KnowledgeDocumentFirestore,
  uid: string,
  args: { resourceUri?: string },
) {
  const uri = typeof args.resourceUri === "string" ? args.resourceUri : "";
  const match = KNOWLEDGE_RESOURCE_RE.exec(uri);
  if (!match) {
    throw new HttpError(400, "resourceUri must be a burnbar://knowledge/<id> URI returned by search.", "invalid_resource_uri");
  }
  const docId = match[1];

  // A knowledge chunk is a single bounded, sealed envelope stored INLINE in the
  // Firestore doc (no Cloud Storage coupling, no string paging) — the doc id is
  // the only owner-scoped lookup needed. The shim decrypts the returned envelope.
  const snap = await db.doc(`users/${uid}/cloud_search_knowledge/${docId}`).get();
  if (!snap.exists) throw new HttpError(404, "Knowledge resource not found.", "resource_not_found");
  const data = snap.data() ?? {};

  return {
    resourceUri: uri,
    contentHash: typeof data.contentHash === "string" ? data.contentHash : "",
    sealedCiphertext: data.sealedCiphertext,
    sealedMetadata: data.sealedMetadata,
    sourceKind: data.sourceKind,
    sourceSlug: data.sourceSlug,
    encrypted: true,
    decryptMode: LOCAL_DECRYPT_MODE,
    storageReads: 0,
    readBudget: { firestoreDocumentReads: 1, storageReads: 0, bodyStorageReadCap: 0, withinBodyReadBudget: true },
  };
}
