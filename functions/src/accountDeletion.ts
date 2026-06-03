/**
 * @fileoverview Account-erasure helpers.
 *
 * The public account-delete UI promises cloud data deletion, not just Firebase
 * Auth deletion. Keep that contract server-side so Firestore Admin and Secret
 * Manager cleanup happen under one audited callable.
 */

import type { CollectionReference, DocumentReference, Firestore, WriteBatch } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

export interface AccountDeletionSummary {
  destroyedSecrets: number;
  failedSecretDestroys: number;
  deletedDocuments: number;
}

export interface AccountDeletionResult extends AccountDeletionSummary {
  deletedAuthUser: boolean;
  authUserAlreadyMissing: boolean;
}

export interface AccountDeletionOptions {
  destroyCredential: (secretVersionName: string) => Promise<void>;
  logger?: Pick<typeof console, "warn">;
  /** Delete a Cloud Storage prefix (objects). Injectable for tests; defaults to the live bucket. */
  deleteStorageObjects?: (prefix: string) => Promise<void>;
}

export interface DeleteUserAccountOptions extends AccountDeletionOptions {
  deleteAuthUser: (uid: string) => Promise<void>;
}

const BATCH_LIMIT = 400;

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
  const summary = await eraseUserCloudData(db, uid, options);
  if (summary.failedSecretDestroys > 0) {
    return {
      ...summary,
      deletedAuthUser: false,
      authUserAlreadyMissing: false,
    };
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
  const logger = options.logger ?? console;

  const secretRefs = await db.collection("provider_account_secret_refs").where("uid", "==", uid).get();

  const batcher = new DeleteBatcher(db, summary);

  for (const doc of secretRefs.docs) {
    const secretVersionName = doc.get("secretVersionName");
    const secretVersion = typeof secretVersionName === "string" ? secretVersionName : undefined;
    if (secretVersion) {
      try {
        await options.destroyCredential(secretVersion);
        summary.destroyedSecrets += 1;
      } catch (error) {
        summary.failedSecretDestroys += 1;
        logger.warn(`Failed to destroy provider credential secret for ${uid}/${doc.id}:`, error);
      }
    }
    await batcher.delete(doc.ref);
  }

  await deleteDocumentTree(db.doc(`users/${uid}`), batcher);
  await deleteDocumentTree(db.doc(`workspaces/${userWorkspaceID(uid)}`), batcher);
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
      logger.warn(`Failed to delete Cloud Storage objects (${prefix}) for ${uid}:`, error);
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
