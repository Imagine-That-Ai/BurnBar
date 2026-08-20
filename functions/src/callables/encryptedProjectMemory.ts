/**
 * @fileoverview Encrypted project-memory snapshot callables.
 *
 * Split out of `encryptedSearch.ts` to keep both modules under the 600-line cap. The four
 * project-memory snapshot callables live here; the original module re-exports them so every existing
 * `import ... from "./callables/encryptedSearch.js"` keeps resolving byte-identically.
 *
 * Behavior is a verbatim relocation of the prior inline handlers: identical auth gate, entitlement
 * gate, validation, sealed-blob handling, Firestore reads/writes, and wire shapes.
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import {
  nowISO,
  requiredIdentifier,
  requireHexDigest,
  requireBoundedNumber,
  optionalISODateString,
  requireBoundedStringArray,
  parseProjectMemoryFreshness,
  requireCloudVaultBlobEnvelope,
  cloudVaultAADContext,
  assertActiveBurnBarProEntitlement,
  sha256Hex,
} from "./shared.js";
import type { ProjectMemorySnapshotDoc } from "../types.js";
import { errorMessage, stripUndefinedObject } from "../guards.js";
import { logWarn, wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

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
        contentHashVersion?: unknown;
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
      const contentHashVersion = requireBoundedNumber(
        request.data.contentHashVersion ?? 0,
        "contentHashVersion",
        0,
        100,
      );
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
      const sealedSnapshot = requireCloudVaultBlobEnvelope(
        request.data.sealedSnapshot,
        "sealedSnapshot",
        cloudVaultAADContext(uid, "project_memory_snapshots", docID, "sealedSnapshot"),
      );
      const updatedAt = nowISO();

      const doc: ProjectMemorySnapshotDoc = {
        docID,
        contentHash,
        contentHashVersion,
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
      const legacyDocID = optionalLegacyProjectMemoryDocID(request.data.legacyDocID);
      if (legacyDocID && legacyDocID !== docID) {
        await db
          .doc(`users/${uid}/project_memory_snapshots/${legacyDocID}`)
          .delete()
          .catch((err: unknown) => {
            logWarn({
              event: "legacy_project_memory_delete_failed",
              user_id_hash: uid.slice(0, 8),
              detail: errorMessage(err),
            });
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

function optionalLegacyProjectMemoryDocID(raw: unknown): string | undefined {
  if (typeof raw !== "string" || raw.trim().length === 0) {
    return undefined;
  }
  const safe = raw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return safe.length > 0 ? safe : undefined;
}

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

export const deleteEncryptedProjectMemorySnapshot = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "deleteEncryptedProjectMemorySnapshot",
    async (
      request: CallableRequest<{
        docID?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before deleting Project Memory.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarProEntitlement(uid);

      const docID = requiredIdentifier(request.data.docID, "docID");
      const deletedAt = nowISO();
      const ref = db.doc(`users/${uid}/project_memory_snapshots/${docID}`);
      const snap = await ref.get();
      const data = snap.data() ?? {};
      const existed = snap.exists;
      const priorContentHash = typeof data.contentHash === "string" ? data.contentHash : undefined;
      const receiptHash = sha256Hex(
        JSON.stringify({
          uid,
          docID,
          existed,
          priorContentHash: priorContentHash ?? null,
          deletedAt,
          collection: "project_memory_snapshots",
        }),
      );

      await ref.delete();
      await db.doc(`users/${uid}/project_memory_tombstones/${docID}`).set(
        stripUndefinedObject({
          docID,
          collection: "project_memory_snapshots",
          existed,
          priorContentHash,
          deletedAt,
          receiptHash,
          schemaVersion: 1,
        }),
        { merge: false },
      );

      return {
        ok: true,
        docID,
        existed,
        deletedAt,
        receiptHash,
      };
    },
  ),
);
