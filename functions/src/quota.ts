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
  UploadedQuotaSnapshotInput,
  QuotaBucket,
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

export async function retrieveAccountSecret(
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

const SUPPORTED_PROVIDER_SET = new Set<string>([
  "openai",
  "minimax",
  "zai",
  "factory",
  "cursor",
  "claude-code",
  "codex",
]);

const MAX_REMOTE_BUCKETS = 16;

function safeDocIDPart(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 120) || "unknown";
}

function requireSafeDocID(label: string, raw: unknown): string {
  if (typeof raw !== "string" || !raw.trim()) {
    throw new Error(`invalid-argument: ${label} must be a non-empty string.`);
  }
  const safe = safeDocIDPart(raw.trim());
  if (!safe) {
    throw new Error(`invalid-argument: ${label} must contain letters or numbers.`);
  }
  return safe;
}

function boundedString(raw: unknown, fallback: string, max: number): string {
  if (typeof raw !== "string") return fallback;
  const trimmed = raw.trim();
  return (trimmed || fallback).slice(0, max);
}

function optionalBoundedString(raw: unknown, max: number): string | undefined {
  if (typeof raw !== "string") return undefined;
  const trimmed = raw.trim();
  return trimmed ? trimmed.slice(0, max) : undefined;
}

function isoDateString(raw: unknown, fallback: string): string {
  if (typeof raw !== "string") return fallback;
  const time = Date.parse(raw);
  return Number.isFinite(time) ? new Date(time).toISOString() : fallback;
}

function confidence(raw: unknown): QuotaSnapshotDoc["confidence"] {
  return raw === "high" || raw === "medium" || raw === "low" || raw === "stale"
    ? raw
    : "medium";
}

function num(raw: unknown, fallback = 0): number {
  const n = Number(raw);
  return Number.isFinite(n) ? n : fallback;
}

function sanitizeBucket(raw: unknown): QuotaBucket {
  const data = raw && typeof raw === "object" && !Array.isArray(raw)
    ? (raw as Record<string, unknown>)
    : {};
  const limit = num(data.limit, -1);
  const used = Math.max(0, num(data.used));
  const remaining = limit >= 0 ? Math.max(0, num(data.remaining, limit - used)) : num(data.remaining, -1);
  const metaInput = data.meta && typeof data.meta === "object" && !Array.isArray(data.meta)
    ? (data.meta as Record<string, unknown>)
    : undefined;
  const meta = metaInput
    ? Object.fromEntries(
        Object.entries(metaInput)
          .slice(0, 20)
          .map(([key, value]) => [String(key).slice(0, 80), String(value).slice(0, 300)])
      )
    : undefined;
  return {
    name: boundedString(data.name, "quota", 120),
    used,
    limit,
    remaining,
    ...(typeof data.window === "string" ? { window: data.window.slice(0, 80) } : {}),
    ...(meta ? { meta } : {}),
  };
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

/**
 * On-demand remote quota snapshot upload for provider accounts.
 *
 * This is intentionally an ingest endpoint, not a scheduler. A signed-in app
 * must invoke it for a specific provider account after it has fetched or
 * observed quota data. The server validates account ownership and provider
 * identity before writing the shared snapshot.
 */
export async function uploadUserProviderAccountQuotaSnapshot(
  db: Firestore,
  uid: string,
  input: UploadedQuotaSnapshotInput
): Promise<QuotaSnapshotDoc> {
  const providerRaw = input.providerID ?? input.provider;
  if (typeof providerRaw !== "string" || !SUPPORTED_PROVIDER_SET.has(providerRaw)) {
    throw new Error(`invalid-argument: unsupported provider ${String(providerRaw)}.`);
  }
  const provider = providerRaw as Provider;
  const accountID = requireSafeDocID("accountID", input.accountID);

  const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
  const accountSnap = await accountRef.get();
  if (!accountSnap.exists) {
    throw new Error(`not-found: provider account ${accountID} does not exist.`);
  }

  const account = accountSnap.data() as ProviderAccountDoc;
  if (account.id !== accountID) {
    throw new Error(`failed-precondition: provider account ID mismatch for ${accountID}.`);
  }
  if (account.providerID !== provider) {
    throw new Error(`permission-denied: snapshot provider does not match account ${accountID}.`);
  }
  if (account.status === "deleted") {
    throw new Error(`failed-precondition: provider account ${accountID} is deleted.`);
  }

  const now = new Date().toISOString();
  const sourceId = boundedString(input.sourceId ?? input.sourceID, "remote-upload", 120);
  const bucketsInput = Array.isArray(input.buckets) ? input.buckets : [];
  const buckets = bucketsInput.slice(0, MAX_REMOTE_BUCKETS).map(sanitizeBucket);
  if (buckets.length === 0) {
    throw new Error("invalid-argument: quota snapshot must include at least one bucket.");
  }
  const managementURL = optionalBoundedString(input.managementURL, 500);
  const statusMessage = optionalBoundedString(input.statusMessage, 500);
  const snapshotID = [
    safeDocIDPart(provider),
    safeDocIDPart(accountID),
    safeDocIDPart(sourceId),
  ].join("_");
  const snapRef = db.doc(`users/${uid}/quota_snapshots/${snapshotID}`);

  const snapshot: QuotaSnapshotDoc = {
    id: snapshotID,
    sourceKind: "provider",
    sourceId,
    provider,
    providerID: account.providerID,
    accountID,
    accountLabel: account.label,
    accountStorageScope: account.storageScope,
    fetchedAt: isoDateString(input.fetchedAt, now),
    source: boundedString(input.source, "Remote quota upload", 180),
    confidence: confidence(input.confidence),
    ...(managementURL ? { managementURL } : {}),
    ...(statusMessage ? { statusMessage } : {}),
    buckets,
    schemaVersion: QUOTA_SCHEMA_VERSION,
    updatedAt: now,
  };

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
