/**
 * @fileoverview Account-erasure helpers.
 *
 * The public account-delete UI promises cloud data deletion, not just Firebase
 * Auth deletion. Keep that contract server-side so Firestore Admin and Secret
 * Manager cleanup happen under one audited callable.
 */

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
}

export interface DeleteUserAccountOptions extends AccountDeletionOptions {
  deleteAuthUser: (uid: string) => Promise<void>;
}

export interface AccountDeletionDocumentReference {
  listCollections(): Promise<AccountDeletionCollectionReference[]>;
}

export interface AccountDeletionCollectionReference {
  listDocuments(): Promise<AccountDeletionDocumentReference[]>;
}

export interface AccountDeletionSecretSnapshot {
  id: string;
  ref: AccountDeletionDocumentReference;
  get(field: string): unknown;
}

export interface AccountDeletionSecretQuery {
  get(): Promise<{ docs: AccountDeletionSecretSnapshot[] }>;
}

export interface AccountDeletionSecretCollection {
  where(field: string, op: string, value: string): AccountDeletionSecretQuery;
}

export interface AccountDeletionWriteBatch {
  delete(ref: AccountDeletionDocumentReference): void;
  commit(): Promise<unknown>;
}

export interface AccountDeletionFirestore {
  collection(path: string): AccountDeletionSecretCollection;
  doc(path: string): AccountDeletionDocumentReference;
  batch(): AccountDeletionWriteBatch;
}

const BATCH_LIMIT = 400;

export function userWorkspaceID(uid: string): string {
  return `workspace-${uid}`;
}

export function providerSecretRefDocumentID(uid: string, accountID: string): string {
  return `${uid}_${accountID}`;
}

export async function eraseUserAccount(
  db: AccountDeletionFirestore,
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
  const logger = options.logger ?? console;

  const secretRefs = await db.collection("provider_account_secret_refs").where("uid", "==", uid).get();

  const batcher = new DeleteBatcher(db, summary);

  for (const doc of secretRefs.docs) {
    const secretVersionName = doc.get("secretVersionName");
    const secretVersion = typeof secretVersionName === "string" ? secretVersionName : undefined;
    let secretDestroyedOrMissing = true;
    if (secretVersion) {
      secretDestroyedOrMissing = false;
      try {
        await options.destroyCredential(secretVersion);
        summary.destroyedSecrets += 1;
        secretDestroyedOrMissing = true;
      } catch (error) {
        summary.failedSecretDestroys += 1;
        logger.warn(`Failed to destroy provider credential secret for uid:${uid.slice(0, 8)}/${doc.id}; keeping ref for retry.`, error);
      }
    }
    if (secretDestroyedOrMissing) {
      await batcher.delete(doc.ref);
    }
  }

  if (summary.failedSecretDestroys > 0) {
    await batcher.flush();
    return summary;
  }

  await deleteDocumentTree(db.doc(`users/${uid}`), batcher);
  await deleteDocumentTree(db.doc(`workspaces/${userWorkspaceID(uid)}`), batcher);
  await batcher.flush();

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

async function deleteCollectionTree(collection: AccountDeletionCollectionReference, batcher: DeleteBatcher): Promise<void> {
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
