import type { Firestore } from "firebase-admin/firestore";
import { verifyCursor, signCursor } from "./cursors.js";
import { HttpError } from "./errors.js";

const HEX_32_128 = /^[a-f0-9]{32,128}$/u;
const ACTIVE_COMMIT_CACHE_TTL_MS = 30_000;
const activeCommitCache = new Map<string, { activeCommitIDs: Set<string>; expiresAtMs: number }>();

export interface SearchArgs {
  query?: string;
  tokenHashes?: string[];
  semanticHashes?: string[];
  provider?: string;
  model?: string;
  projectName?: string;
  harness?: string;
  from?: string;
  to?: string;
  limit?: number;
  cursor?: string;
  includeBodyPreview?: boolean;
}

function hashes(raw: unknown, max: number, field: string): string[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) throw new HttpError(400, `${field} must be an array.`, "invalid_input");
  return raw.slice(0, max).filter((item): item is string => typeof item === "string" && HEX_32_128.test(item));
}

export async function searchConversations(db: Firestore, uid: string, args: SearchArgs) {
  const limit = Math.max(1, Math.min(Math.floor(Number(args.limit ?? 10)), 50));
  const tokenHashes = hashes(args.tokenHashes, 10, "tokenHashes");
  const semanticHashes = hashes(args.semanticHashes, 12, "semanticHashes");
  if (tokenHashes.length === 0 && semanticHashes.length === 0) {
    return {
      mode: "local_decrypt_shim_required",
      hits: [],
      warning: "Sealed-only hosted search requires locally derived opaque query hashes. Use openburnbar-mcp-remote for decrypted search.",
      readBudget: { firestoreDocumentReads: 0, storageReads: 0, searchReadCap: 150, withinSearchReadBudget: true }
    };
  }

  const offset = args.cursor ? verifyCursor(args.cursor, uid, "burnbar_search_conversations").offset : 0;
  let firestoreDocumentReads = 0;
  const active = await activeCommitIDs(db, uid);
  firestoreDocumentReads += active.firestoreDocumentReads;
  const candidates = new Map<string, { id: string; tokenMatches: number; semanticMatches: number; data: FirebaseFirestore.DocumentData }>();
  const remainingSearchReadBudget = Math.max(0, 150 - firestoreDocumentReads);
  const activePostingQueryCount = [tokenHashes, semanticHashes].filter((items) => items.length > 0).length;
  const candidateReadCap = Math.max(
    1,
    Math.min(limit * 2, Math.floor(remainingSearchReadBudget / Math.max(1, activePostingQueryCount * 2)))
  );
  const postingReads = await Promise.all([
    collectPostingMatches(db, uid, tokenHashes, "token", candidates, active, args.provider, candidateReadCap),
    collectPostingMatches(db, uid, semanticHashes, "semantic", candidates, active, args.provider, candidateReadCap)
  ]);
  firestoreDocumentReads += postingReads.reduce((sum, reads) => sum + reads, 0);

  const sorted = Array.from(candidates.values()).sort((a, b) => {
    const scoreA = a.tokenMatches * 2 + a.semanticMatches;
    const scoreB = b.tokenMatches * 2 + b.semanticMatches;
    return scoreB - scoreA || Number(a.data.ordinal ?? 0) - Number(b.data.ordinal ?? 0);
  });
  const page = sorted.slice(offset, offset + limit);
  const hits = [];
  const seenDocuments = new Set<string>();
  for (const item of page) {
    const documentID = typeof item.data.documentID === "string" ? item.data.documentID : "";
    if (!documentID || seenDocuments.has(documentID)) continue;
    let doc: FirebaseFirestore.DocumentData | undefined;
    if (args.includeBodyPreview) {
      const docSnap = await db.doc(`users/${uid}/cloud_search_documents/${documentID}`).get();
      firestoreDocumentReads += 1;
      if (!docSnap.exists) continue;
      doc = docSnap.data() ?? {};
      if (doc.bodyHash !== item.data.bodyHash || doc.storagePath !== item.data.storagePath) continue;
    }
    if (args.projectName && (doc?.projectName ?? item.data.projectName) !== args.projectName) continue;
    seenDocuments.add(documentID);
    hits.push({
      id: `burnbar://conversation/${documentID}/${item.id}`,
      resourceUri: `burnbar://conversation/${documentID}`,
      chunkID: item.id,
      documentID,
      sourceKind: item.data.sourceKind,
      sourceID: item.data.sourceID,
      provider: item.data.provider,
      projectName: doc?.projectName ?? item.data.projectName,
      sealedTitle: doc?.sealedTitle ?? item.data.sealedTitle,
      sealedSnippet: item.data.sealedSnippet,
      sealedBodyPreview: args.includeBodyPreview ? doc?.sealedBodyPreview : undefined,
      score: Math.min(1, (item.tokenMatches * 2 + item.semanticMatches) / Math.max(1, tokenHashes.length * 2 + semanticHashes.length)),
      matchKind: item.tokenMatches > 0 && item.semanticMatches > 0 ? "hybrid" : item.semanticMatches > 0 ? "semantic" : "token",
      decryptMode: "local_decrypt_shim"
    });
  }
  return {
    hits,
    nextCursor: offset + limit < sorted.length
      ? signCursor({ uid, tool: "burnbar_search_conversations", offset: offset + limit, exp: Date.now() + 15 * 60_000 })
      : undefined,
    storageReads: 0,
    readBudget: { firestoreDocumentReads, storageReads: 0, searchReadCap: 150, withinSearchReadBudget: firestoreDocumentReads <= 150 }
  };
}

async function activeCommitIDs(db: Firestore, uid: string): Promise<{ activeCommitIDs: Set<string>; firestoreDocumentReads: number }> {
  const cached = activeCommitCache.get(uid);
  if (cached && cached.expiresAtMs > Date.now()) {
    return { activeCommitIDs: new Set(cached.activeCommitIDs), firestoreDocumentReads: 0 };
  }
  const manifest = await db.doc(`users/${uid}/cloud_search_index_manifest/current`).get();
  const active = new Set<string>();
  const byDevice = manifest.get("activeCommitIDsByDevice");
  if (byDevice && typeof byDevice === "object") {
    for (const value of Object.values(byDevice as Record<string, unknown>)) {
      if (typeof value === "string") active.add(value);
    }
  }
  if (active.size > 0) {
    activeCommitCache.set(uid, { activeCommitIDs: new Set(active), expiresAtMs: Date.now() + ACTIVE_COMMIT_CACHE_TTL_MS });
    return { activeCommitIDs: active, firestoreDocumentReads: 1 };
  }
  const state = await db.collection(`users/${uid}/cloud_search_index_state`).limit(100).get();
  for (const doc of state.docs) {
    const commitID = doc.get("activeCommitID");
    if (typeof commitID === "string") active.add(commitID);
  }
  activeCommitCache.set(uid, { activeCommitIDs: new Set(active), expiresAtMs: Date.now() + ACTIVE_COMMIT_CACHE_TTL_MS });
  return { activeCommitIDs: active, firestoreDocumentReads: 1 + state.docs.length };
}

async function collectPostingMatches(
  db: Firestore,
  uid: string,
  inputHashes: string[],
  kind: "token" | "semantic",
  candidates: Map<string, { id: string; tokenMatches: number; semanticMatches: number; data: FirebaseFirestore.DocumentData }>,
  active: { activeCommitIDs: Set<string>; firestoreDocumentReads: number },
  provider: string | undefined,
  candidateReadCap: number
): Promise<number> {
  if (inputHashes.length === 0) return 0;
  const requested = new Set(inputHashes);
  let query: FirebaseFirestore.Query = db
    .collection(`users/${uid}/cloud_search_postings`)
    .where("postingKey", "in", inputHashes.map((hash) => `${kind}_${hash}`));
  if (provider) query = query.where("provider", "==", provider);
  const postings = await query.limit(candidateReadCap).get();
  let firestoreDocumentReads = postings.docs.length;
  const chunkIDs = new Set<string>();
  for (const posting of postings.docs) {
    const postingData = posting.data() ?? {};
    const hash = posting.get("hash");
    const chunkID = posting.get("chunkID");
    if (posting.get("kind") === kind && typeof hash === "string" && requested.has(hash) && typeof chunkID === "string") {
      if (postingHasChunkPayload(postingData)) {
        const commitID = typeof postingData.commitID === "string" ? postingData.commitID : undefined;
        if (active.activeCommitIDs.size > 0 && (!commitID || !active.activeCommitIDs.has(commitID))) continue;
        const current = candidates.get(chunkID) ?? { id: chunkID, tokenMatches: 0, semanticMatches: 0, data: postingData };
        if (kind === "token") current.tokenMatches += 1;
        else current.semanticMatches += 1;
        candidates.set(chunkID, current);
      } else {
        chunkIDs.add(chunkID);
      }
    }
  }
  const refs = Array.from(chunkIDs).slice(0, candidateReadCap).map((chunkID) => db.doc(`users/${uid}/cloud_search_chunks/${chunkID}`));
  if (refs.length === 0) return firestoreDocumentReads;
  const chunks = await db.getAll(...refs);
  firestoreDocumentReads += refs.length;
  for (const chunk of chunks) {
    if (!chunk.exists) continue;
    const data = chunk.data() ?? {};
    if (provider && data.provider !== provider) continue;
    const commitID = typeof data.commitID === "string" ? data.commitID : undefined;
    if (active.activeCommitIDs.size > 0 && (!commitID || !active.activeCommitIDs.has(commitID))) continue;
    const values = Array.isArray(data[kind === "token" ? "tokenHashes" : "semanticHashes"])
      ? data[kind === "token" ? "tokenHashes" : "semanticHashes"].filter((hash: unknown): hash is string => typeof hash === "string")
      : [];
    const matches = values.reduce((sum: number, hash: string) => sum + (requested.has(hash) ? 1 : 0), 0);
    if (matches <= 0) continue;
    const current = candidates.get(chunk.id) ?? { id: chunk.id, tokenMatches: 0, semanticMatches: 0, data };
    if (kind === "token") current.tokenMatches += matches;
    else current.semanticMatches += matches;
    candidates.set(chunk.id, current);
  }
  return firestoreDocumentReads;
}

function postingHasChunkPayload(data: FirebaseFirestore.DocumentData): boolean {
  return typeof data.documentID === "string"
    && typeof data.sourceKind === "string"
    && typeof data.sourceID === "string"
    && typeof data.bodyHash === "string"
    && typeof data.storagePath === "string"
    && data.sealedSnippet !== undefined;
}

export async function listIndexStatus(db: Firestore, uid: string) {
  const manifest = await db.doc(`users/${uid}/cloud_search_index_manifest/current`).get();
  if (manifest.exists) return { ...manifest.data(), mode: "manifest" };
  const states = await db.collection(`users/${uid}/cloud_search_index_state`).limit(100).get();
  return {
    mode: "legacy_state_rollup",
    devices: states.docs.map((doc) => ({ deviceId: doc.id, ...doc.data() })),
    stale: states.empty
  };
}

export async function listFacets(db: Firestore, uid: string, kind: string) {
  const field = kind === "model" ? "model" : kind === "project" ? "projectName" : kind === "harness" ? "harness" : "provider";
  const docs = await db.collection(`users/${uid}/cloud_search_documents`).select(field).limit(500).get();
  const counts = new Map<string, number>();
  for (const doc of docs.docs) {
    const value = doc.get(field);
    if (typeof value === "string" && value.trim()) counts.set(value, (counts.get(value) ?? 0) + 1);
  }
  return Array.from(counts.entries()).sort((a, b) => b[1] - a[1]).slice(0, 50).map(([value, count]) => ({ value, count }));
}
