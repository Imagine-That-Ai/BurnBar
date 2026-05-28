/**
 * @fileoverview Encrypted session logs, cloud search, and project memory callables
 */

import { Timestamp } from "firebase-admin/firestore";
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
import type { DocumentData, DocumentSnapshot, QuerySnapshot, WriteBatch } from "firebase-admin/firestore";
import type { ProjectMemorySnapshotDoc } from "../types.js";
import { stripUndefinedObject } from "../guards.js";
import { wrapCallableHandler } from "../logging.js";

// ---------------------------------------------------------------------------
// Callable: encrypted hosted session logs + cloud search
// ---------------------------------------------------------------------------

export const beginEncryptedSessionBlobUpload = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("beginEncryptedSessionBlobUpload", async (
    request: CallableRequest<{
      documentID?: unknown;
      bodyHash?: unknown;
      encryptedByteCount?: unknown;
      contentType?: unknown;
    }>
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
      getConfig().encryptedSessionBlobMaxBytes
    );
    const contentType =
      boundedTrimmedString(request.data.contentType, "contentType", 128, false) ??
      "application/octet-stream";
    if (contentType !== "application/octet-stream") {
      throw new HttpsError("invalid-argument", "encrypted session blobs must use application/octet-stream.");
    }

    const storagePath = `users/${uid}/session_logs/${documentID}/bodies/${bodyHash}.json.aesgcm`;
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
    const [uploadURL] = await getStorage()
      .bucket()
      .file(storagePath)
      .getSignedUrl({
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
  })
);

export const getEncryptedSessionBlobDownloadUrl = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("getEncryptedSessionBlobDownloadUrl", async (
    request: CallableRequest<{
      storagePath?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before reading session logs.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarProEntitlement(uid);
    const storagePath = boundedTrimmedString(request.data.storagePath, "storagePath", 1024, true);
    assertUserStoragePath(uid, storagePath);
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
    const [downloadURL] = await getStorage()
      .bucket()
      .file(storagePath)
      .getSignedUrl({
        version: "v4",
        action: "read",
        expires: expiresAt,
      });
    return { downloadURL, expiresAt: expiresAt.toISOString() };
  }
));

export const commitEncryptedSearchIndexBatch = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("commitEncryptedSearchIndexBatch", async (
    request: CallableRequest<{
      documents?: unknown;
      chunks?: unknown;
      indexVersion?: unknown;
      deviceId?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before syncing the search index.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarProEntitlement(uid);

    const documents = requireRecordArray(request.data.documents, "documents", 50);
    const chunks = requireRecordArray(request.data.chunks, "chunks", 300);
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
      const doc = {
        uid,
        documentID,
        deviceId,
        sourceKind: boundedTrimmedString(raw.sourceKind, "document.sourceKind", 64, true),
        sourceID: boundedTrimmedString(raw.sourceID, "document.sourceID", 512, true),
        sourceVersionID: boundedTrimmedString(raw.sourceVersionID, "document.sourceVersionID", 512, false),
        provider: boundedTrimmedString(raw.provider, "document.provider", 80, false),
        projectName: boundedTrimmedString(raw.projectName, "document.projectName", 512, false),
        bodyHash: requireHexDigest(raw.bodyHash, "document.bodyHash"),
        storagePath,
        sealedTitle: requireSealedText(raw.sealedTitle, "document.sealedTitle"),
        sealedBodyPreview: requireSealedText(raw.sealedBodyPreview, "document.sealedBodyPreview"),
        byteCount: requireBoundedNumber(raw.byteCount, "document.byteCount", 0, getConfig().encryptedSessionBlobMaxBytes),
        encryptedByteCount: requireBoundedNumber(
          raw.encryptedByteCount,
          "document.encryptedByteCount",
          1,
          getConfig().encryptedSessionBlobMaxBytes
        ),
        indexVersion,
        tokenHashVersion: 1,
        semanticHashVersion: 1,
        commitID,
        updatedAt: now,
        schemaVersion: 1,
      };
      await assertEncryptedSessionBlobObject({
        uid,
        storagePath: doc.storagePath,
        documentID,
        bodyHash: doc.bodyHash,
        encryptedByteCount: doc.encryptedByteCount,
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
        throw new HttpsError("invalid-argument", "chunk.semanticHashes are required for encrypted semantic search indexes.");
      }
      const chunk = {
        uid,
        chunkID,
        documentID,
        deviceId,
        sourceKind: boundedTrimmedString(raw.sourceKind, "chunk.sourceKind", 64, true),
        sourceID: boundedTrimmedString(raw.sourceID, "chunk.sourceID", 512, true),
        provider: boundedTrimmedString(raw.provider, "chunk.provider", 80, false),
        projectName: boundedTrimmedString(raw.projectName, "chunk.projectName", 512, false),
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
      for (const hash of semanticHashes) {
        const postingKey = `semantic_${hash}`;
        const edgeID = `${postingKey}_${chunkID}`;
        writes.push((batch) => batch.set(
          postingsRef.doc(edgeID),
          stripUndefinedObject({
            uid,
            postingKey,
            edgeID,
            kind: "semantic",
            hash,
            chunkID,
            documentID,
            sourceKind: chunk.sourceKind,
            sourceID: chunk.sourceID,
            provider: chunk.provider,
            projectName: chunk.projectName,
            ordinal: chunk.ordinal,
            bodyHash: chunk.bodyHash,
            storagePath: chunk.storagePath,
            sealedSnippet: chunk.sealedSnippet,
            updatedAt: now,
            indexVersion,
            commitID,
            schemaVersion: 1,
          }),
          { merge: true }
        ));
        writeCount += 1;
      }
    }

    writes.push((batch) => batch.set(
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
      { merge: true }
    ));
    writeCount += 1;

    await commitBatchedWrites(writes);
    return { ok: true, writeCount, documentCount: documents.length, chunkCount: chunks.length, commitID };
  }
));

export const commitEncryptedProjectMemorySnapshot = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("commitEncryptedProjectMemorySnapshot", async (
    request: CallableRequest<{
      projectSlug?: unknown;
      projectDisplayName?: unknown;
      contentHash?: unknown;
      sourceSessionCount?: unknown;
      sourceConversationCount?: unknown;
      generatedAt?: unknown;
      freshness?: unknown;
      visualKinds?: unknown;
      sealedSnapshot?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before syncing Project Memory.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarProEntitlement(uid);

    const projectSlug = requiredIdentifier(request.data.projectSlug, "projectSlug");
    const projectDisplayName = boundedTrimmedString(
      request.data.projectDisplayName,
      "projectDisplayName",
      240,
      true
    );
    const contentHash = requireHexDigest(request.data.contentHash, "contentHash");
    const sourceSessionCount = requireBoundedNumber(
      request.data.sourceSessionCount ?? 0,
      "sourceSessionCount",
      0,
      1_000_000
    );
    const sourceConversationCount = requireBoundedNumber(
      request.data.sourceConversationCount ?? 0,
      "sourceConversationCount",
      0,
      1_000_000
    );
    const generatedAt = optionalISODateString(request.data.generatedAt, "generatedAt") ?? nowISO();
    const freshness = parseProjectMemoryFreshness(request.data.freshness);
    const visualKinds = request.data.visualKinds == null
      ? []
      : requireBoundedStringArray(request.data.visualKinds, "visualKinds", 24, 80);
    const sealedSnapshot = requireCloudVaultBlobEnvelope(request.data.sealedSnapshot, "sealedSnapshot");
    const updatedAt = nowISO();

    const doc: ProjectMemorySnapshotDoc = {
      projectSlug,
      projectDisplayName,
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
      schemaVersion: 1,
      updatedAt,
    };

    await db.doc(`users/${uid}/project_memory_snapshots/${projectSlug}`).set(stripUndefinedObject(doc), { merge: true });
    return {
      ok: true,
      projectSlug,
      contentHash,
      generatedAt,
      updatedAt,
    };
  }
));

export const getEncryptedProjectMemorySnapshot = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("getEncryptedProjectMemorySnapshot", async (
    request: CallableRequest<{
      projectSlug?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before reading Project Memory.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarProEntitlement(uid);

    const projectSlug = requiredIdentifier(request.data.projectSlug, "projectSlug");
    const snap = await db.doc(`users/${uid}/project_memory_snapshots/${projectSlug}`).get();
    if (!snap.exists) {
      return { snapshot: null };
    }
    const data = snap.data() ?? {};
    return {
      snapshot: stripUndefinedObject({
        projectSlug: data.projectSlug ?? projectSlug,
        projectDisplayName: data.projectDisplayName,
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
  }
));

export const listEncryptedProjectMemorySnapshots = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("listEncryptedProjectMemorySnapshots", async (
    request: CallableRequest<{
      limit?: unknown;
    }>
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
      return stripUndefinedObject({
        projectSlug: data.projectSlug ?? doc.id,
        projectDisplayName: data.projectDisplayName,
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
  }
));

export const searchEncryptedConversationIndex = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("searchEncryptedConversationIndex", async (
    request: CallableRequest<{
      tokenHashes?: unknown;
      semanticHashes?: unknown;
      limit?: unknown;
      provider?: unknown;
    }>
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
    const stateSnap = await db
      .collection(`users/${uid}/cloud_search_index_state`)
      .limit(100)
      .get();
    const activeCommitIDs = new Set(
      stateSnap.docs
        .map((doc) => doc.get("activeCommitID"))
        .filter((commitID): commitID is string => typeof commitID === "string" && /^[a-f0-9]{32}$/u.test(commitID))
    );

    const mergeChunkDoc = (
      doc: DocumentSnapshot,
      requested: Set<string>,
      fieldName: "tokenHashes" | "semanticHashes",
      scoreName: "tokenMatches" | "semanticMatches"
    ) => {
      if (!doc.exists) return;
      const data = doc.data() ?? {};
      if (provider && data.provider !== provider) return;
      const chunkCommitID = typeof data.commitID === "string" ? data.commitID : undefined;
      if (chunkCommitID) {
        if (!activeCommitIDs.has(chunkCommitID)) return;
      } else if (activeCommitIDs.size > 0) {
        return;
      }
      const hashes = Array.isArray(data[fieldName])
        ? data[fieldName].filter((hash): hash is string => typeof hash === "string")
        : [];
      const matches = hashes.reduce((sum, hash) => sum + (requested.has(hash) ? 1 : 0), 0);
      if (matches <= 0) return;
      const existing = scoredById.get(doc.id) ?? {
        id: doc.id,
        data,
        tokenMatches: 0,
        semanticMatches: 0,
      };
      existing[scoreName] += matches;
      scoredById.set(doc.id, existing);
    };

    const mergeSnapshot = (
      snap: QuerySnapshot,
      requested: Set<string>,
      fieldName: "tokenHashes" | "semanticHashes",
      scoreName: "tokenMatches" | "semanticMatches"
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
      scoreName: "tokenMatches" | "semanticMatches"
    ) => {
      if (hashes.length === 0) return;
      const postingKeys = hashes.map((hash) => `${kind}_${hash}`);
      let postingQuery = db
        .collection(`users/${uid}/cloud_search_postings`)
        .where("postingKey", "in", postingKeys);
      if (provider) postingQuery = postingQuery.where("provider", "==", provider);
      const postingSnaps = await postingQuery.limit(500).get();
      const chunkIDs = new Set<string>();
      for (const postingSnap of postingSnaps.docs) {
        const data = postingSnap.data();
        if (!data || data.kind !== kind || typeof data.hash !== "string") continue;
        if (!hashes.includes(data.hash)) continue;
        if (typeof data.chunkID === "string" && chunkIDs.size < 500) {
          chunkIDs.add(data.chunkID);
        }
      }
      if (chunkIDs.size === 0) return;
      const missingRefs = Array.from(chunkIDs)
        .filter((chunkID) => !chunkCache.has(chunkID))
        .map((chunkID) => db.doc(`users/${uid}/cloud_search_chunks/${chunkID}`));
      if (missingRefs.length > 0) {
        const chunkSnaps = await db.getAll(...missingRefs);
        for (const chunkSnap of chunkSnaps) {
          chunkCache.set(chunkSnap.id, chunkSnap);
        }
      }
      const requested = new Set(hashes);
      for (const chunkID of chunkIDs) {
        const chunkSnap = chunkCache.get(chunkID);
        if (chunkSnap) {
          mergeChunkDoc(chunkSnap, requested, fieldName, scoreName);
        }
      }
    };

    await Promise.all([
      mergePostingHits(tokenHashes, "token", "tokenHashes", "tokenMatches"),
      mergePostingHits(semanticHashes, "semantic", "semanticHashes", "semanticMatches"),
    ]);

    if (tokenHashes.length > 0) {
      let tokenQuery = chunksRef.where("tokenHashes", "array-contains-any", tokenHashes);
      if (provider) tokenQuery = tokenQuery.where("provider", "==", provider);
      const tokenSnap = await tokenQuery.limit(250).get();
      mergeSnapshot(tokenSnap, new Set(tokenHashes), "tokenHashes", "tokenMatches");
    }

    if (semanticHashes.length > 0) {
      let semanticQuery = chunksRef.where("semanticHashes", "array-contains-any", semanticHashes);
      if (provider) semanticQuery = semanticQuery.where("provider", "==", provider);
      const semanticSnap = await semanticQuery.limit(250).get();
      mergeSnapshot(semanticSnap, new Set(semanticHashes), "semanticHashes", "semanticMatches");
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
        projectName: docData.projectName ?? item.data.projectName,
        sealedTitle: docData.sealedTitle,
        sealedSnippet: item.data.sealedSnippet,
        sealedBodyPreview: docData.sealedBodyPreview,
        storagePath: item.data.storagePath,
        bodyHash: item.data.bodyHash,
        score: Math.min(1, (item.tokenMatches * 2 + item.semanticMatches) / Math.max(1, tokenHashes.length * 2 + semanticHashes.length)),
        tokenScore: tokenHashes.length > 0 ? item.tokenMatches / tokenHashes.length : 0,
        semanticScore: semanticHashes.length > 0 ? item.semanticMatches / semanticHashes.length : 0,
        matchKind: item.tokenMatches > 0 && item.semanticMatches > 0 ? "hybrid" : item.semanticMatches > 0 ? "semantic" : "token",
        tokenHashVersion: item.data.tokenHashVersion ?? 1,
        semanticHashVersion: item.data.semanticHashVersion ?? 0,
        indexVersion: item.data.indexVersion ?? 1,
      });
      if (hits.length >= limit) break;
    }
    return { hits };
  }
));

