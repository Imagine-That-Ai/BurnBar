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
 * ciphertext INLINE (no Cloud Storage coupling), and is idempotent by `dedupHash`
 * (unchanged chunks are skipped).
 *
 * B-SEC-2 — plaintext metadata side channels (now FLAG-DAY ENFORCED, privacy-
 * leak-remediation-2026-06-02 §3). Earlier revisions persisted three plaintext
 * side channels per vector: `contentHash` (SHA-256 of the chunk plaintext — lets
 * a curious server confirm a *guessed* plaintext by hashing it), the real
 * `sourcePath` (repo file paths), and the cleartext `sourceSlug`. The write path
 * now REQUIRES the vault-keyed replacements and REJECTS the cleartext ones:
 *   - dedup/idempotency uses `dedupHash`, a VAULT-KEYED HMAC the device computes
 *     (HKDF-derive a per-user dedup key from the vault key, then HMAC the
 *     plaintext) — REQUIRED. Two members committing the same plaintext therefore
 *     produce DIFFERENT stored hashes, and the server can no longer confirm a
 *     guess by hashing candidate plaintext (it lacks the key). The legacy
 *     cleartext `contentHash` is no longer accepted. See `dedupHashVersion`.
 *   - the cloaked embedding (`cloakedVector`) is REQUIRED — a raw uncloaked
 *     `embedding` is rejected.
 *   - `sourcePath` is dropped server-side — it already lives inside the
 *     AES-256-GCM `sealedMetadata` blob (the device seals `source_path` there;
 *     see PensieveKnowledgeChunker.prepareBatch), so the cleartext column was a
 *     pure duplicate leak.
 *   - the filter key is `slugHmac` (a vault-keyed HMAC of the slug the device
 *     sends), REQUIRED, instead of the cleartext `sourceSlug`.
 * Existing legacy v0 rows remain readable until the device re-ingests each
 * source (forced by an `embeddingModelVersion`/`dedupHashVersion` bump). No
 * server-side backfill exists — the server never holds the vault key.
 * `sourceKind` (one of three coarse buckets) and `byteCount` (a length) remain
 * cleartext as ACCEPTED leakage — they are server-side filter / cap inputs and
 * carry no content; see docs/pensieve-leakage-analysis.md and docs/PENSIEVE.md.
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
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const KNOWLEDGE_VECTOR_DIM = 384;
const MAX_CHUNK_BYTES = 64 * 1024; // generous per-chunk plaintext ceiling
const MAX_BATCH_VECTORS = 800;
const SOURCE_KINDS = new Set(["repo_docs", "notes", "chat_memory"]);

/**
 * Stamped onto every row so old (legacy v0) rows stay distinguishable from the
 * vault-keyed v1 rows and a forced re-ingestion can target the laggards.
 *   - 0 — legacy: `dedupHash` held the cleartext SHA-256 of the plaintext (a
 *         confirm-the-guess side channel). The WRITE path no longer produces v0
 *         rows — the version is retained only so existing legacy rows remain
 *         readable until the device re-ingests them.
 *   - 1 — vault-keyed: `dedupHash` is the device's vault-keyed HMAC(plaintext)
 *         and `slugHmac` is the vault-keyed HMAC(slug); no cleartext hash/path.
 *
 * FLAG-DAY ENFORCEMENT (privacy-leak-remediation-2026-06-02 §3, Option A): the
 * device derivation (PensieveKnowledgeChunker + the Node shim) ships in the same
 * release that flips this write path to REQUIRE the vault-keyed `dedupHash` and
 * `cloakedVector`; not-yet-updated clients sending a cleartext `contentHash`/raw
 * `embedding` are now REJECTED. Existing legacy v0 rows stay readable until the
 * device re-ingests each source (forced by bumping `embeddingModelVersion`/
 * `dedupHashVersion`), which rewrites them at v1. There is no server-side
 * backfill — the server never holds the vault key.
 */
const DEDUP_HASH_VERSION_LEGACY_CLEARTEXT = 0;
const DEDUP_HASH_VERSION_VAULT_HMAC = 1;

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
  region: FUNCTIONS_REGION,
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

/**
 * Validate the on-device-cloaked embedding: exactly KNOWLEDGE_VECTOR_DIM finite
 * numbers. The caller passes ONLY `raw.cloakedVector` (privacy-leak-remediation-
 * 2026-06-02 §3) — the legacy uncloaked `embedding` field is no longer accepted,
 * so a not-yet-updated client that sends a raw embedding is rejected (the field
 * is simply absent here, producing the "must be a 384-dimension array" error).
 */
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
 * Resolve the vault-keyed dedup hash for one vector. The device sends
 * `dedupHash` = HMAC(plaintext) under an HKDF-derived per-user dedup key, so the
 * server stores a hash it cannot recompute from a guessed plaintext, and two
 * members storing the same plaintext get different hashes.
 *
 * FLAG-DAY (privacy-leak-remediation-2026-06-02 §3): the vault-keyed `dedupHash`
 * is now REQUIRED. The legacy cleartext `contentHash` (a confirm-the-guess
 * SHA-256 oracle) is no longer accepted as a fallback — a not-yet-updated client
 * that omits `dedupHash` is rejected. Always stamped v1.
 */
function resolveDedupHash(
  raw: Record<string, unknown>,
  fieldPrefix: string,
): { dedupHash: string; dedupHashVersion: number } {
  return {
    dedupHash: requireHexDigest(raw.dedupHash, `${fieldPrefix}.dedupHash`),
    dedupHashVersion: DEDUP_HASH_VERSION_VAULT_HMAC,
  };
}

/**
 * commitKnowledgeBatch — store a batch of cloaked + sealed knowledge chunks.
 * The server never decrypts; it enforces the tier chunk/byte caps and is
 * idempotent by `dedupHash`. Returns { ok, written, skipped, tier, chunkCount }.
 */
export const commitKnowledgeBatch = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler(
    "commitKnowledgeBatch",
    async (
      request: CallableRequest<{
        sourceSlug?: unknown;
        slugHmac?: unknown;
        vectors?: unknown;
        embeddingModelVersion?: unknown;
        deviceId?: unknown;
      }>,
    ) => {
      const uid = requireUid(request);
      await assertActiveBurnBarCloudProEntitlement(uid);

      // Document-id key for the per-source manifest (a slug is a safe doc id, the
      // HMAC is not necessarily). The HMAC is the SEARCH/DELETE filter key; the
      // slug stays out of the per-vector rows (B-SEC-2).
      const sourceSlug = safeCloudDocumentID(request.data.sourceSlug, "sourceSlug");
      // Vault-keyed HMAC(slug) the device computes; the only slug-derived value
      // stored on each vector. REQUIRED on the write path (privacy-leak-
      // remediation-2026-06-02 §3) — a cleartext slug is no longer stored on the
      // per-vector rows, so a not-yet-updated client that omits it is rejected.
      const slugHmac = requireHexDigest(request.data.slugHmac, "slugHmac");
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
      // No `sourcePath` here on purpose (B-SEC-2): the real path lives only inside
      // the sealed metadata blob, so we never re-accept a cleartext copy to store.
      const validated = vectors.map((raw, i) => {
        const { dedupHash, dedupHashVersion } = resolveDedupHash(raw, `vectors[${i}]`);
        return {
          // Prefer an explicit device id; else the keyed dedupHash (B-SEC-2 — a
          // keyed value, not a plaintext SHA-256). `vectorId` is only an opaque
          // idempotency doc id; with v1 hashes it no longer confirms a guess.
          vectorId: safeCloudDocumentID(raw.vectorId ?? dedupHash, `vectors[${i}].vectorId`),
          // ONLY the cloaked vector is accepted — a raw `embedding` is rejected
          // (privacy-leak-remediation-2026-06-02 §3): the server must never store
          // an uncloaked embedding it could invert.
          embedding: requireCloakedVector(raw.cloakedVector, `vectors[${i}].cloakedVector`),
          sealedCiphertext: requireSealedText(raw.sealedCiphertext ?? raw.ciphertext, `vectors[${i}].sealedCiphertext`),
          sealedMetadata: requireSealedText(raw.sealedMetadata, `vectors[${i}].sealedMetadata`),
          dedupHash,
          dedupHashVersion,
          sourceKind: requireSourceKind(raw.sourceKind, `vectors[${i}].sourceKind`),
          chunkIndex: requireBoundedNumber(raw.chunkIndex, `vectors[${i}].chunkIndex`, 0, 1_000_000),
          byteCount: requireBoundedNumber(raw.byteCount, `vectors[${i}].byteCount`, 0, MAX_CHUNK_BYTES),
        };
      });

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
        // Idempotent skip: compare the stored `dedupHash`. Both legacy v0 rows
        // and vault-keyed v1 rows store it under `dedupHash`, so the cleartext
        // `contentHash` oracle is no longer read here (privacy-leak-remediation-
        // 2026-06-02 §3). A pre-`dedupHash` ancient row simply re-writes once.
        const priorDedupHash = priorExists ? prior?.get("dedupHash") : undefined;
        if (priorExists && priorDedupHash === v.dedupHash) {
          skipped += 1; // unchanged chunk — idempotent no-op
          continue;
        }
        if (!priorExists) creates += 1;
        bytesDelta += v.byteCount - (priorExists ? Number(prior?.get("byteCount") ?? 0) : 0);
        const docData = {
          uid,
          vectorId: v.vectorId,
          // Vault-keyed HMAC(slug) — the search/delete filter key (B-SEC-2). No
          // cleartext `sourceSlug`/`sourcePath` is stored: the path is sealed.
          slugHmac,
          sourceKind: v.sourceKind,
          chunkIndex: v.chunkIndex,
          // Vault-keyed HMAC(plaintext) (or a legacy v0 cleartext SHA-256 for
          // not-yet-updated clients — see dedupHashVersion).
          dedupHash: v.dedupHash,
          dedupHashVersion: v.dedupHashVersion,
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
      // The manifest is intentionally slug-keyed (it is the user's own source
      // registry, read back by configureKnowledgeSource); the per-vector rows —
      // the cross-tenant-joinable surface B-SEC-2 targets — carry only `slugHmac`.
      writes.push((batch) =>
        batch.set(
          db.doc(`users/${uid}/knowledge_sync_manifests/${sourceSlug}`),
          stripUndefinedObject({
            uid,
            sourceSlug,
            slugHmac,
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
  wrapCallableHandler(
    "deleteKnowledgeSource",
    async (request: CallableRequest<{ sourceSlug?: unknown; slugHmac?: unknown }>) => {
      const uid = requireUid(request);
      await assertActiveBurnBarCloudProEntitlement(uid);
      const sourceSlug = safeCloudDocumentID(request.data.sourceSlug, "sourceSlug");
      const coll = db.collection(`users/${uid}/cloud_search_knowledge`);

      // B-SEC-2 rows are filter-keyed by `slugHmac` (not the cleartext slug).
      // Resolve it from the device (preferred) or the manifest, then also sweep
      // any legacy `sourceSlug`-keyed rows so pre-B-SEC-2 sources fully delete.
      const manifestRef = db.doc(`users/${uid}/knowledge_sync_manifests/${sourceSlug}`);
      const slugHmac =
        request.data.slugHmac !== undefined
          ? requireHexDigest(request.data.slugHmac, "slugHmac")
          : ((await manifestRef.get()).get("slugHmac") as string | undefined);

      let deleted = 0;
      if (slugHmac) {
        deleted += await deleteQueryInBatches(coll.where("slugHmac", "==", slugHmac));
      }
      deleted += await deleteQueryInBatches(coll.where("sourceSlug", "==", sourceSlug));
      await manifestRef.delete();
      return { ok: true, deleted };
    },
  ),
);

/** Pure helpers exposed for unit testing (validators + tier table). */
export const __testing__ = {
  PENSIEVE_LIMITS,
  KNOWLEDGE_VECTOR_DIM,
  MAX_CHUNK_BYTES,
  // Retained so existing legacy rows stay classifiable; the write path no longer
  // produces v0 rows (privacy-leak-remediation-2026-06-02 §3).
  DEDUP_HASH_VERSION_LEGACY_CLEARTEXT,
  DEDUP_HASH_VERSION_VAULT_HMAC,
  requireSourceKind,
  requireCloakedVector,
  resolveDedupHash,
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
