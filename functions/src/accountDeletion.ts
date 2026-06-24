/**
 * @fileoverview Account-erasure helpers.
 *
 * The public account-delete UI promises cloud data deletion, not just Firebase
 * Auth deletion. Keep that contract server-side so Firestore Admin and Secret
 * Manager cleanup happen under one audited callable.
 */

import { createHash } from "node:crypto";
import { getStorage } from "firebase-admin/storage";
import { logWarn } from "./logging.js";
import { appendAuditEventRequired, AUDIT_ACTIONS } from "./callables/auditLog.js";

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
  logger?: Pick<typeof console, "warn">;
  /** Delete a Cloud Storage prefix (objects). Injectable for tests; defaults to the live bucket. */
  deleteStorageObjects?: (prefix: string) => Promise<void>;
}

interface AccountDeletionQueryDocument {
  readonly id: string;
  readonly ref: AccountDeletionDocumentReference;
  get(field: string): unknown;
}

interface AccountDeletionQuery {
  get(): Promise<{ docs: AccountDeletionQueryDocument[] }>;
}

interface AccountDeletionCollection {
  listDocuments(): Promise<AccountDeletionDocumentReference[]>;
  where(field: string, op: "==", value: unknown): AccountDeletionQuery;
}

interface AccountDeletionDocumentReference {
  readonly path?: string;
  listCollections(): Promise<AccountDeletionCollection[]>;
  set?(data: Record<string, unknown>, options?: { merge?: boolean }): Promise<unknown>;
}

interface AccountDeletionWriteBatch {
  delete(ref: AccountDeletionDocumentReference): void;
  commit(): Promise<unknown>;
}

interface AccountDeletionFirestore {
  collection(path: string): AccountDeletionCollection;
  doc(path: string): AccountDeletionDocumentReference;
  batch(): AccountDeletionWriteBatch;
}

type AccountDeletionAuditAppender = (
  uid: string,
  event: { actor: string; action: string; domain: string },
) => Promise<unknown>;

interface AccountDeletionAudit {
  actor: string;
  domain: string;
  /** Injectable appenders for tests; defaults to the live audit chain. */
  appendAuditEventRequired?: AccountDeletionAuditAppender;
}

interface DeleteUserAccountOptions extends AccountDeletionOptions {
  deleteAuthUser: (uid: string) => Promise<void>;
  /** Durable audit config. Required because account erasure is irreversible. */
  audit: AccountDeletionAudit;
}

const BATCH_LIMIT = 400;
const ACCOUNT_ERASURE_AUDIT_COLLECTION = "account_erasure_audit";
const ACCOUNT_ERASURE_AUDIT_SCHEMA_VERSION = 1;

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

function accountErasureAuditDocumentID(uid: string): string {
  return createHash("sha256").update(uid, "utf8").digest("hex");
}

export async function eraseUserAccount(
  db: AccountDeletionFirestore,
  uid: string,
  options: DeleteUserAccountOptions,
): Promise<AccountDeletionResult> {
  // Fail-closed intent: an irreversible account erasure must leave a durable
  // audit record. If the intent cannot be persisted, refuse the action rather
  // than silently deleting data without evidence.
  const appendRequired = options.audit.appendAuditEventRequired ?? appendAuditEventRequired;
  const intentAudit = await appendRequired(uid, {
    actor: options.audit.actor,
    action: AUDIT_ACTIONS.accountDeleteIntent,
    domain: options.audit.domain,
  });
  await writeAccountErasureAuditIntent(db, uid, options.audit, intentAudit);

  const summary = await eraseUserCloudData(db, uid, options);
  await updateAccountErasureAuditBestEffort(db, uid, {
    status: summary.failedSecretDestroys > 0 ? "cloud_data_deleted_with_secret_destroy_failures" : "cloud_data_deleted",
    cloudDataDeletedAt: new Date().toISOString(),
    deletedDocuments: summary.deletedDocuments,
    destroyedSecrets: summary.destroyedSecrets,
    failedSecretDestroys: summary.failedSecretDestroys,
  });
  if (summary.failedSecretDestroys > 0) {
    return {
      ...summary,
      deletedAuthUser: false,
      authUserAlreadyMissing: false,
    };
  }

  try {
    await options.deleteAuthUser(uid);
    await updateAccountErasureAuditBestEffort(db, uid, {
      status: "account_deleted",
      authDeletedAt: new Date().toISOString(),
    });
    return {
      ...summary,
      deletedAuthUser: true,
      authUserAlreadyMissing: false,
    };
  } catch (error) {
    if (isFirebaseAuthUserNotFound(error)) {
      await updateAccountErasureAuditBestEffort(db, uid, {
        status: "auth_user_already_missing",
        authDeleteObservedAt: new Date().toISOString(),
      });
      return {
        ...summary,
        deletedAuthUser: false,
        authUserAlreadyMissing: true,
      };
    }
    await updateAccountErasureAuditBestEffort(db, uid, {
      status: "auth_delete_failed",
      authDeleteFailedAt: new Date().toISOString(),
    });
    throw error;
  }
}

export async function eraseUserCloudData(
  db: AccountDeletionFirestore,
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
    // UIDs and paths are truncated or redacted before logging.
    const payload = {
      event: "account_deletion_warning",
      user_id_hash: userIdHash,
      message: msg,
      error: err instanceof Error ? err.message : String(err ?? ""),
      ...extra,
    };
    if (options.logger) {
      options.logger.warn(JSON.stringify(payload));
      return;
    }
    logWarn(payload);
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

async function deleteDocumentTree(ref: AccountDeletionDocumentReference, batcher: DeleteBatcher): Promise<void> {
  const collections = await ref.listCollections();
  for (const collection of collections) {
    await deleteCollectionTree(collection, batcher);
  }
  await batcher.delete(ref);
}

/** Delete every doc matched by a (uid-scoped) query — used for root collections. */
async function deleteQuery(query: AccountDeletionQuery, batcher: DeleteBatcher): Promise<void> {
  const snapshot = await query.get();
  for (const doc of snapshot.docs) {
    await batcher.delete(doc.ref);
  }
}

async function deleteCollectionTree(collection: AccountDeletionCollection, batcher: DeleteBatcher): Promise<void> {
  const docs = await collection.listDocuments();
  for (const doc of docs) {
    await deleteDocumentTree(doc, batcher);
  }
}

class DeleteBatcher {
  private batch: AccountDeletionWriteBatch;
  private pending = 0;

  constructor(
    private readonly db: AccountDeletionFirestore,
    private readonly summary: AccountDeletionSummary,
  ) {
    this.batch = db.batch();
  }

  async delete(ref: AccountDeletionDocumentReference): Promise<void> {
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

function accountErasureAuditRef(db: AccountDeletionFirestore, uid: string): AccountDeletionDocumentReference {
  return db.doc(`${ACCOUNT_ERASURE_AUDIT_COLLECTION}/${accountErasureAuditDocumentID(uid)}`);
}

function extractAuditAppendMetadata(result: unknown): Record<string, unknown> {
  if (!result || typeof result !== "object") return {};
  const seq = "seq" in result && typeof result.seq === "number" ? result.seq : undefined;
  const hash = "hash" in result && typeof result.hash === "string" ? result.hash : undefined;
  return stripUndefined({
    intentAuditSeq: seq,
    intentAuditHash: hash,
  });
}

async function writeAccountErasureAuditIntent(
  db: AccountDeletionFirestore,
  uid: string,
  audit: AccountDeletionAudit,
  intentAudit: unknown,
): Promise<void> {
  const now = new Date().toISOString();
  await mergeAccountErasureAudit(db, uid, {
    schemaVersion: ACCOUNT_ERASURE_AUDIT_SCHEMA_VERSION,
    uidHash: accountErasureAuditDocumentID(uid),
    status: "intent_recorded",
    actor: audit.actor,
    domain: audit.domain,
    intentAction: AUDIT_ACTIONS.accountDeleteIntent,
    completionAction: AUDIT_ACTIONS.accountDeleteComplete,
    intentRecordedAt: now,
    updatedAt: now,
    ...extractAuditAppendMetadata(intentAudit),
  });
}

async function updateAccountErasureAuditBestEffort(
  db: AccountDeletionFirestore,
  uid: string,
  patch: Record<string, unknown>,
): Promise<void> {
  try {
    await mergeAccountErasureAudit(db, uid, {
      ...patch,
      updatedAt: new Date().toISOString(),
    });
  } catch {
    // The fail-closed pre-delete intent is already durable. Later status updates
    // improve operator forensics but must not resurrect or block account erasure.
  }
}

async function mergeAccountErasureAudit(
  db: AccountDeletionFirestore,
  uid: string,
  data: Record<string, unknown>,
): Promise<void> {
  const ref = accountErasureAuditRef(db, uid);
  if (typeof ref.set !== "function") {
    throw new Error("Account erasure audit reference does not support set().");
  }
  await ref.set(stripUndefined(data), { merge: true });
}

function stripUndefined(value: Record<string, unknown>): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value)) {
    if (item !== undefined) {
      result[key] = item;
    }
  }
  return result;
}
