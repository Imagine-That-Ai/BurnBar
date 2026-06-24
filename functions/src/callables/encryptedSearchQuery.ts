/**
 * @fileoverview Encrypted conversation index search callable.
 *
 * Split out of `encryptedSearch.ts` to keep both modules under the 600-line cap. The
 * `searchEncryptedConversationIndex` callable and its scoring/merging helpers live here; the
 * original module re-exports the callable so every existing `import ... from
 * "./callables/encryptedSearch.js"` keeps resolving byte-identically.
 *
 * Behavior is a verbatim relocation of the prior inline handler: identical auth gate, entitlement
 * gate, validation, posting/fallback merge order, scoring, and hit projection.
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import type {
  CollectionReference,
  DocumentData,
  DocumentSnapshot,
  Query,
  QuerySnapshot,
} from "firebase-admin/firestore";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { boundedTrimmedString, requireOptionalSearchHashes, assertActiveBurnBarProEntitlement } from "./shared.js";
import { cloudSearchCompleteFallbackHashes } from "./encryptedSearchIndex.js";
import { sessionLogManifestIsVisible } from "./conversationQuery.js";
import { wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

type ScoredChunk = {
  id: string;
  data: DocumentData;
  tokenMatches: number;
  semanticMatches: number;
};

type HashFieldName = "tokenHashes" | "semanticHashes";
type ScoreName = "tokenMatches" | "semanticMatches";

/**
 * Mutable accumulator threaded through the merge helpers so the relocated logic keeps its exact
 * scoring side-effects (the prior closures captured these same maps).
 */
type SearchContext = {
  uid: string;
  provider: string | undefined;
  scoredById: Map<string, ScoredChunk>;
  chunkCache: Map<string, DocumentSnapshot>;
  countedMatches: Set<string>;
  manifestVisibilityCache: Map<string, boolean>;
  visibleDocumentIDs: Set<string>;
};

const SEARCH_POSTING_SCAN_BATCH_LIMIT = 500;
const SEARCH_FALLBACK_SCAN_BATCH_LIMIT = 250;

async function searchManifestIsVisible(context: SearchContext, documentID: string): Promise<boolean> {
  const cached = context.manifestVisibilityCache.get(documentID);
  if (cached !== undefined) return cached;
  if (!documentID || documentID.includes("/")) {
    context.manifestVisibilityCache.set(documentID, false);
    return false;
  }
  const manifestSnap = await db.doc(`users/${context.uid}/session_logs/${documentID}`).get();
  const visible = manifestSnap.exists && sessionLogManifestIsVisible(manifestSnap.data() ?? {});
  context.manifestVisibilityCache.set(documentID, visible);
  return visible;
}

/**
 * Merge a single chunk doc's hash matches into the running score. Returns whether the doc matched
 * at least one requested hash (preserving the prior `mergeChunkDoc` boolean contract).
 */
async function mergeChunkDoc(
  context: SearchContext,
  doc: DocumentSnapshot,
  requested: Set<string>,
  fieldName: HashFieldName,
  scoreName: ScoreName,
): Promise<boolean> {
  if (!doc.exists) return false;
  const data = doc.data() ?? {};
  if (context.provider && data.provider !== context.provider) return false;
  const hashes = Array.isArray(data[fieldName])
    ? data[fieldName].filter((hash): hash is string => typeof hash === "string")
    : [];
  let matches = 0;
  for (const hash of hashes) {
    if (!requested.has(hash)) continue;
    const matchKey = `${scoreName}:${doc.id}:${hash}`;
    if (context.countedMatches.has(matchKey)) continue;
    context.countedMatches.add(matchKey);
    matches += 1;
  }
  if (matches <= 0) return false;
  const documentID = typeof data.documentID === "string" ? data.documentID : "";
  if (!(await searchManifestIsVisible(context, documentID))) return false;
  const existing = context.scoredById.get(doc.id) ?? {
    id: doc.id,
    data,
    tokenMatches: 0,
    semanticMatches: 0,
  };
  existing[scoreName] += matches;
  context.scoredById.set(doc.id, existing);
  context.visibleDocumentIDs.add(documentID);
  return true;
}

/** Cache then score every chunk in a fallback array-contains-any snapshot. */
async function mergeSnapshot(
  context: SearchContext,
  snap: QuerySnapshot,
  requested: Set<string>,
  fieldName: HashFieldName,
  scoreName: ScoreName,
): Promise<void> {
  for (const doc of snap.docs) {
    context.chunkCache.set(doc.id, doc);
    await mergeChunkDoc(context, doc, requested, fieldName, scoreName);
  }
}

/** Resolve and score the chunk ids referenced by one posting-query page. */
async function mergePostingSnapshot(
  context: SearchContext,
  postingSnaps: QuerySnapshot,
  requested: Set<string>,
  kind: "token" | "semantic",
  fieldName: HashFieldName,
  scoreName: ScoreName,
): Promise<void> {
  const chunkIDs = new Set<string>();
  for (const postingSnap of postingSnaps.docs) {
    const data = postingSnap.data();
    if (!data || data.kind !== kind || typeof data.hash !== "string") continue;
    if (!requested.has(data.hash)) continue;
    if (typeof data.chunkID === "string") {
      chunkIDs.add(data.chunkID);
    }
  }
  if (chunkIDs.size === 0) return;
  const missingRefs = Array.from(chunkIDs)
    .filter((chunkID) => !context.chunkCache.has(chunkID))
    .map((chunkID) => db.doc(`users/${context.uid}/cloud_search_chunks/${chunkID}`));
  if (missingRefs.length > 0) {
    const chunkSnaps = await db.getAll(...missingRefs);
    for (const chunkSnap of chunkSnaps) {
      context.chunkCache.set(chunkSnap.id, chunkSnap);
    }
  }
  for (const chunkID of chunkIDs) {
    const chunkSnap = context.chunkCache.get(chunkID);
    if (!chunkSnap) continue;
    await mergeChunkDoc(context, chunkSnap, requested, fieldName, scoreName);
  }
}

/** Score posting-resolved chunks. */
async function mergePostingHits(
  context: SearchContext,
  hashes: string[],
  kind: "token" | "semantic",
  fieldName: HashFieldName,
  scoreName: ScoreName,
  targetVisibleDocuments: number,
): Promise<void> {
  if (hashes.length === 0) return;
  const postingKeys = hashes.map((hash) => `${kind}_${hash}`);
  const requested = new Set(hashes);
  let baseQuery: Query = db
    .collection(`users/${context.uid}/cloud_search_postings`)
    .where("postingKey", "in", postingKeys);
  if (context.provider) baseQuery = baseQuery.where("provider", "==", context.provider);
  let cursor: DocumentSnapshot | undefined;
  do {
    const query = cursor == null ? baseQuery : baseQuery.startAfter(cursor);
    const postingSnaps = await query.limit(SEARCH_POSTING_SCAN_BATCH_LIMIT).get();
    if (postingSnaps.empty) return;
    await mergePostingSnapshot(context, postingSnaps, requested, kind, fieldName, scoreName);
    if (postingSnaps.size < SEARCH_POSTING_SCAN_BATCH_LIMIT) return;
    cursor = postingSnaps.docs[postingSnaps.docs.length - 1];
  } while (context.visibleDocumentIDs.size < targetVisibleDocuments);
}

function fallbackQuery(
  context: SearchContext,
  chunksRef: CollectionReference,
  fieldName: HashFieldName,
  hash: string,
): Query {
  let query: Query = chunksRef.where(fieldName, "array-contains-any", [hash]);
  if (context.provider) query = query.where("provider", "==", context.provider);
  return query;
}

async function mergeFallbackHash(
  context: SearchContext,
  chunksRef: CollectionReference,
  hash: string,
  fieldName: HashFieldName,
  scoreName: ScoreName,
  targetVisibleDocuments: number,
): Promise<void> {
  const requested = new Set([hash]);
  const baseQuery = fallbackQuery(context, chunksRef, fieldName, hash);
  let cursor: DocumentSnapshot | undefined;
  do {
    const query = cursor == null ? baseQuery : baseQuery.startAfter(cursor);
    const snap = await query.limit(SEARCH_FALLBACK_SCAN_BATCH_LIMIT).get();
    if (snap.empty) return;
    await mergeSnapshot(context, snap, requested, fieldName, scoreName);
    if (snap.size < SEARCH_FALLBACK_SCAN_BATCH_LIMIT) return;
    cursor = snap.docs[snap.docs.length - 1];
  } while (context.visibleDocumentIDs.size < targetVisibleDocuments);
}

/** Run fallback queries per requested hash and keep paging past tombstoned-only batches. */
async function mergeFallbackHits(
  context: SearchContext,
  chunksRef: CollectionReference,
  hashes: string[],
  fieldName: HashFieldName,
  scoreName: ScoreName,
  targetVisibleDocuments: number,
): Promise<void> {
  const fallbackHashes = cloudSearchCompleteFallbackHashes(hashes);
  if (fallbackHashes.length === 0) return;
  for (const hash of fallbackHashes) {
    await mergeFallbackHash(context, chunksRef, hash, fieldName, scoreName, targetVisibleDocuments);
  }
}

/** Sort scored chunks by weighted score, breaking ties by ordinal (verbatim prior comparator). */
function sortScoredChunks(scoredById: Map<string, ScoredChunk>): ScoredChunk[] {
  return Array.from(scoredById.values())
    .filter((item) => item.tokenMatches > 0 || item.semanticMatches > 0)
    .sort((a, b) => {
      const aScore = a.tokenMatches * 2 + a.semanticMatches;
      const bScore = b.tokenMatches * 2 + b.semanticMatches;
      return bScore - aScore || Number(a.data.ordinal ?? 0) - Number(b.data.ordinal ?? 0);
    });
}

/** Project a scored chunk + its owning document into the wire hit shape (verbatim field set). */
function buildSearchHit(
  uid: string,
  item: ScoredChunk,
  docData: DocumentData,
  documentID: string,
  tokenCount: number,
  semanticCount: number,
): Record<string, unknown> {
  return {
    id: item.id,
    uid,
    chunkID: item.id,
    documentID,
    sourceKind: item.data.sourceKind,
    sourceID: item.data.sourceID,
    provider: item.data.provider,
    sealedTitle: docData.sealedTitle,
    sealedSnippet: item.data.sealedSnippet,
    sealedBodyPreview: docData.sealedBodyPreview,
    storagePath: item.data.storagePath,
    bodyHash: item.data.bodyHash,
    bodyHashVersion: item.data.bodyHashVersion ?? docData.bodyHashVersion ?? 0,
    score: Math.min(1, (item.tokenMatches * 2 + item.semanticMatches) / Math.max(1, tokenCount * 2 + semanticCount)),
    tokenScore: tokenCount > 0 ? item.tokenMatches / tokenCount : 0,
    semanticScore: semanticCount > 0 ? item.semanticMatches / semanticCount : 0,
    matchKind:
      item.tokenMatches > 0 && item.semanticMatches > 0 ? "hybrid" : item.semanticMatches > 0 ? "semantic" : "token",
    tokenHashVersion: item.data.tokenHashVersion ?? 1,
    semanticHashVersion: item.data.semanticHashVersion ?? 0,
    indexVersion: item.data.indexVersion ?? 1,
  };
}

/** Walk scored chunks newest-first, dedupe by document, and emit at most `limit` verified hits. */
async function buildSearchHits(
  context: SearchContext,
  scored: ScoredChunk[],
  tokenCount: number,
  semanticCount: number,
  limit: number,
): Promise<Array<Record<string, unknown>>> {
  const hits: Array<Record<string, unknown>> = [];
  const seenDocuments = new Set<string>();
  for (const item of scored) {
    const documentID = typeof item.data.documentID === "string" ? item.data.documentID : "";
    if (!documentID || documentID.includes("/") || seenDocuments.has(documentID)) continue;
    const docSnap = await db.doc(`users/${context.uid}/cloud_search_documents/${documentID}`).get();
    if (!docSnap.exists) continue;
    const docData = docSnap.data() ?? {};
    if (docData.bodyHash !== item.data.bodyHash || docData.storagePath !== item.data.storagePath) continue;
    if (!(await searchManifestIsVisible(context, documentID))) continue;
    seenDocuments.add(documentID);
    hits.push(buildSearchHit(context.uid, item, docData, documentID, tokenCount, semanticCount));
    if (hits.length >= limit) break;
  }
  return hits;
}

export const searchEncryptedConversationIndex = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "searchEncryptedConversationIndex",
    async (
      request: CallableRequest<{
        tokenHashes?: unknown;
        semanticHashes?: unknown;
        limit?: unknown;
        provider?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before searching session logs.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarProEntitlement(uid);

      const tokenHashes = requireOptionalSearchHashes(request.data.tokenHashes, "tokenHashes").slice(0, 10);
      const semanticHashes = requireOptionalSearchHashes(request.data.semanticHashes, "semanticHashes").slice(0, 12);
      const limitRaw = typeof request.data.limit === "number" ? request.data.limit : 25;
      const limit = Math.max(1, Math.min(Math.floor(limitRaw), 50));
      const provider = boundedTrimmedString(request.data.provider, "provider", 80, false);
      if (tokenHashes.length === 0 && semanticHashes.length === 0) return { hits: [] };

      const context: SearchContext = {
        uid,
        provider,
        scoredById: new Map<string, ScoredChunk>(),
        chunkCache: new Map<string, DocumentSnapshot>(),
        countedMatches: new Set<string>(),
        manifestVisibilityCache: new Map<string, boolean>(),
        visibleDocumentIDs: new Set<string>(),
      };
      const chunksRef = db.collection(`users/${uid}/cloud_search_chunks`);
      const targetVisibleDocuments = Math.max(limit, Math.min(200, limit * 4));

      await mergePostingHits(context, tokenHashes, "token", "tokenHashes", "tokenMatches", targetVisibleDocuments);
      await mergePostingHits(
        context,
        semanticHashes,
        "semantic",
        "semanticHashes",
        "semanticMatches",
        targetVisibleDocuments,
      );

      await mergeFallbackHits(context, chunksRef, tokenHashes, "tokenHashes", "tokenMatches", targetVisibleDocuments);
      await mergeFallbackHits(
        context,
        chunksRef,
        semanticHashes,
        "semanticHashes",
        "semanticMatches",
        targetVisibleDocuments,
      );

      const scored = sortScoredChunks(context.scoredById);
      const hits = await buildSearchHits(context, scored, tokenHashes.length, semanticHashes.length, limit);
      return { hits };
    },
  ),
);
