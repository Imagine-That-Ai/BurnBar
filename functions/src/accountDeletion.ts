/**
 * @fileoverview Account-erasure helpers.
 *
 * The public account-delete UI promises cloud data deletion, not just Firebase
 * Auth deletion. Keep that contract server-side so Firestore Admin and Secret
 * Manager cleanup happen under one audited callable.
 */

import type { CollectionReference, DocumentReference, Firestore, Query, WriteBatch } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { logWarn } from "./logging.js";
import { appendAuditEvent, appendAuditEventRequired, AUDIT_ACTIONS } from "./callables/auditLog.js";

interface AccountDeletionSummary {
  destroyedSecrets: number;
  failedSecretDestroys: number;
  deletedDocuments: number;
}

interface AccountDeletionResult extends AccountDeletionSummary {
  deletedAuthUser: boolean;
  authUserAlreadyMissing: boolean;
}

interface AccountDeletionOptions {
  destroyCredential: (secretVersionName: string) => Promise<void>;
  /** Delete a Cloud Storage prefix (objects). Injectable for tests; defaults to the live bucket. */
  deleteStorageObjects?: (prefix: string) => Promise<void>;
}

interface AccountDeletionAudit {
  actor: string;
  domain: string;
  /** Injectable appenders for tests; defaults to the live audit chain. */
  appendAuditEvent?: typeof appendAuditEvent;
  appendAuditEventRequired?: typeof appendAuditEventRequired;
}

export interface DeleteUserAccountOptions extends AccountDeletionOptions {
  deleteAuthUser: (uid: string) => Promise<void>;
  /** Durable audit config. Required: account erasure is irreversible (FINDING-006). */
  audit: AccountDeletionAudit;
}

const BATCH_LIMIT = 400;

/**
 * Root (non-`users/{uid}`) collections that carry per-document `uid` ownership
 * and therefore are not reached by the `users/{uid}` subtree walk. Account erase
 * must delete the caller's documents in each (GDPR Art.17).
 */
const ROOT_COLLECTIONS_KEYED_BY_UID = ["voip_outbound", "fcm_outbound"] as const;

export function userWorkspaceID(uid: string): string {
  return `workspace-${uid}`;
}

export function providerSecretRefDocumentID(uid: string, accountID: string): string {
  return `${uid}_${accountID}`;
}

export async function eraseUserAccount(
  db: Firestore,
  uid: string,
  options: DeleteUserAccountOptions,
): Promise<AccountDeletionResult> {
  // Fail-closed intent: an irreversible account erasure must leave a durable
  // audit record. If the intent cannot be persisted, refuse the action rather
  // than silently deleting data without evidence (FINDING-006).
  const appendRequired = options.audit.appendAuditEventRequired ?? appendAuditEventRequired;
  await appendRequired(uid, {
    actor: options.audit.actor,
    action: AUDIT_ACTIONS.accountDeleteIntent,
    domain: options.audit.domain,
  });

  const summary = await eraseUserCloudData(db, uid, options);
  if (summary.failedSecretDestroys > 0) {
    return {
      ...summary,
      deletedAuthUser: false,
      authUserAlreadyMissing: false,
    };
  }

  // Best-effort completion record: the intent is the fail-closed guard; the
  // completion record improves forensics but cannot undo the deletion.
  const appendComplete = options.audit.appendAuditEvent ?? appendAuditEvent;
  try {
    await appendComplete(uid, {
      actor: options.audit.actor,
      action: AUDIT_ACTIONS.accountDeleteComplete,
      domain: options.audit.domain,
    });
  } catch {
    // Completion audit is best-effort; the intent audit already guarantees a
    // durable record of the irreversible action.
  }

  try {
    await options.deleteAuthUser(uid);
    return {
      ...summary,
      deletedAuthUser: true,
      authUserAlreadyMissing: false,
    };
  } catch (error) {
    if (isFirebaseAuthUserNotFound(error)) {
      return {
        ...summary,
        deletedAuthUser: false,
        authUserAlreadyMissing: true,
      };
    }
    throw error;
  }
}

export async function eraseUserCloudData(
  db: Firestore,
  uid: string,
  options: AccountDeletionOptions,
): Promise<AccountDeletionSummary> {
  if (!uid.trim()) {
    throw new Error("uid is required for account deletion.");
  }

  const summary: AccountDeletionSummary = {
    destroyedSecrets: 0,
    failedSecretDestroys: 0,
    deletedDocuments: 0,
  };
  const userIdHash = uid.slice(0, 8);

  const safeWarn = (msg: string, err?: unknown, extra?: Record<string, unknown>) => {
    // Always route through the structured scrubber instead of any raw logger so
    // UIDs and paths are truncated/redacted per I3/I7 invariants. Closes OPUS-F-005.
    logWarn({
      event: "account_deletion_warning",
      user_id_hash: userIdHash,
      message: msg,
      error: err instanceof Error ? err.message : String(err ?? ""),
      ...extra,
    });
  };

  const secretRefs = await db.collection("provider_account_secret_refs").where("uid", "==", uid).get();

  const batcher = new DeleteBatcher(db, summary);

  for (const doc of secretRefs.docs) {
    const secretVersionName = doc.get("secretVersionName");
    const secretVersion = typeof secretVersionName === "string" ? secretVersionName : undefined;
    // provider_account_secret_refs doc ids are `${uid}_${accountID}`; never log
    // the raw id. Keep only an 8-char account correlation hash for debugging.
    const accountID = doc.id.startsWith(`${uid}_`) ? doc.id.slice(uid.length + 1) : undefined;
    const accountIdHash = accountID ? accountID.slice(0, 8) : undefined;
    if (secretVersion) {
      try {
        await options.destroyCredential(secretVersion);
        summary.destroyedSecrets += 1;
      } catch (error) {
        summary.failedSecretDestroys += 1;
        safeWarn("Failed to destroy provider credential secret", error, {
          account_id_hash: accountIdHash,
          collection: "provider_account_secret_refs",
        });
      }
    }
    await batcher.delete(doc.ref);
  }

  // Root push-queue collections are keyed by random doc id (not under the
  // users/{uid} tree), so the recursive walk below never reaches them. Without
  // an explicit uid-scoped sweep they survive "delete my account" forever,
  // retaining uid + cleartext caller name + live push tokens (F-RR09-001,
  // GDPR Art.17). The companion expireAt TTL only bounds delivered docs.
  await deleteQuery(db.collection("voip_outbound").where("uid", "==", uid), batcher);
  await deleteQuery(db.collection("fcm_outbound").where("uid", "==", uid), batcher);
  await deleteDocumentTree(db.doc(`users/${uid}`), batcher);
  await deleteDocumentTree(db.doc(`workspaces/${userWorkspaceID(uid)}`), batcher);

  // GDPR Art.17: the VoIP / FCM push fan-out queues live in ROOT collections
  // (not under users/{uid}), each carrying the owning `uid` field. The
  // user-subtree walk above never reaches them, so erase them explicitly by
  // owner. They are TTL-bounded (T-PRV-02) but a deletion request must purge
  // them immediately rather than waiting for the TTL sweep.
  for (const rootCollection of ROOT_COLLECTIONS_KEYED_BY_UID) {
    const docs = await db.collection(rootCollection).where("uid", "==", uid).get();
    for (const doc of docs.docs) {
      await batcher.delete(doc.ref);
    }
  }

  await batcher.flush();

  // Purge the user's Cloud Storage objects too — sealed session-log bodies,
  // Hermes gateway attachments, and the avatar. Without this, account erase left
  // orphaned ciphertext blobs behind (the Firestore manifests were gone but the
  // bytes remained). Best-effort: a storage failure must not fail the erase.
  const deleteStorageObjects =
    options.deleteStorageObjects ??
    (async (prefix: string) => {
      await getStorage().bucket().deleteFiles({ prefix, force: true });
    });
  for (const prefix of [`users/${uid}/`, `avatars/${uid}`]) {
    try {
      await deleteStorageObjects(prefix);
    } catch (error) {
      safeWarn("Failed to delete Cloud Storage objects", error, { storage_prefix_kind: prefix.startsWith("avatars/") ? "avatars" : "users" });
    }
  }

  return summary;
}

export function isFirebaseAuthUserNotFound(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const code = "code" in error ? error.code : undefined;
  const errorInfo =
    "errorInfo" in error && error.errorInfo && typeof error.errorInfo === "object" ? error.errorInfo : undefined;
  const nestedCode = errorInfo && "code" in errorInfo ? errorInfo.code : undefined;
  return code === "auth/user-not-found" || nestedCode === "auth/user-not-found";
}

async function deleteDocumentTree(ref: DocumentReference, batcher: DeleteBatcher): Promise<void> {
  const collections = await ref.listCollections();
  for (const collection of collections) {
    await deleteCollectionTree(collection, batcher);
  }
  await batcher.delete(ref);
}

/** Delete every doc matched by a (uid-scoped) query — used for root collections. */
async function deleteQuery(query: Query, batcher: DeleteBatcher): Promise<void> {
  const snapshot = await query.get();
  for (const doc of snapshot.docs) {
    await batcher.delete(doc.ref);
  }
}

async function deleteCollectionTree(collection: CollectionReference, batcher: DeleteBatcher): Promise<void> {
  const docs = await collection.listDocuments();
  for (const doc of docs) {
    await deleteDocumentTree(doc, batcher);
  }
}

class DeleteBatcher {
  private batch: WriteBatch;
  private pending = 0;

  constructor(
    private readonly db: Firestore,
    private readonly summary: AccountDeletionSummary,
  ) {
    this.batch = db.batch();
  }

  async delete(ref: DocumentReference): Promise<void> {
    this.batch.delete(ref);
    this.pending += 1;
    this.summary.deletedDocuments += 1;
    if (this.pending >= BATCH_LIMIT) {
      await this.flush();
    }
  }

  async flush(): Promise<void> {
    if (this.pending === 0) return;
    await this.batch.commit();
    this.batch = this.db.batch();
    this.pending = 0;
  }
}
