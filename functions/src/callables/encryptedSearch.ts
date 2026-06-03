/**
 * @fileoverview Encrypted session logs, cloud search, and project memory callables
 */

import { Timestamp, AggregateField } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import {
  nowISO,
  requiredIdentifier,
  boundedTrimmedString,
  safeCloudDocumentID,
  requireHexDigest,
  requireBoundedNumber,
  requireRecordArray,
  commitBatchedWrites,
  requireTokenHashes,
  requireOptionalSearchHashes,
  requireSealedText,
  optionalISODateString,
  requireBoundedStringArray,
  parseProjectMemoryFreshness,
  requireCloudVaultBlobEnvelope,
  assertUserStoragePath,
  assertEncryptedSessionBlobObject,
  assertActiveBurnBarProEntitlement,
} from "./shared.js";
import { randomBytes } from "node:crypto";
import type { DocumentData, DocumentSnapshot, QuerySnapshot, WriteBatch, Query } from "firebase-admin/firestore";
import type { ProjectMemorySnapshotDoc } from "../types.js";
import { stripUndefinedObject } from "../guards.js";
import { wrapCallableHandler } from "../logging.js";
import {
  applyConversationFacetFilters,
  assertConversationFacetCombination,
  buildConversationPageQuery,
  mapSessionLogManifestRow,
  resolveConversationSort,
} from "./conversationQuery.js";
import { buildCloudSearchPostingEdges, cloudSearchFallbackHashes } from "./encryptedSearchIndex.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

// ---------------------------------------------------------------------------
// Callable: encrypted hosted session logs + cloud search
// ---------------------------------------------------------------------------

export const beginEncryptedSessionBlobUpload = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "beginEncryptedSessionBlobUpload",
    async (
      request: CallableRequest<{
        documentID?: unknown;
        bodyHash?: unknown;
        encryptedByteCount?: unknown;
        contentType?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before uploading session logs.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarProEntitlement(uid);

      const documentID = safeCloudDocumentID(request.data.documentID, "documentID");
      const bodyHash = requireHexDigest(request.data.bodyHash, "bodyHash");
      const encryptedByteCount = requireBoundedNumber(
        request.data.encryptedByteCount,
        "encryptedByteCount",
        1,
        getConfig().encryptedSessionBlobMaxBytes,
      );
      const contentType =
        boundedTrimmedString(request.data.contentType, "contentType", 128, false) ?? "application/octet-stream";
      if (contentType !== "application/octet-stream") {
        throw new HttpsError("invalid-argument", "encrypted session blobs must use application/octet-stream.");
      }

      const storagePath = `users/${uid}/session_logs/${documentID}/bodies/${bodyHash}.json.aesgcm`;
      const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
      const [uploadURL] = await getStorage().bucket().file(storagePath).getSignedUrl({
        version: "v4",
        action: "write",
        expires: expiresAt,
        contentType,
      });

      return {
        storagePath,
        uploadURL,
        expiresAt: expiresAt.toISOString(),
        maxBytes: getConfig().encryptedSessionBlobMaxBytes,
        acceptedByteCount: encryptedByteCount,
      };
    },
  ),
);

export const getEncryptedSessionBlobDownloadUrl = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "getEncryptedSessionBlobDownloadUrl",
    async (
      request: CallableRequest<{
        storagePath?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before reading session logs.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarProEntitlement(uid);
      const storagePath = boundedTrimmedString(request.data.storagePath, "storagePath", 1024, true);
      assertUserStoragePath(uid, storagePath);
      // Verify the body object is actually present before minting a signed URL. A v4 read URL is
      // generated without checking existence, so a deleted/never-uploaded blob would otherwise hand
      // the client a link that 404s on GET — an opaque "download failed". Surfacing `not-found` here
      // lets the app say the transcript is gone (and stop offering a futile retry) instead.
      const file = getStorage().bucket().file(storagePath);
      const [exists] = await file.exists();
      if (!exists) {
        throw new HttpsError("not-found", "The encrypted session log is no longer stored in the cloud.");
      }
      const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
      const [downloadURL] = await file.getSignedUrl({
        version: "v4",
        action: "read",
        expires: expiresAt,
      });
      return { downloadURL, expiresAt: expiresAt.toISOString() };
    },
  ),
);

export const commitEncryptedSearchIndexBatch = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "commitEncryptedSearchIndexBatch",
    async (
      request: CallableRequest<{
        documents?: unknown;
        chunks?: unknown;
        indexVersion?: unknown;
        deviceId?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before syncing the search index.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarProEntitlement(uid);

      const documents = requireRecordArray(request.data.documents, "documents", 50);
      const chunks = requireRecordArray(request.data.chunks, "chunks", 800);
      const indexVersion = requireBoundedNumber(request.data.indexVersion, "indexVersion", 1, 100);
      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 256, true);
      const now = Timestamp.now();
      const commitID = randomBytes(16).toString("hex");

      let writeCount = 0;
      const writes: Array<(batch: WriteBatch) => void> = [];
      const documentsRef = db.collection(`users/${uid}/cloud_search_documents`);
      const chunksRef = db.collection(`users/${uid}/cloud_search_chunks`);
      const postingsRef = db.collection(`users/${uid}/cloud_search_postings`);

      for (const raw of documents) {
        const documentID = safeCloudDocumentID(raw.documentID, "document.documentID");
        const storagePath = boundedTrimmedString(raw.storagePath, "document.storagePath", 1024, true);
        if (!storagePath) {
          throw new HttpsError("invalid-argument", "document.storagePath is required.");
        }
        const requestedEncryptedByteCount = requireBoundedNumber(
          raw.encryptedByteCount,
          "document.encryptedByteCount",
          1,
          getConfig().encryptedSessionBlobMaxBytes,
        );
        const doc = {
          uid,
          documentID,
          deviceId,
          sourceKind: boundedTrimmedString(raw.sourceKind, "document.sourceKind", 64, true),
          sourceID: boundedTrimmedString(raw.sourceID, "document.sourceID", 512, true),
          sourceVersionID: boundedTrimmedString(raw.sourceVersionID, "document.sourceVersionID", 512, false),
          provider: boundedTrimmedString(raw.provider, "document.provider", 80, false),
          bodyHash: requireHexDigest(raw.bodyHash, "document.bodyHash"),
          storagePath,
          sealedTitle: requireSealedText(raw.sealedTitle, "document.sealedTitle"),
          sealedBodyPreview: requireSealedText(raw.sealedBodyPreview, "document.sealedBodyPreview"),
          byteCount: requireBoundedNumber(
            raw.byteCount,
            "document.byteCount",
            0,
            getConfig().encryptedSessionBlobMaxBytes,
          ),
          encryptedByteCount: requestedEncryptedByteCount,
          indexVersion,
          tokenHashVersion: 1,
          semanticHashVersion: 1,
          commitID,
          updatedAt: now,
          schemaVersion: 1,
        };
        doc.encryptedByteCount = await assertEncryptedSessionBlobObject({
          uid,
          storagePath: doc.storagePath,
          documentID,
          bodyHash: doc.bodyHash,
          encryptedByteCount: requestedEncryptedByteCount,
        });
        writes.push((batch) => batch.set(documentsRef.doc(documentID), stripUndefinedObject(doc), { merge: true }));
        writeCount += 1;
      }

      for (const raw of chunks) {
        const documentID = safeCloudDocumentID(raw.documentID, "chunk.documentID");
        const chunkID = safeCloudDocumentID(raw.chunkID, "chunk.chunkID");
        const tokenHashes = requireTokenHashes(raw.tokenHashes, "chunk.tokenHashes");
        const semanticHashes = requireOptionalSearchHashes(raw.semanticHashes, "chunk.semanticHashes");
        const storagePath = boundedTrimmedString(raw.storagePath, "chunk.storagePath", 1024, true);
        if (!storagePath) {
          throw new HttpsError("invalid-argument", "chunk.storagePath is required.");
        }
        if (indexVersion >= 2 && semanticHashes.length === 0) {
          throw new HttpsError(
            "invalid-argument",
            "chunk.semanticHashes are required for encrypted semantic search indexes.",
          );
        }
        const chunk = {
          uid,
          chunkID,
          documentID,
          deviceId,
          sourceKind: boundedTrimmedString(raw.sourceKind, "chunk.sourceKind", 64, true),
          sourceID: boundedTrimmedString(raw.sourceID, "chunk.sourceID", 512, true),
          provider: boundedTrimmedString(raw.provider, "chunk.provider", 80, false),
          ordinal: requireBoundedNumber(raw.ordinal, "chunk.ordinal", 0, 100_000),
          startOffset: requireBoundedNumber(raw.startOffset, "chunk.startOffset", 0, 50_000_000),
          endOffset: requireBoundedNumber(raw.endOffset, "chunk.endOffset", 0, 50_000_000),
          contentHash: requireHexDigest(raw.contentHash, "chunk.contentHash"),
          bodyHash: requireHexDigest(raw.bodyHash, "chunk.bodyHash"),
          storagePath,
          sealedSnippet: requireSealedText(raw.sealedSnippet, "chunk.sealedSnippet"),
          tokenHashes,
          semanticHashes,
          indexVersion,
          tokenHashVersion: 1,
          semanticHashVersion: semanticHashes.length > 0 ? 1 : 0,
          commitID,
          updatedAt: now,
          schemaVersion: 1,
        };
        assertUserStoragePath(uid, chunk.storagePath, chunk.bodyHash, documentID);
        writes.push((batch) => batch.set(chunksRef.doc(chunkID), stripUndefinedObject(chunk), { merge: true }));
        writeCount += 1;
        for (const edge of buildCloudSearchPostingEdges({
          source: {
            uid,
            chunkID,
            documentID,
            sourceKind: chunk.sourceKind,
            sourceID: chunk.sourceID,
            provider: chunk.provider,
            ordinal: chunk.ordinal,
            bodyHash: chunk.bodyHash,
            storagePath: chunk.storagePath,
            sealedSnippet: chunk.sealedSnippet,
            indexVersion,
            commitID,
            updatedAt: now,
          },
          tokenHashes,
          semanticHashes,
        })) {
          writes.push((batch) =>
            batch.set(postingsRef.doc(edge.edgeID), stripUndefinedObject(edge.data), { merge: true }),
          );
          writeCount += 1;
        }
      }

      writes.push((batch) =>
        batch.set(
          db.doc(`users/${uid}/cloud_search_index_state/${deviceId}`),
          stripUndefinedObject({
            uid,
            deviceId,
            indexVersion,
            activeCommitID: commitID,
            lastCommittedAt: now,
            documentCount: documents.length,
            chunkCount: chunks.length,
            postingCount: writeCount - documents.length - chunks.length,
            schemaVersion: 1,
          }),
          { merge: true },
        ),
      );
      writeCount += 1;

      await commitBatchedWrites(writes);
      return { ok: true, writeCount, documentCount: documents.length, chunkCount: chunks.length, commitID };
    },
  ),
);

export const commitEncryptedProjectMemorySnapshot = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "commitEncryptedProjectMemorySnapshot",
    async (
      request: CallableRequest<{
        docID?: unknown;
        legacyDocID?: unknown;
        contentHash?: unknown;
        sourceSessionCount?: unknown;
        sourceConversationCount?: unknown;
        generatedAt?: unknown;
        freshness?: unknown;
        visualKinds?: unknown;
        sealedSnapshot?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before syncing Project Memory.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarProEntitlement(uid);

      // SEAL + OPAQUE DOC ID (privacy-leak-remediation-2026-06-02 §2). The device
      // derives an opaque, deterministic `docID` from the project slug under the
      // vault key (projectMemoryDocID) and keys the doc by it; the plaintext slug
      // and display name are NO LONGER accepted or persisted — both already live
      // inside the sealed `sealedSnapshot` blob.
      const docID = requiredIdentifier(request.data.docID, "docID");
      const contentHash = requireHexDigest(request.data.contentHash, "contentHash");
      const sourceSessionCount = requireBoundedNumber(
        request.data.sourceSessionCount ?? 0,
        "sourceSessionCount",
        0,
        1_000_000,
      );
      const sourceConversationCount = requireBoundedNumber(
        request.data.sourceConversationCount ?? 0,
        "sourceConversationCount",
        0,
        1_000_000,
      );
      const generatedAt = optionalISODateString(request.data.generatedAt, "generatedAt") ?? nowISO();
      const freshness = parseProjectMemoryFreshness(request.data.freshness);
      const visualKinds =
        request.data.visualKinds == null
          ? []
          : requireBoundedStringArray(request.data.visualKinds, "visualKinds", 24, 80);
      const sealedSnapshot = requireCloudVaultBlobEnvelope(request.data.sealedSnapshot, "sealedSnapshot");
      const updatedAt = nowISO();

      const doc: ProjectMemorySnapshotDoc = {
        docID,
        contentHash,
        sourceSessionCount,
        sourceConversationCount,
        generatedAt,
        freshness,
        visualKinds,
        sealedSnapshot,
        encryption: {
          algorithm: sealedSnapshot.algorithm,
          keyVersion: sealedSnapshot.keyVersion,
          envelopeSchemaVersion: sealedSnapshot.schemaVersion,
        },
        // schemaVersion 2 fences the new sealed-only rows from legacy
        // plaintext-slug-keyed rows (privacy-leak-remediation-2026-06-02 §2).
        schemaVersion: 2,
        updatedAt,
      };

      await db.doc(`users/${uid}/project_memory_snapshots/${docID}`).set(stripUndefinedObject(doc), { merge: true });

      // Migration: the device sends `legacyDocID` (the old project-name-derived
      // slug) when it differs from the opaque `docID`. Delete the stranded legacy
      // doc so its cleartext `projectDisplayName` field and name-revealing doc id
      // do not linger server-readable (privacy-leak-remediation-2026-06-02 §2).
      const legacyDocID =
        typeof request.data.legacyDocID === "string" && request.data.legacyDocID.length > 0
          ? request.data.legacyDocID
          : undefined;
      if (legacyDocID && legacyDocID !== docID) {
        await db
          .doc(`users/${uid}/project_memory_snapshots/${legacyDocID}`)
          .delete()
          .catch(() => {
            /* best-effort cleanup; the scheduled privacy backfill is the backstop */
          });
      }
      return {
        ok: true,
        docID,
        contentHash,
        generatedAt,
        updatedAt,
      };
    },
  ),
);

export const getEncryptedProjectMemorySnapshot = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "getEncryptedProjectMemorySnapshot",
    async (
      request: CallableRequest<{
        docID?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before reading Project Memory.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarProEntitlement(uid);

      // Keyed by the opaque vault-key-derived docID the device sends; the server
      // never sees the project slug/name (§2). The returned projection carries
      // only the sealed snapshot + content-free facets — no plaintext name/slug.
      const docID = requiredIdentifier(request.data.docID, "docID");
      const snap = await db.doc(`users/${uid}/project_memory_snapshots/${docID}`).get();
      if (!snap.exists) {
        return { snapshot: null };
      }
      const data = snap.data() ?? {};
      return {
        snapshot: stripUndefinedObject({
          docID: data.docID ?? docID,
          contentHash: data.contentHash,
          sourceSessionCount: data.sourceSessionCount,
          sourceConversationCount: data.sourceConversationCount,
          generatedAt: data.generatedAt,
          freshness: data.freshness,
          visualKinds: data.visualKinds,
          sealedSnapshot: data.sealedSnapshot,
          encryption: data.encryption,
          schemaVersion: data.schemaVersion,
          updatedAt: data.updatedAt,
        }),
      };
    },
  ),
);

export const listEncryptedProjectMemorySnapshots = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "listEncryptedProjectMemorySnapshots",
    async (
      request: CallableRequest<{
        limit?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before listing Project Memory.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarProEntitlement(uid);

      const limit = requireBoundedNumber(request.data.limit ?? 20, "limit", 1, 50);
      const snapshot = await db
        .collection(`users/${uid}/project_memory_snapshots`)
        .orderBy("updatedAt", "desc")
        .limit(limit)
        .get();

      const snapshots = snapshot.docs.map((doc) => {
        const data = doc.data();
        // Opaque docID only — no plaintext name/slug projection (§2). A client
        // that needs the display name opens the sealed snapshot on-device.
        return stripUndefinedObject({
          docID: data.docID ?? doc.id,
          contentHash: data.contentHash,
          sourceSessionCount: data.sourceSessionCount,
          sourceConversationCount: data.sourceConversationCount,
          generatedAt: data.generatedAt,
          freshness: data.freshness,
          visualKinds: data.visualKinds,
          schemaVersion: data.schemaVersion,
          updatedAt: data.updatedAt,
        });
      });

      return { snapshots };
    },
  ),
);

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

      type ScoredChunk = {
        id: string;
        data: DocumentData;
        tokenMatches: number;
        semanticMatches: number;
      };
      const scoredById = new Map<string, ScoredChunk>();
      const chunksRef = db.collection(`users/${uid}/cloud_search_chunks`);
      const chunkCache = new Map<string, DocumentSnapshot>();

      const mergeChunkDoc = (
        doc: DocumentSnapshot,
        requested: Set<string>,
        fieldName: "tokenHashes" | "semanticHashes",
        scoreName: "tokenMatches" | "semanticMatches",
      ): boolean => {
        if (!doc.exists) return false;
        const data = doc.data() ?? {};
        if (provider && data.provider !== provider) return false;
        const hashes = Array.isArray(data[fieldName])
          ? data[fieldName].filter((hash): hash is string => typeof hash === "string")
          : [];
        const matches = hashes.reduce((sum, hash) => sum + (requested.has(hash) ? 1 : 0), 0);
        if (matches <= 0) return false;
        const existing = scoredById.get(doc.id) ?? {
          id: doc.id,
          data,
          tokenMatches: 0,
          semanticMatches: 0,
        };
        existing[scoreName] += matches;
        scoredById.set(doc.id, existing);
        return true;
      };

      const mergeSnapshot = (
        snap: QuerySnapshot,
        requested: Set<string>,
        fieldName: "tokenHashes" | "semanticHashes",
        scoreName: "tokenMatches" | "semanticMatches",
      ) => {
        for (const doc of snap.docs) {
          chunkCache.set(doc.id, doc);
          mergeChunkDoc(doc, requested, fieldName, scoreName);
        }
      };

      const mergePostingHits = async (
        hashes: string[],
        kind: "token" | "semantic",
        fieldName: "tokenHashes" | "semanticHashes",
        scoreName: "tokenMatches" | "semanticMatches",
      ): Promise<Set<string>> => {
        const matchedHashes = new Set<string>();
        if (hashes.length === 0) return matchedHashes;
        const postingKeys = hashes.map((hash) => `${kind}_${hash}`);
        let postingQuery = db.collection(`users/${uid}/cloud_search_postings`).where("postingKey", "in", postingKeys);
        if (provider) postingQuery = postingQuery.where("provider", "==", provider);
        const postingSnaps = await postingQuery.limit(500).get();
        const chunkIDs = new Set<string>();
        const requested = new Set(hashes);
        for (const postingSnap of postingSnaps.docs) {
          const data = postingSnap.data();
          if (!data || data.kind !== kind || typeof data.hash !== "string") continue;
          if (!requested.has(data.hash)) continue;
          if (typeof data.chunkID === "string" && chunkIDs.size < 500) {
            chunkIDs.add(data.chunkID);
          }
        }
        if (chunkIDs.size === 0) return matchedHashes;
        const missingRefs = Array.from(chunkIDs)
          .filter((chunkID) => !chunkCache.has(chunkID))
          .map((chunkID) => db.doc(`users/${uid}/cloud_search_chunks/${chunkID}`));
        if (missingRefs.length > 0) {
          const chunkSnaps = await db.getAll(...missingRefs);
          for (const chunkSnap of chunkSnaps) {
            chunkCache.set(chunkSnap.id, chunkSnap);
          }
        }
        for (const chunkID of chunkIDs) {
          const chunkSnap = chunkCache.get(chunkID);
          if (chunkSnap) {
            if (mergeChunkDoc(chunkSnap, requested, fieldName, scoreName)) {
              const hashesOnChunk = Array.isArray(chunkSnap.get(fieldName))
                ? chunkSnap.get(fieldName).filter((hash: unknown): hash is string => typeof hash === "string")
                : [];
              for (const hash of hashesOnChunk) {
                if (requested.has(hash)) matchedHashes.add(hash);
              }
            }
          }
        }
        return matchedHashes;
      };

      const [tokenPostingMatchedHashes, semanticPostingMatchedHashes] = await Promise.all([
        mergePostingHits(tokenHashes, "token", "tokenHashes", "tokenMatches"),
        mergePostingHits(semanticHashes, "semantic", "semanticHashes", "semanticMatches"),
      ]);

      const tokenFallbackHashes = cloudSearchFallbackHashes(tokenHashes, tokenPostingMatchedHashes);
      if (tokenFallbackHashes.length > 0) {
        let tokenQuery = chunksRef.where("tokenHashes", "array-contains-any", tokenFallbackHashes);
        if (provider) tokenQuery = tokenQuery.where("provider", "==", provider);
        const tokenSnap = await tokenQuery.limit(250).get();
        mergeSnapshot(tokenSnap, new Set(tokenFallbackHashes), "tokenHashes", "tokenMatches");
      }

      const semanticFallbackHashes = cloudSearchFallbackHashes(semanticHashes, semanticPostingMatchedHashes);
      if (semanticFallbackHashes.length > 0) {
        let semanticQuery = chunksRef.where("semanticHashes", "array-contains-any", semanticFallbackHashes);
        if (provider) semanticQuery = semanticQuery.where("provider", "==", provider);
        const semanticSnap = await semanticQuery.limit(250).get();
        mergeSnapshot(semanticSnap, new Set(semanticFallbackHashes), "semanticHashes", "semanticMatches");
      }

      const scored = Array.from(scoredById.values())
        .filter((item) => item.tokenMatches > 0 || item.semanticMatches > 0)
        .sort((a, b) => {
          const aScore = a.tokenMatches * 2 + a.semanticMatches;
          const bScore = b.tokenMatches * 2 + b.semanticMatches;
          return bScore - aScore || Number(a.data.ordinal ?? 0) - Number(b.data.ordinal ?? 0);
        });

      const hits: Array<Record<string, unknown>> = [];
      const seenDocuments = new Set<string>();
      for (const item of scored) {
        const documentID = typeof item.data.documentID === "string" ? item.data.documentID : "";
        if (!documentID || seenDocuments.has(documentID)) continue;
        const docSnap = await db.doc(`users/${uid}/cloud_search_documents/${documentID}`).get();
        if (!docSnap.exists) continue;
        const docData = docSnap.data() ?? {};
        if (docData.bodyHash !== item.data.bodyHash || docData.storagePath !== item.data.storagePath) continue;
        seenDocuments.add(documentID);
        hits.push({
          id: item.id,
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
          score: Math.min(
            1,
            (item.tokenMatches * 2 + item.semanticMatches) /
              Math.max(1, tokenHashes.length * 2 + semanticHashes.length),
          ),
          tokenScore: tokenHashes.length > 0 ? item.tokenMatches / tokenHashes.length : 0,
          semanticScore: semanticHashes.length > 0 ? item.semanticMatches / semanticHashes.length : 0,
          matchKind:
            item.tokenMatches > 0 && item.semanticMatches > 0
              ? "hybrid"
              : item.semanticMatches > 0
                ? "semantic"
                : "token",
          tokenHashVersion: item.data.tokenHashVersion ?? 1,
          semanticHashVersion: item.data.semanticHashVersion ?? 0,
          indexVersion: item.data.indexVersion ?? 1,
        });
        if (hits.length >= limit) break;
      }
      return { hits };
    },
  ),
);

// ---------------------------------------------------------------------------
// Callable: faceted conversation cockpit query (zero-knowledge bodies stay sealed)
// ---------------------------------------------------------------------------

/**
 * Faceted, paginated query over a paid user's encrypted session-log manifests. Filters and sorts
 * run only on operational cockpit facets (provider, model, device, source, token/cost totals,
 * timing); project/path/title/body search uses `searchEncryptedConversationIndex` so the client
 * sends keyed hashes and decrypts result labels locally. Aggregates (count + cost + token sums)
 * are computed with Firestore aggregation when an index is available, and degrade to `null` rather
 * than failing the page when one is missing.
 */
export const queryConversations = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "queryConversations",
    async (
      request: CallableRequest<{
        providers?: unknown;
        models?: unknown;
        deviceId?: unknown;
        sourceType?: unknown;
        dateFrom?: unknown;
        dateTo?: unknown;
        sort?: unknown;
        direction?: unknown;
        limit?: unknown;
        cursorDocId?: unknown;
        includeAggregates?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before querying conversations.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarProEntitlement(uid);

      const data = request.data ?? {};

      // Equality facets. providers/models may be multi-valued (Firestore `in`, capped at 30), but
      // only one `in` clause is allowed per query, so reject the both-multi case with guidance.
      const providers = data.providers == null ? [] : requireBoundedStringArray(data.providers, "providers", 20, 80);
      const models = data.models == null ? [] : requireBoundedStringArray(data.models, "models", 20, 120);
      const deviceId = boundedTrimmedString(data.deviceId, "deviceId", 200, false);
      const sourceType = boundedTrimmedString(data.sourceType, "sourceType", 80, false);

      const { providerInClause, modelInClause } = assertConversationFacetCombination(providers, models);

      const dateFrom = optionalISODateString(data.dateFrom, "dateFrom");
      const dateTo = optionalISODateString(data.dateTo, "dateTo");
      const hasDateRange = Boolean(dateFrom || dateTo);

      // A range filter must lead the order-by, so a date window forces a startTime sort.
      const requestedSort = boundedTrimmedString(data.sort, "sort", 32, false);
      const sort = resolveConversationSort(requestedSort, hasDateRange, data.direction);

      const limit = requireBoundedNumber(data.limit ?? 30, "limit", 1, 100);
      const includeAggregates = data.includeAggregates !== false;

      const logsRef = db.collection(`users/${uid}/session_logs`);
      const filtered: Query = applyConversationFacetFilters(logsRef, {
        providers,
        models,
        providerInClause,
        modelInClause,
        deviceId,
        sourceType,
        dateFrom,
        dateTo,
      });

      // Page query: stable order with a document-id tiebreaker so the cursor never skips or repeats.
      let pageQuery: Query = buildConversationPageQuery(filtered, sort);

      if (data.cursorDocId != null) {
        const cursorDocId = safeCloudDocumentID(data.cursorDocId, "cursorDocId");
        const cursorSnap = await logsRef.doc(cursorDocId).get();
        if (cursorSnap.exists) {
          pageQuery = pageQuery.startAfter(cursorSnap);
        }
      }

      let pageSnap: QuerySnapshot;
      try {
        pageSnap = await pageQuery.limit(limit).get();
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        if (/index/iu.test(message)) {
          throw new HttpsError(
            "failed-precondition",
            "This conversation filter needs a Firestore index that is still building. Try again shortly or narrow the filters.",
          );
        }
        throw error;
      }

      const rows = pageSnap.docs.map((doc) => mapSessionLogManifestRow(doc.id, doc.data()));

      const nextCursor = pageSnap.size === limit ? (pageSnap.docs[pageSnap.docs.length - 1]?.id ?? null) : null;

      let aggregates: { count: number; totalCostUSD: number; totalTokens: number } | null = null;
      if (includeAggregates) {
        try {
          const aggregateSnap = await filtered
            .aggregate({
              count: AggregateField.count(),
              totalCostUSD: AggregateField.sum("costUSD"),
              totalTokens: AggregateField.sum("totalTokens"),
            })
            .get();
          const aggData = aggregateSnap.data();
          aggregates = {
            count: Number(aggData.count ?? 0),
            totalCostUSD: Number(aggData.totalCostUSD ?? 0),
            totalTokens: Number(aggData.totalTokens ?? 0),
          };
        } catch {
          // Aggregation needs the same indexes as the filtered query; if one is still building we
          // return the page without rollups rather than failing the whole request.
          aggregates = null;
        }
      }

      return {
        rows,
        nextCursor,
        sort: sort.sortField,
        direction: sort.direction,
        aggregates,
      };
    },
  ),
);
