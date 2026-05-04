/**
 * @fileoverview Quota refresh orchestration.
 *
 * Looks up active provider connections for a user, retrieves the encrypted
 * credential from Secret Manager, dispatches to the correct adapter, and
 * writes the resulting quota snapshot to Firestore.
 */

import { getFirestore, type Firestore } from "firebase-admin/firestore";
import type {
  Provider,
  ProviderConnectionDoc,
  ProviderAccountDoc,
  ProviderAccountSecretRefDoc,
  QuotaSnapshotDoc,
  QuotaRefreshResult,
} from "./types.js";
import { retrieveCredential } from "./secrets.js";
import { minimaxAdapter } from "./providers/minimax.js";
import { zaiAdapter } from "./providers/zai.js";
import { factoryAdapter } from "./providers/factory.js";
import { cursorAdapter } from "./providers/cursor.js";
import { openaiAdapter } from "./providers/openai.js";

const ADAPTERS = {
  openai: openaiAdapter,
  minimax: minimaxAdapter,
  zai: zaiAdapter,
  factory: factoryAdapter,
  cursor: cursorAdapter,
} as const;

/** Schema version for quota snapshot documents. */
const QUOTA_SCHEMA_VERSION = 2;

export function providerAccountSecretRefID(uid: string, accountID: string): string {
  const safeUid = uid.replace(/[^a-zA-Z0-9]/g, "-");
  const safeAccountID = accountID.replace(/[^a-zA-Z0-9_-]/g, "-");
  return `${safeUid}_${safeAccountID}`;
}

export function providerAccountSecretRefPath(uid: string, accountID: string): string {
  return `provider_account_secret_refs/${providerAccountSecretRefID(uid, accountID)}`;
}

async function retrieveAccountSecret(
  db: Firestore,
  uid: string,
  accountID: string
): Promise<string> {
  const ref = db.doc(providerAccountSecretRefPath(uid, accountID));
  const snap = await ref.get();
  if (!snap.exists) {
    throw new Error(`No private secret reference for account ${accountID}`);
  }
  const data = snap.data() as ProviderAccountSecretRefDoc;
  if (data.uid !== uid || data.accountID !== accountID || !data.secretVersionName) {
    throw new Error(`Secret reference does not match account ${accountID}`);
  }
  return retrieveCredential(data.secretVersionName);
}

/**
 * Refresh quota for a single user+provider pair.
 *
 * @param db - Firestore instance.
 * @param uid - Firebase Auth UID.
 * @param provider - Provider key.
 * @returns The written snapshot document (or null on failure).
 */
export async function refreshUserProviderQuota(
  db: Firestore,
  uid: string,
  provider: Provider
): Promise<QuotaSnapshotDoc | null> {
  const connRef = db.doc(`users/${uid}/provider_connections/${provider}`);
  const snapRef = db.doc(`users/${uid}/quota_snapshots/${provider}_default`);
  const legacyAccountID = `${provider}_default`;

  const connDoc = await connRef.get();
  if (!connDoc.exists) {
    throw new Error(`No connection doc found for ${provider}`);
  }
  const conn = connDoc.data() as ProviderConnectionDoc;

  if (conn.status !== "connected") {
    throw new Error(`Connection ${provider} is not active (${conn.status})`);
  }

  const credential = await retrieveAccountSecret(db, uid, legacyAccountID);
  const adapter = ADAPTERS[provider as keyof typeof ADAPTERS];
  if (!adapter) {
    throw new Error(`No adapter for provider ${provider}`);
  }

  const result: QuotaRefreshResult = await adapter.fetchQuota(credential, "default");

  const now = new Date().toISOString();

  if (!result.ok) {
    await connRef.update({
      status: "error",
      lastErrorCode: result.errorCode ?? "unknown",
      lastRefreshAt: now,
    });
    return null;
  }

  const snapshot: QuotaSnapshotDoc = {
    ...result.snapshot!,
    providerID: result.snapshot!.provider,
    accountID: legacyAccountID,
    accountLabel: conn.redactedLabel,
    accountStorageScope: "cloud_refreshable",
    schemaVersion: QUOTA_SCHEMA_VERSION,
    updatedAt: now,
  };

  await db.runTransaction(async (tx) => {
    tx.set(snapRef, snapshot, { merge: true });
    tx.update(connRef, {
      status: "connected",
      lastRefreshAt: now,
      lastErrorCode: null,
    });
  });

  return snapshot;
}

/**
 * Refresh quota for a single first-class provider account.
 */
export async function refreshUserProviderAccountQuota(
  db: Firestore,
  uid: string,
  accountID: string
): Promise<QuotaSnapshotDoc | null> {
  const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
  const accountSnap = await accountRef.get();
  if (!accountSnap.exists) {
    throw new Error(`No provider account doc found for ${accountID}`);
  }

  const account = accountSnap.data() as ProviderAccountDoc;
  if (account.id !== accountID) {
    throw new Error(`Provider account ID mismatch for ${accountID}`);
  }
  if (account.status !== "connected") {
    throw new Error(`Provider account ${accountID} is not active (${account.status})`);
  }
  if (account.storageScope !== "cloud_refreshable") {
    throw new Error(`Provider account ${accountID} is not cloud-refreshable`);
  }

  const provider = account.providerID as Provider;
  const adapter = ADAPTERS[provider as keyof typeof ADAPTERS];
  if (!adapter) {
    throw new Error(`No adapter for provider ${provider}`);
  }

  const credential = await retrieveAccountSecret(db, uid, accountID);
  const result: QuotaRefreshResult = await adapter.fetchQuota(credential, accountID);
  const now = new Date().toISOString();

  if (!result.ok) {
    await accountRef.update({
      status: "error",
      lastErrorCode: result.errorCode ?? "unknown",
      lastRefreshAt: now,
      updatedAt: now,
    });
    return null;
  }

  const snapshot: QuotaSnapshotDoc = {
    ...result.snapshot!,
    providerID: account.providerID,
    accountID,
    accountLabel: account.label,
    accountStorageScope: account.storageScope,
    schemaVersion: QUOTA_SCHEMA_VERSION,
    updatedAt: now,
  };
  const snapshotID = `${account.providerID}_${accountID}_${result.snapshot!.sourceId}`;
  const snapRef = db.doc(`users/${uid}/quota_snapshots/${snapshotID}`);

  await db.runTransaction(async (tx) => {
    tx.set(snapRef, snapshot, { merge: true });
    tx.update(accountRef, {
      status: "connected",
      lastRefreshAt: now,
      lastErrorCode: null,
      updatedAt: now,
    });
  });

  return snapshot;
}
