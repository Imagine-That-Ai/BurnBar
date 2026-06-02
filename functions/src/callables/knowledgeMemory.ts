/**
 * @fileoverview Pensieve knowledge-memory callables — the ingest/write side of
 * the E2EE per-member semantic memory.
 *
 * The device chunks, embeds (bge-small-en-v1.5), CLOAKS each vector with the
 * vault key, and AES-256-GCM-seals the chunk text + metadata, then calls
 * commitKnowledgeBatch. The server stores ONLY the cloaked vector + opaque
 * sealed envelopes (it never decrypts) at users/{uid}/cloud_search_knowledge,
 * with a per-vector embedding written as a Firestore VectorValue so the hosted
 * MCP (knowledge.ts) can run findNearest COSINE search per namespace.
 *
 * Mirrors commitEncryptedSearchIndexBatch (encryptedSearch.ts): same auth gate,
 * validators, batched-write, and stripUndefinedObject conventions. Differences:
 * gated on Cloud Pro (proMax-strict), enforces per-tier chunk/byte caps, stores
 * ciphertext INLINE (no Cloud Storage coupling), and is idempotent by
 * contentHash (unchanged chunks are skipped).
 */

import { Timestamp, FieldValue, AggregateField } from "firebase-admin/firestore";
import type { Query, WriteBatch } from "firebase-admin/firestore";
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
  requireSealedText,
  assertActiveBurnBarCloudProEntitlement,
  isActiveBurnBarUltraEntitlement,
  BURNBAR_ULTRA_ENTITLEMENT_ID as ULTRA_ENTITLEMENT_ID,
} from "./shared.js";
import { stripUndefinedObject } from "../guards.js";
import { wrapCallableHandler } from "../logging.js";
import { randomBytes } from "node:crypto";

const KNOWLEDGE_VECTOR_DIM = 384;
const MAX_CHUNK_BYTES = 64 * 1024; // generous per-chunk plaintext ceiling
const MAX_BATCH_VECTORS = 800;
const SOURCE_KINDS = new Set(["repo_docs", "notes", "chat_memory"]);

type PensieveTier = "pro" | "ultra";
export interface PensieveLimits {
  sources: number;
  chunks: number;
  bytes: number;
}

/** Per-tier hard caps (see the Pensieve plan's tier table). User-level, not per-source. */
export const PENSIEVE_LIMITS: Record<PensieveTier, PensieveLimits> = {
  pro: { sources: 3, chunks: 5_000, bytes: 25 * 1024 * 1024 },
  ultra: { sources: 15, chunks: 50_000, bytes: 250 * 1024 * 1024 },
};

const CALLABLE_OPTS = {
  region: "us-central1",
  enforceAppCheck: getConfig().enforceAppCheck,
  maxInstances: 100,
} as const;

/**
 * Resolve the member's Pensieve tier. Ultra mirrors proMax (so Cloud Pro gates
 * already passed); only the LIMIT lookup branches on the burnbar_ultra doc,
 * which is written solely by the reconciler (single writer) — so trusting
 * active + expiry here is safe.
 */
async function resolvePensieveTier(uid: string): Promise<PensieveTier> {
  const snap = await db.doc(`users/${uid}/entitlements/${ULTRA_ENTITLEMENT_ID}`).get();
  return isActiveBurnBarUltraEntitlement(snap.data()) ? "ultra" : "pro";
}

function requireSourceKind(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, 64, true);
  if (!SOURCE_KINDS.has(value)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be one of: ${[...SOURCE_KINDS].join(", ")}.`);
  }
  return value;
}

/** Validate the on-device-cloaked embedding: exactly KNOWLEDGE_VECTOR_DIM finite numbers. */
function requireCloakedVector(raw: unknown, fieldName: string): number[] {
  if (!Array.isArray(raw) || raw.length !== KNOWLEDGE_VECTOR_DIM) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a ${KNOWLEDGE_VECTOR_DIM}-dimension array.`);
  }
  const vec = raw.map((v) => Number(v));
  if (vec.some((v) => !Number.isFinite(v))) {
    throw new HttpsError("invalid-argument", `${fieldName} must contain only finite numbers.`);
  }
  return vec;
}

function slugify(raw: string): string {
  const slug = raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/gu, "-")
    .replace(/^-+|-+$/gu, "")
    .slice(0, 120);
  return slug || randomBytes(8).toString("hex");
}

/** Delete every doc matched by `query`, in Firestore-batch-sized pages. */
async function deleteQueryInBatches(query: Query): Promise<number> {
  let deleted = 0;
  for (;;) {
    const snap = await query.limit(400).get();
    if (snap.empty) break;
    await commitBatchedWrites(snap.docs.map((doc) => (batch: WriteBatch) => batch.delete(doc.ref)));
    deleted += snap.size;
    if (snap.size < 400) break;
  }
  return deleted;
}

function requireUid(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to use Pensieve knowledge memory.");
  enforceAuthAndAppCheck(request, uid);
  return uid;
}

/**
 * commitKnowledgeBatch — store a batch of cloaked + sealed knowledge chunks.
 * The server never decrypts; it enforces the tier chunk/byte caps and is
 * idempotent by contentHash. Returns { ok, written, skipped, tier, chunkCount }.
 */
export const commitKnowledgeBatch = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler(
    "commitKnowledgeBatch",
    async (
      request: CallableRequest<{
        sourceSlug?: unknown;
        vectors?: unknown;
        embeddingModelVersion?: unknown;
        deviceId?: unknown;
      }>,
    ) => {
      const uid = requireUid(request);
      await assertActiveBurnBarCloudProEntitlement(uid);

      const sourceSlug = safeCloudDocumentID(request.data.sourceSlug, "sourceSlug");
      const embeddingModelVersion = boundedTrimmedString(
        request.data.embeddingModelVersion,
        "embeddingModelVersion",
        120,
        true,
      );
      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 256, false);
      const vectors = requireRecordArray(request.data.vectors, "vectors", MAX_BATCH_VECTORS);

      const tier = await resolvePensieveTier(uid);
      const limits = PENSIEVE_LIMITS[tier];
      const now = Timestamp.now();
      const commitID = randomBytes(16).toString("hex");
      const coll = db.collection(`users/${uid}/cloud_search_knowledge`);

      // Validate every item up front — a single bad item fails the whole batch.
      const validated = vectors.map((raw, i) => ({
        vectorId: safeCloudDocumentID(raw.vectorId ?? raw.contentHash, `vectors[${i}].vectorId`),
        embedding: requireCloakedVector(raw.cloakedVector ?? raw.embedding, `vectors[${i}].cloakedVector`),
        sealedCiphertext: requireSealedText(raw.sealedCiphertext ?? raw.ciphertext, `vectors[${i}].sealedCiphertext`),
        sealedMetadata: requireSealedText(raw.sealedMetadata, `vectors[${i}].sealedMetadata`),
        contentHash: requireHexDigest(raw.contentHash, `vectors[${i}].contentHash`),
        sourceKind: requireSourceKind(raw.sourceKind, `vectors[${i}].sourceKind`),
        sourcePath: boundedTrimmedString(raw.sourcePath, `vectors[${i}].sourcePath`, 512, false),
        chunkIndex: requireBoundedNumber(raw.chunkIndex, `vectors[${i}].chunkIndex`, 0, 1_000_000),
        byteCount: requireBoundedNumber(raw.byteCount, `vectors[${i}].byteCount`, 0, MAX_CHUNK_BYTES),
      }));

      // Pre-read existing docs: enables idempotent skip + accurate cap deltas.
      const refs = validated.map((v) => coll.doc(v.vectorId));
      const existingSnaps = refs.length ? await db.getAll(...refs) : [];
      const existingByID = new Map(existingSnaps.map((snap) => [snap.id, snap]));

      // Current user-level usage for the hard caps.
      const agg = await coll.aggregate({ n: AggregateField.count(), bytes: AggregateField.sum("byteCount") }).get();
      const existingCount = Number(agg.data().n ?? 0);
      const existingBytes = Number(agg.data().bytes ?? 0);

      let creates = 0;
      let bytesDelta = 0;
      let written = 0;
      let skipped = 0;
      const writes: Array<(batch: WriteBatch) => void> = [];

      for (const v of validated) {
        const prior = existingByID.get(v.vectorId);
        const priorExists = Boolean(prior?.exists);
        if (priorExists && prior?.get("contentHash") === v.contentHash) {
          skipped += 1; // unchanged chunk — idempotent no-op
          continue;
        }
        if (!priorExists) creates += 1;
        bytesDelta += v.byteCount - (priorExists ? Number(prior?.get("byteCount") ?? 0) : 0);
        const docData = {
          uid,
          vectorId: v.vectorId,
          sourceSlug,
          sourceKind: v.sourceKind,
          sourcePath: v.sourcePath,
          chunkIndex: v.chunkIndex,
          contentHash: v.contentHash,
          byteCount: v.byteCount,
          embedding: FieldValue.vector(v.embedding),
          embeddingModelVersion,
          sealedCiphertext: v.sealedCiphertext,
          sealedMetadata: v.sealedMetadata,
          deviceId,
          commitID,
          updatedAt: now,
          schemaVersion: 1,
        };
        writes.push((batch) => batch.set(coll.doc(v.vectorId), stripUndefinedObject(docData), { merge: true }));
        written += 1;
      }

      // Hard tier caps — throw before committing any write.
      if (existingCount + creates > limits.chunks) {
        throw new HttpsError(
          "failed-precondition",
          `Pensieve chunk limit reached (${limits.chunks} for ${tier}). Delete a source or upgrade to Ultra.`,
        );
      }
      if (existingBytes + bytesDelta > limits.bytes) {
        throw new HttpsError(
          "failed-precondition",
          `Pensieve storage limit reached (${Math.round(limits.bytes / (1024 * 1024))} MB for ${tier}). Delete a source or upgrade to Ultra.`,
        );
      }

      // Per-source manifest: increment counts + record sync health (no plaintext).
      writes.push((batch) =>
        batch.set(
          db.doc(`users/${uid}/knowledge_sync_manifests/${sourceSlug}`),
          stripUndefinedObject({
            uid,
            sourceSlug,
            embeddingModelVersion,
            chunkCount: FieldValue.increment(creates),
            byteCount: FieldValue.increment(bytesDelta),
            lastSyncAt: now,
            lastError: null,
            schemaVersion: 1,
          }),
          { merge: true },
        ),
      );

      await commitBatchedWrites(writes);
      return { ok: true, written, skipped, tier, chunkCount: existingCount + creates };
    },
  ),
);

/**
 * configureKnowledgeSource — register a knowledge source (repo docs / notes /
 * chat memory) and return its stable slug. Enforces the per-tier source cap for
 * NEW sources only. Returns { sourceSlug }.
 */
export const configureKnowledgeSource = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler(
    "configureKnowledgeSource",
    async (
      request: CallableRequest<{
        sourceKind?: unknown;
        rootPath?: unknown;
        repoInstallId?: unknown;
        globs?: unknown;
        sourceSlug?: unknown;
      }>,
    ) => {
      const uid = requireUid(request);
      await assertActiveBurnBarCloudProEntitlement(uid);

      const sourceKind = requireSourceKind(request.data.sourceKind, "sourceKind");
      const rootPath = boundedTrimmedString(request.data.rootPath, "rootPath", 1024, false);
      const repoInstallId = boundedTrimmedString(request.data.repoInstallId, "repoInstallId", 256, false);
      const requested =
        boundedTrimmedString(request.data.sourceSlug, "sourceSlug", 200, false) ?? rootPath ?? repoInstallId;
      const sourceSlug = safeCloudDocumentID(slugify(requested ?? randomBytes(8).toString("hex")), "sourceSlug");

      const manifestRef = db.doc(`users/${uid}/knowledge_sync_manifests/${sourceSlug}`);
      const existing = await manifestRef.get();
      if (!existing.exists) {
        const tier = await resolvePensieveTier(uid);
        const count = (await db.collection(`users/${uid}/knowledge_sync_manifests`).count().get()).data().count;
        if (count >= PENSIEVE_LIMITS[tier].sources) {
          throw new HttpsError(
            "failed-precondition",
            `Pensieve source limit reached (${PENSIEVE_LIMITS[tier].sources} for ${tier}). Delete a source or upgrade to Ultra.`,
          );
        }
      }

      await manifestRef.set(
        stripUndefinedObject({
          uid,
          sourceSlug,
          sourceKind,
          rootPath,
          repoInstallId,
          chunkCount: existing.exists ? (existing.get("chunkCount") ?? 0) : 0,
          byteCount: existing.exists ? (existing.get("byteCount") ?? 0) : 0,
          lastConfiguredAt: Timestamp.now(),
          schemaVersion: 1,
        }),
        { merge: true },
      );
      return { sourceSlug };
    },
  ),
);

/** deleteKnowledgeSource — drop all vectors for one source + its manifest. */
export const deleteKnowledgeSource = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("deleteKnowledgeSource", async (request: CallableRequest<{ sourceSlug?: unknown }>) => {
    const uid = requireUid(request);
    await assertActiveBurnBarCloudProEntitlement(uid);
    const sourceSlug = safeCloudDocumentID(request.data.sourceSlug, "sourceSlug");
    const deleted = await deleteQueryInBatches(
      db.collection(`users/${uid}/cloud_search_knowledge`).where("sourceSlug", "==", sourceSlug),
    );
    await db.doc(`users/${uid}/knowledge_sync_manifests/${sourceSlug}`).delete();
    return { ok: true, deleted };
  }),
);

/** Pure helpers exposed for unit testing (validators + tier table). */
export const __testing__ = {
  PENSIEVE_LIMITS,
  KNOWLEDGE_VECTOR_DIM,
  MAX_CHUNK_BYTES,
  requireSourceKind,
  requireCloakedVector,
  slugify,
};

/** purgeKnowledgeMemory — GDPR/delete: drop ALL of a member's knowledge + manifests. */
export const purgeKnowledgeMemory = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("purgeKnowledgeMemory", async (request: CallableRequest) => {
    const uid = requireUid(request);
    await assertActiveBurnBarCloudProEntitlement(uid);
    const deletedVectors = await deleteQueryInBatches(db.collection(`users/${uid}/cloud_search_knowledge`));
    const deletedManifests = await deleteQueryInBatches(db.collection(`users/${uid}/knowledge_sync_manifests`));
    return { ok: true, deletedVectors, deletedManifests };
  }),
);
