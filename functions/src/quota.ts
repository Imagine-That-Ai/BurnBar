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
  QuotaSnapshotDoc,
  QuotaRefreshResult,
} from "./types.js";
import { retrieveCredential } from "./secrets.js";
import { minimaxAdapter } from "./providers/minimax.js";
import { zaiAdapter } from "./providers/zai.js";
import { factoryAdapter } from "./providers/factory.js";
import { cursorAdapter } from "./providers/cursor.js";

const ADAPTERS = {
  minimax: minimaxAdapter,
  zai: zaiAdapter,
  factory: factoryAdapter,
  cursor: cursorAdapter,
} as const;

/** Schema version for quota snapshot documents. */
const QUOTA_SCHEMA_VERSION = 1;

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

  const connDoc = await connRef.get();
  if (!connDoc.exists) {
    throw new Error(`No connection doc found for ${provider}`);
  }
  const conn = connDoc.data() as ProviderConnectionDoc;

  if (conn.status !== "connected") {
    throw new Error(`Connection ${provider} is not active (${conn.status})`);
  }

  const secretVersionName = connDoc.get("secretVersionName") as string | undefined;
  if (!secretVersionName) {
    throw new Error(`No secret version reference for ${provider}`);
  }

  const credential = await retrieveCredential(secretVersionName);
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
