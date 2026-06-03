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
 * The dedup-v0 retirement is now COMPLETE: legacy v0 rows are unreachable by
 * recall (knowledgeSearch floors `dedupHashVersion == 1` and filters the new
 * `embeddingModelVersion` tag) and the commit idempotent-skip below treats any
 * stored `dedupHashVersion !== 1` as a non-match (it rewrites at v1). Stranded
 * v0 rows — orphaned because a re-ingest produces a NEW vault-keyed doc id and
 * cannot reach the old SHA-256-keyed doc — are DELETED by
 * `purgeLegacyKnowledgeVectors` (owner callable + daily onSchedule). The
 * cleartext-SHA-256 oracle therefore no longer exists in any served or queryable
 * row. No server-side backfill is needed for the re-seal — the server never
 * holds the vault key; the device re-ingests under the bumped model tag.
 * `sourceKind` (one of three coarse buckets) and `byteCount` (a length) remain
 * cleartext as ACCEPTED leakage — they are server-side filter / cap inputs and
 * carry no content; see docs/pensieve-leakage-analysis.md and docs/PENSIEVE.md.
 */

import { Timestamp, FieldValue, AggregateField } from "firebase-admin/firestore";
import type { Query, QueryDocumentSnapshot, WriteBatch } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";

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
import { logInfo, wrapCallableHandler } from "../logging.js";
import { randomBytes } from "node:crypto";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const KNOWLEDGE_VECTOR_DIM = 384;
const MAX_CHUNK_BYTES = 64 * 1024; // generous per-chunk plaintext ceiling
const MAX_BATCH_VECTORS = 800;
const SOURCE_KINDS = new Set(["repo_docs", "notes", "chat_memory"]);

/**
 * Stamped onto every row so old (legacy v0) rows stay distinguishable from the
 * vault-keyed v1 rows so the v0 purge can target them.
 *   - 0 — legacy: `dedupHash` held the cleartext SHA-256 of the plaintext (a
 *         confirm-the-guess side channel). The WRITE path no longer produces v0
 *         rows. This version is retained ONLY as the purge predicate; v0 rows
 *         are deleted by `purgeLegacyKnowledgeVectors` and never served
 *         (knowledgeSearch floors `dedupHashVersion == 1`, and the commit
 *         idempotent-skip below treats `dedupHashVersion !== 1` as a non-match).
 *   - 1 — vault-keyed: `dedupHash` is the device's vault-keyed HMAC(plaintext)
 *         and `slugHmac` is the vault-keyed HMAC(slug); no cleartext hash/path.
 *
 * FLAG-DAY ENFORCEMENT (privacy-leak-remediation-2026-06-02 §3, Option A): the
 * device derivation (PensieveKnowledgeChunker + the Node shim) ships in the same
 * release that flips this write path to REQUIRE the vault-keyed `dedupHash` and
 * `cloakedVector`; not-yet-updated clients sending a cleartext `contentHash`/raw
 * `embedding` are now REJECTED. The dedup-v0 retirement is COMPLETE: v0 rows are
 * unreachable by recall (search floors `dedupHashVersion == 1` and filters the
 * bumped `embeddingModelVersion` tag) and are deleted by the v0 purge, so the
 * cleartext-SHA-256 oracle no longer exists in any served or queryable row.
 * There is no server-side backfill — the server never holds the vault key; the
 * device re-ingests each source under the bumped model tag.
 */
const DEDUP_HASH_VERSION_LEGACY_CLEARTEXT = 0;
const DEDUP_HASH_VERSION_VAULT_HMAC = 1;

/**
 * The RETIRED embedding-model tag. Every live vector now lands under the bumped
 * tag (PensieveVectorCloak.embeddingModelVersion / embed.ts EMBEDDING_MODEL_VERSION
 * = "bge-small-en-v1.5-vault-dedup-v1"), so any row still carrying this string is
 * a pre-flag-day v0/ancient row. `purgeLegacyKnowledgeVectors` deletes by this
 * tag to reach pre-`dedupHashVersion` ancients that lack the version field
 * (Firestore cannot query "field absent"). Keep in lockstep with the device
 * constants if the production model tag is ever bumped again.
 */
const RETIRED_EMBEDDING_MODEL_VERSION = "bge-small-en-v1.5";

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

      // Opaque vault-keyed source id for the per-source manifest. Path-derived
      // slugs are rejected; source paths live only inside sealed metadata.
      const sourceSlug = requireHexDigest(request.data.sourceSlug, "sourceSlug");
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
        // Idempotent skip: compare the stored `dedupHash` AND require the stored
        // row to already be at v1. FLAG-DAY (dedup-v0 retirement): a stored doc
        // whose `dedupHashVersion !== 1` (a legacy v0 row, or a pre-versioned
        // ancient with no field) is NEVER treated as an idempotent match — the
        // chunk is force-rewritten at v1 so the cleartext-SHA-256 oracle cannot
        // survive a re-ingest that happens to collide on doc id. The cleartext
        // `contentHash` oracle is no longer read here (privacy-leak-remediation-
        // 2026-06-02 §3).
        const priorDedupHash = priorExists ? prior?.get("dedupHash") : undefined;
        const priorVersion = priorExists ? Number(prior?.get("dedupHashVersion") ?? 0) : 0;
        if (priorExists && priorVersion === DEDUP_HASH_VERSION_VAULT_HMAC && priorDedupHash === v.dedupHash) {
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
          // Vault-keyed HMAC(plaintext) — always v1; the write path no longer
          // produces a legacy v0 cleartext SHA-256 (see dedupHashVersion).
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
      // The manifest id/sourceSlug is an opaque vault-keyed source id; source
      // paths and labels live only inside sealed per-vector metadata.
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
 * chat memory) and return its stable opaque source id. Enforces the per-tier
 * source cap for NEW sources only. Returns { sourceSlug }.
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
      if (request.data.rootPath !== undefined && request.data.rootPath !== null) {
        throw new HttpsError("invalid-argument", "rootPath is private and must stay sealed on device.");
      }
      const repoInstallId = boundedTrimmedString(request.data.repoInstallId, "repoInstallId", 256, false);
      const requested = request.data.sourceSlug ?? repoInstallId ?? randomBytes(32).toString("hex");
      const sourceSlug = requireHexDigest(requested, "sourceSlug");

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
      const sourceSlug = requireHexDigest(request.data.sourceSlug, "sourceSlug");
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
  // Retained ONLY as the v0 purge predicate; the write path no longer produces
  // v0 rows and recall never serves them (privacy-leak-remediation-2026-06-02 §3).
  DEDUP_HASH_VERSION_LEGACY_CLEARTEXT,
  DEDUP_HASH_VERSION_VAULT_HMAC,
  RETIRED_EMBEDDING_MODEL_VERSION,
  requireSourceKind,
  requireCloakedVector,
  resolveDedupHash,
  purgeLegacyKnowledgeVectorsForUser,
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

/**
 * Delete every stranded legacy v0 / pre-flag-day knowledge vector for one user.
 *
 * FLAG-DAY (dedup-v0 retirement): a re-ingest produces a NEW vault-keyed doc id
 * and cannot reach the old SHA-256-keyed v0 doc, so the keyless oracle survives
 * forever on those orphaned rows unless we delete them. `privacyBackfill` can
 * only strip FIELDS (FieldValue.delete()), never whole docs, so the purge lives
 * here. Two predicates, both whole-doc deletes via `deleteQueryInBatches`:
 *   1. `dedupHashVersion == 0` — every explicitly-stamped legacy v0 row.
 *   2. `embeddingModelVersion == RETIRED_EMBEDDING_MODEL_VERSION` — reaches the
 *      pre-`dedupHashVersion` ancients that lack the version field (Firestore
 *      cannot query "field absent"). Safe because the device now writes ONLY
 *      under the bumped model tag, so any row still on the retired tag is stale.
 * Idempotent (re-runnable) and zero-knowledge — it deletes by opaque columns and
 * never reads plaintext. Returns the per-predicate delete counts.
 */
async function purgeLegacyKnowledgeVectorsForUser(
  uid: string,
): Promise<{ deletedByVersion: number; deletedByRetiredTag: number }> {
  const coll = db.collection(`users/${uid}/cloud_search_knowledge`);
  const deletedByVersion = await deleteQueryInBatches(
    coll.where("dedupHashVersion", "==", DEDUP_HASH_VERSION_LEGACY_CLEARTEXT),
  );
  const deletedByRetiredTag = await deleteQueryInBatches(
    coll.where("embeddingModelVersion", "==", RETIRED_EMBEDDING_MODEL_VERSION),
  );
  return { deletedByVersion, deletedByRetiredTag };
}

/**
 * purgeLegacyKnowledgeVectors — owner-scoped flag-day sweep that DELETES the
 * stranded legacy v0 / retired-model-tag knowledge vectors for the caller. Pairs
 * with `searchKnowledge`'s `dedupHashVersion == 1` floor (which stops serving
 * them) to finish the dedup-v0 retirement: stop returning v0, then delete it.
 */
export const purgeLegacyKnowledgeVectors = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("purgeLegacyKnowledgeVectors", async (request: CallableRequest) => {
    const uid = requireUid(request);
    await assertActiveBurnBarCloudProEntitlement(uid);
    const { deletedByVersion, deletedByRetiredTag } = await purgeLegacyKnowledgeVectorsForUser(uid);
    return { ok: true, deletedByVersion, deletedByRetiredTag, deleted: deletedByVersion + deletedByRetiredTag };
  }),
);

/**
 * Daily backstop for the v0 purge. Walks a bounded page of members and runs the
 * same idempotent sweep so accounts converge to "no stranded v0 / retired-tag
 * knowledge vector" without each client invoking the callable (mirrors
 * backfillPrivacyPlaintextScheduled).
 */
export const purgeLegacyKnowledgeVectorsScheduled = onSchedule(
  {
    region: FUNCTIONS_REGION,
    schedule: "every 24 hours",
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async () => {
    const startedAt = Date.now();
    let usersScanned = 0;
    let deletedByVersion = 0;
    let deletedByRetiredTag = 0;
    let cursor: QueryDocumentSnapshot | undefined;
    let exhausted = false;
    while (Date.now() - startedAt < 500_000) {
      let query = db.collection("users").orderBy("__name__").limit(500);
      if (cursor) query = query.startAfter(cursor);
      const users = await query.get();
      if (users.empty) {
        exhausted = true;
        break;
      }
      for (const user of users.docs) {
        usersScanned += 1;
        const stats = await purgeLegacyKnowledgeVectorsForUser(user.id);
        deletedByVersion += stats.deletedByVersion;
        deletedByRetiredTag += stats.deletedByRetiredTag;
      }
      cursor = users.docs.at(-1);
      if (users.size < 500) {
        exhausted = true;
        break;
      }
    }
    logInfo({
      event: "callable_info",
      message: "legacy knowledge vector purge (scheduled)",
      usersScanned,
      exhausted,
      nextUserCursor: exhausted ? undefined : cursor?.id,
      deletedByVersion,
      deletedByRetiredTag,
    });
  },
);
