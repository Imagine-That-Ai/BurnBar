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
  cloudVaultAADContext,
  assertUserStoragePath,
  assertEncryptedSessionBlobObject,
  assertActiveBurnBarProEntitlement,
} from "./shared.js";
import { randomBytes } from "node:crypto";
import type { QuerySnapshot, WriteBatch, Query } from "firebase-admin/firestore";
import { stripUndefinedObject } from "../guards.js";
import { wrapCallableHandler } from "../logging.js";
import {
  applyConversationFacetFilters,
  assertConversationFacetCombination,
  buildConversationPageQuery,
  mapSessionLogManifestRow,
  resolveConversationSort,
} from "./conversationQuery.js";
import { buildCloudSearchPostingEdges } from "./encryptedSearchIndex.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

// Re-export relocated callables so existing `import ... from "./callables/encryptedSearch.js"`
// keeps resolving byte-identically. These were split out to keep every module under the
// 600-line cap (the search/scoring machinery and the project-memory callables moved verbatim).
export { searchEncryptedConversationIndex } from "./encryptedSearchQuery.js";
export {
  commitEncryptedProjectMemorySnapshot,
  getEncryptedProjectMemorySnapshot,
  listEncryptedProjectMemorySnapshots,
} from "./encryptedProjectMemory.js";

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
      const committedDocumentIDs: string[] = [];
      const writePaths = new Set<string>();

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
          bodyHashVersion: requireBoundedNumber(raw.bodyHashVersion ?? 0, "document.bodyHashVersion", 0, 100),
          storagePath,
          sealedTitle: requireSealedText(
            raw.sealedTitle,
            "document.sealedTitle",
            cloudVaultAADContext(uid, "cloud_search_documents", documentID, "sealedTitle"),
          ),
          sealedBodyPreview: requireSealedText(
            raw.sealedBodyPreview,
            "document.sealedBodyPreview",
            cloudVaultAADContext(uid, "cloud_search_documents", documentID, "sealedBodyPreview"),
          ),
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
        const docRef = documentsRef.doc(documentID);
        writes.push((batch) => batch.set(docRef, stripUndefinedObject(doc), { merge: true }));
        writePaths.add(docRef.path);
        writeCount += 1;
        committedDocumentIDs.push(documentID);
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
          contentHashVersion: requireBoundedNumber(raw.contentHashVersion ?? 0, "chunk.contentHashVersion", 0, 100),
          bodyHash: requireHexDigest(raw.bodyHash, "chunk.bodyHash"),
          bodyHashVersion: requireBoundedNumber(raw.bodyHashVersion ?? 0, "chunk.bodyHashVersion", 0, 100),
          storagePath,
          sealedSnippet: requireSealedText(
            raw.sealedSnippet,
            "chunk.sealedSnippet",
            cloudVaultAADContext(uid, "cloud_search_chunks", chunkID, "sealedSnippet"),
          ),
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
        const chunkRef = chunksRef.doc(chunkID);
        writes.push((batch) => batch.set(chunkRef, stripUndefinedObject(chunk), { merge: true }));
        writePaths.add(chunkRef.path);
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
            bodyHashVersion: chunk.bodyHashVersion,
            storagePath: chunk.storagePath,
            sealedSnippet: chunk.sealedSnippet,
            indexVersion,
            commitID,
            updatedAt: now,
          },
          tokenHashes,
          semanticHashes,
        })) {
          const postingRef = postingsRef.doc(edge.edgeID);
          writes.push((batch) => batch.set(postingRef, stripUndefinedObject(edge.data), { merge: true }));
          writePaths.add(postingRef.path);
          writeCount += 1;
        }
      }

      for (const documentID of committedDocumentIDs) {
        const [oldChunks, oldPostings] = await Promise.all([
          chunksRef.where("documentID", "==", documentID).get(),
          postingsRef.where("documentID", "==", documentID).get(),
        ]);
        for (const old of oldChunks.docs) {
          if (writePaths.has(old.ref.path)) continue;
          writes.push((batch) => batch.delete(old.ref));
          writeCount += 1;
        }
        for (const old of oldPostings.docs) {
          if (writePaths.has(old.ref.path)) continue;
          writes.push((batch) => batch.delete(old.ref));
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
