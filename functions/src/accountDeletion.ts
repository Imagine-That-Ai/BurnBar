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
import {
  ensureAccountErasureTombstone,
  requireFreshAccountErasure,
  requireResumableAccountErasure,
  updateAccountErasureAuditBestEffort,
  updateAccountErasureAuditRequired,
  writeAccountErasureAuditIntent,
  writeAccountErasureCompletionRequired,
} from "./accountDeletionAudit.js";

export {
  ACCOUNT_ERASURE_TOMBSTONE_COLLECTION,
  isAccountErasureResumable,
  verifyRetainedAccountErasureEvents,
} from "./accountDeletionAudit.js";

export type AccountStoragePrefixKind = "user_data" | "avatar";

export interface AccountDeletionSummary {
  destroyedSecrets: number;
  failedSecretDestroys: number;
  deletedStoragePrefixes: number;
  failedStorageDeletes: number;
  failedStoragePrefixKinds: AccountStoragePrefixKind[];
  deletedDocuments: number;
  cloudDataDeleted: boolean;
  retryRequired: boolean;
}

export interface AccountDeletionResult extends AccountDeletionSummary {
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
  get?(): Promise<AccountDeletionDocumentSnapshot>;
  set?(data: Record<string, unknown>, options?: { merge?: boolean }): Promise<unknown>;
}

interface AccountDeletionDocumentSnapshot {
  readonly exists: boolean;
  get(field: string): unknown;
}

interface AccountDeletionWriteBatch {
  create?(ref: AccountDeletionDocumentReference, data: Record<string, unknown>): void;
  delete(ref: AccountDeletionDocumentReference): void;
  set?(ref: AccountDeletionDocumentReference, data: Record<string, unknown>, options?: { merge?: boolean }): void;
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
  revokeAuthTokens: (uid: string) => Promise<void>;
  deleteAuthUser: (uid: string) => Promise<void>;
  /** True only after a schema-v2 nonterminal receipt has been verified. */
  resumeExistingIntent?: boolean;
  /** Durable audit config. Required because account erasure is irreversible. */
  audit: AccountDeletionAudit;
}

const BATCH_LIMIT = 400;

/**
 * Root (non-`users/{uid}`) collections that carry per-document `uid` ownership
 * and therefore are not reached by the `users/{uid}` subtree walk. Account erase
 * must delete the caller's documents in each (GDPR Art.17).
 */
export const ACCOUNT_ERASURE_ROOT_OWNER_REGISTRY = [
  { collection: "voip_outbound", ownerField: "uid" },
  { collection: "fcm_outbound", ownerField: "uid" },
  { collection: "credential_transfers", ownerField: "ownerUid" },
  { collection: "hermes_gateway_token_index", ownerField: "uid" },
  { collection: "hermes_gateway_device_sessions", ownerField: "uid" },
  { collection: "cli_link_sessions", ownerField: "ownerUid" },
] as const;

function accountStoragePrefixes(uid: string): Array<{ kind: AccountStoragePrefixKind; prefix: string }> {
  return [
    { kind: "user_data", prefix: `users/${uid}/` },
    { kind: "avatar", prefix: `avatars/${uid}/` },
  ];
}

export function userWorkspaceID(uid: string): string {
  return `workspace-${uid}`;
}

export function providerSecretRefDocumentID(uid: string, accountID: string): string {
  return `${uid}_${accountID}`;
}

function accountDeletionCorrelationHash(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex").slice(0, 12);
}

export async function eraseUserAccount(
  db: AccountDeletionFirestore,
  uid: string,
  options: DeleteUserAccountOptions,
): Promise<AccountDeletionResult> {
  if (options.resumeExistingIntent) {
    await requireResumableAccountErasure(db, uid);
  } else {
    await requireFreshAccountErasure(db, uid);
    // Fail closed before the write barrier: preserve the complete canonical
    // authorization event outside the user tree before any data is removed.
    const appendRequired = options.audit.appendAuditEventRequired ?? appendAuditEventRequired;
    const intentAudit = await appendRequired(uid, {
      actor: options.audit.actor,
      action: AUDIT_ACTIONS.accountDeleteIntent,
      domain: options.audit.domain,
    });
    await writeAccountErasureAuditIntent(db, uid, options.audit, intentAudit);
  }

  // This durable server-only marker is the write barrier consumed by Firestore,
  // Storage, and the callable wrapper. Admin cleanup bypasses client rules.
  await ensureAccountErasureTombstone(db, uid);
  try {
    await options.revokeAuthTokens(uid);
  } catch (error) {
    if (!isFirebaseAuthUserNotFound(error)) {
      await updateAccountErasureAuditRequired(db, uid, {
        status: "session_revoke_failed",
        sessionRevokeFailedAt: new Date().toISOString(),
        retryRequired: true,
      });
      throw error;
    }
  }

  let summary: AccountDeletionSummary;
  try {
    summary = await eraseUserCloudData(db, uid, options);
  } catch (error) {
    // The durable intent remains a valid resume authorization even when this
    // status write is unavailable. Never proceed to Auth deletion after an
    // unclassified Firestore cleanup failure.
    await updateAccountErasureAuditBestEffort(db, uid, {
      status: "cloud_data_cleanup_failed",
      retryRequired: true,
      cleanupFailureObservedAt: new Date().toISOString(),
    });
    throw error;
  }

  const cleanupEvidence = {
    deletedDocuments: summary.deletedDocuments,
    destroyedSecrets: summary.destroyedSecrets,
    failedSecretDestroys: summary.failedSecretDestroys,
    deletedStoragePrefixes: summary.deletedStoragePrefixes,
    failedStorageDeletes: summary.failedStorageDeletes,
    failedStoragePrefixKinds: summary.failedStoragePrefixKinds,
    cloudDataDeleted: summary.cloudDataDeleted,
    retryRequired: summary.retryRequired,
  };

  if (!summary.cloudDataDeleted) {
    // This state is load-bearing retry authorization. Persist it fail-closed so
    // operators can distinguish a requested deletion from completed erasure.
    await updateAccountErasureAuditRequired(db, uid, {
      status: "external_cleanup_incomplete",
      cleanupAttemptedAt: new Date().toISOString(),
      ...cleanupEvidence,
    });
    return {
      ...summary,
      deletedAuthUser: false,
      authUserAlreadyMissing: false,
    };
  }

  // Persist proof that every cloud-data stage completed before the irreversible
  // Auth deletion. If this write fails, Auth remains and the intent record can
  // authorize an idempotent retry.
  await updateAccountErasureAuditRequired(db, uid, {
    status: "cloud_data_deleted",
    cloudDataDeletedAt: new Date().toISOString(),
    ...cleanupEvidence,
  });

  let authUserAlreadyMissing = false;
  try {
    await options.deleteAuthUser(uid);
  } catch (error) {
    if (isFirebaseAuthUserNotFound(error)) authUserAlreadyMissing = true;
    else {
      await updateAccountErasureAuditBestEffort(db, uid, {
        status: "auth_delete_failed",
        authDeleteFailedAt: new Date().toISOString(),
        retryRequired: true,
      });
      throw error;
    }
  }

  // Auth is now absent. Do not return success until the complete retained event
  // and terminal receipt are durable. A reconciliation job repairs this stage
  // if the process dies after Auth deletion but before these writes.
  const outcome = authUserAlreadyMissing ? "auth_user_already_missing" : "account_deleted";
  await writeAccountErasureCompletionRequired(db, uid, options.audit, outcome);
  return {
    ...summary,
    deletedAuthUser: !authUserAlreadyMissing,
    authUserAlreadyMissing,
  };
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
    deletedStoragePrefixes: 0,
    failedStorageDeletes: 0,
    failedStoragePrefixKinds: [],
    deletedDocuments: 0,
    cloudDataDeleted: false,
    retryRequired: false,
  };
  const userIdHash = accountDeletionCorrelationHash(uid);

  const safeWarn = (msg: string, err?: unknown, extra?: Record<string, unknown>) => {
    // Always route through the structured scrubber instead of any raw logger so
    // UIDs and paths are truncated or redacted before logging.
    const payload = {
      event: "account_deletion_warning",
      user_id_hash: userIdHash,
      message: msg,
      error_code: accountDeletionErrorCode(err),
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
    // the raw id. Keep only a one-way correlation hash for debugging.
    const accountID = doc.id.startsWith(`${uid}_`) ? doc.id.slice(uid.length + 1) : undefined;
    const accountIdHash = accountID ? accountDeletionCorrelationHash(accountID) : undefined;
    if (!secretVersion?.trim()) {
      // The reference is the only server-side link to the hosted secret. Never
      // delete a malformed ref and then claim erasure succeeded: that would
      // orphan an external credential with no deterministic retry path.
      summary.failedSecretDestroys += 1;
      safeWarn("Provider credential reference is missing its secret version", undefined, {
        account_id_hash: accountIdHash,
        collection: "provider_account_secret_refs",
      });
      continue;
    }
    try {
      await options.destroyCredential(secretVersion);
      summary.destroyedSecrets += 1;
    } catch (error) {
      if (isSecretVersionAlreadyErased(error)) {
        // A previous attempt may have destroyed the external version and
        // crashed before deleting this Firestore pointer. Treat that state as
        // success so retries remain idempotent.
        summary.destroyedSecrets += 1;
      } else {
        summary.failedSecretDestroys += 1;
        safeWarn("Failed to destroy provider credential secret", error, {
          account_id_hash: accountIdHash,
          collection: "provider_account_secret_refs",
        });
        continue;
      }
    }
    // Delete only refs whose external secret is gone. Failed refs remain as the
    // durable retry manifest; deleting them would make cleanup unrecoverable.
    await batcher.delete(doc.ref);
  }

  // Commit successful secret-ref cleanup before returning an incomplete result.
  // Failed refs and the user/trusted-device subtree remain available to retry.
  await batcher.flush();

  // Cloud Storage is an erasure prerequisite, not best-effort cleanup. Prefix
  // deletion is idempotent, so every retry attempts both prefixes again.
  const deleteStorageObjects =
    options.deleteStorageObjects ??
    (async (prefix: string) => {
      const bucket = getStorage().bucket();
      await bucket.deleteFiles({ prefix, force: true });
      const [remaining] = await bucket.getFiles({ prefix, maxResults: 1 });
      if (remaining.length > 0) {
        // Do not include the raw user-scoped prefix in the exception because the
        // structured warning path intentionally logs only the category.
        throw new Error("Cloud Storage prefix still contains objects after deletion.");
      }
    });
  for (const { kind, prefix } of accountStoragePrefixes(uid)) {
    try {
      await deleteStorageObjects(prefix);
      summary.deletedStoragePrefixes += 1;
    } catch (error) {
      summary.failedStorageDeletes += 1;
      summary.failedStoragePrefixKinds.push(kind);
      safeWarn("Failed to delete Cloud Storage objects", error, { storage_prefix_kind: kind });
    }
  }

  if (summary.failedSecretDestroys > 0 || summary.failedStorageDeletes > 0) {
    summary.retryRequired = true;
    return summary;
  }

  // Only after every external artifact is gone may we erase the Firestore
  // identity/trusted-device substrate and permit Auth deletion.
  await deleteDocumentTree(db.doc(`users/${uid}`), batcher);
  await deleteDocumentTree(db.doc(`workspaces/${userWorkspaceID(uid)}`), batcher);

  // Root records are keyed independently from users/{uid}; keep this explicit
  // registry in sync with every server-owned UID-bearing root collection.
  for (const entry of ACCOUNT_ERASURE_ROOT_OWNER_REGISTRY) {
    const docs = await db.collection(entry.collection).where(entry.ownerField, "==", uid).get();
    for (const doc of docs.docs) {
      await batcher.delete(doc.ref);
    }
  }

  await batcher.flush();
  summary.cloudDataDeleted = true;

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

/** Secret Manager destroy is idempotent from the erasure contract's view. */
export function isSecretVersionAlreadyErased(error: unknown): boolean {
  if (!isRecord(error)) return false;
  const record = error;
  const response = isRecord(record.response) ? record.response : undefined;
  const responseData = response && isRecord(response.data) ? response.data : undefined;
  const responseError = responseData && isRecord(responseData.error) ? responseData.error : undefined;
  const errorInfo = isRecord(record.errorInfo) ? record.errorInfo : undefined;
  const rawCode = record.code ?? response?.status;
  const code = typeof rawCode === "string" && /^\d+$/u.test(rawCode) ? Number(rawCode) : rawCode;
  const status = responseError?.status ?? errorInfo?.code;
  const message = [record.message, responseError?.message, errorInfo?.message]
    .filter((value): value is string => typeof value === "string")
    .join(" ");

  if (code === 404 || code === 5 || status === "NOT_FOUND") return true;
  return (code === 400 || code === 9 || status === "FAILED_PRECONDITION") && /\bdestroyed\b/iu.test(message);
}

async function deleteDocumentTree(ref: AccountDeletionDocumentReference, batcher: DeleteBatcher): Promise<void> {
  const collections = await ref.listCollections();
  for (const collection of collections) {
    await deleteCollectionTree(collection, batcher);
  }
  await batcher.delete(ref);
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function accountDeletionErrorCode(error: unknown): string {
  if (!isRecord(error)) return "unknown";
  const record = error;
  const errorInfo = isRecord(record.errorInfo) ? record.errorInfo : undefined;
  const response = isRecord(record.response) ? record.response : undefined;
  const candidate = record.code ?? errorInfo?.code ?? response?.status;
  if (typeof candidate === "string" || typeof candidate === "number") {
    const value = String(candidate);
    if (/^[A-Za-z0-9_./-]{1,64}$/u.test(value)) return value;
  }
  if (error instanceof Error && /^[A-Za-z][A-Za-z0-9_]{0,63}$/u.test(error.name)) {
    return error.name;
  }
  return "external_cleanup_error";
}
