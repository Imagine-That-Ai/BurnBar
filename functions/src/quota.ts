/**
 * @fileoverview Quota refresh orchestration.
 *
 * Looks up active provider connections for a user, retrieves the encrypted
 * credential from Secret Manager, dispatches to the correct adapter, and
 * writes the resulting quota snapshot to Firestore.
 */

import { Timestamp, type Firestore } from "firebase-admin/firestore";
import type {
  Provider,
  ProviderConnectionDoc,
  ProviderAccountDoc,
  ProviderAccountSecretRefDoc,
  HostedQuotaEntitlementDoc,
  ProviderAccountStorageScope,
  QuotaSnapshotDoc,
  QuotaRefreshResult,
  QuotaBucket,
} from "./types.js";
import { getConfig } from "./config.js";
import { hostedQuotaRunnerToken } from "./hostedRunnerConfig.js";
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
const HOSTED_RUNNER_PROVIDERS = new Set<Provider>(["codex"]);

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
  if (!["connected", "stale", "error"].includes(account.status)) {
    throw new Error(`Provider account ${accountID} is not active (${account.status})`);
  }
  if (
    account.storageScope === "server_private" &&
    HOSTED_RUNNER_PROVIDERS.has(account.providerID as Provider)
  ) {
    return refreshHostedQuotaAccount(db, uid, account);
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

async function refreshHostedQuotaAccount(
  db: Firestore,
  uid: string,
  account: ProviderAccountDoc
): Promise<QuotaSnapshotDoc | null> {
  await requireHostedQuotaEntitlement(db, uid);
  await consumeHostedRefreshBudget(db, uid, account.id);

  const credential = await retrieveAccountSecret(db, uid, account.id);
  const now = new Date().toISOString();
  try {
    const snapshot = await fetchHostedRunnerSnapshot(account, credential, now);
    const snapshotID = `${account.providerID}_${account.id}_${safeDocSegment(snapshot.sourceId)}`;
    const snapRef = db.doc(`users/${uid}/quota_snapshots/${snapshotID}`);
    const accountRef = db.doc(`users/${uid}/provider_accounts/${account.id}`);
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
  } catch (err) {
    await db.doc(`users/${uid}/provider_accounts/${account.id}`).update({
      status: "error",
      lastErrorCode: "hosted_runner_failed",
      lastRefreshAt: now,
      updatedAt: now,
    });
    throw err;
  }
}

async function requireHostedQuotaEntitlement(
  db: Firestore,
  uid: string
): Promise<void> {
  const [hostedSnap, proSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get(),
    db.doc(`users/${uid}/entitlements/burnbar_pro`).get(),
  ]);
  if (isActiveHostedQuotaEntitlement(hostedSnap.data() as HostedQuotaEntitlementDoc | undefined)) return;
  if (isActivePremiumEntitlement(proSnap.data())) return;
  throw new Error("permission-denied: Hosted Quota Sync or BurnBar Pro subscription required.");
}

function isActiveHostedQuotaEntitlement(entitlement: HostedQuotaEntitlementDoc | undefined): boolean {
  if (!entitlement) return false;
  const expiresAtMs = entitlement.expiresAt ? Date.parse(entitlement.expiresAt) : 0;
  return entitlement.active === true
    && entitlement.productID === getConfig().hostedQuotaProductID
    && Number.isFinite(expiresAtMs)
    && expiresAtMs > Date.now();
}

function isActivePremiumEntitlement(raw: Record<string, unknown> | undefined): boolean {
  if (!raw || raw.active !== true) return false;
  const productID = typeof raw.productID === "string" ? raw.productID : "";
  if (
    productID !== getConfig().hostedQuotaProductID &&
    productID !== getConfig().burnBarProProductID &&
    productID !== getConfig().googlePlaySubscriptionProductID
  ) {
    return false;
  }
  const expireAt = raw.expireAt;
  if (expireAt && typeof expireAt === "object") {
    const candidate = expireAt as { toMillis?: () => number };
    if (typeof candidate.toMillis === "function") {
      return candidate.toMillis() > Date.now();
    }
  }
  const expiresAtMs = raw.expiresAt ? Date.parse(String(raw.expiresAt)) : 0;
  return Number.isFinite(expiresAtMs) && expiresAtMs > Date.now();
}

async function consumeHostedRefreshBudget(
  db: Firestore,
  uid: string,
  accountID: string
): Promise<void> {
  const cfg = getConfig();
  const now = new Date();
  const dayKey = now.toISOString().slice(0, 10).replace(/-/g, "");
  const monthKey = now.toISOString().slice(0, 7).replace("-", "");
  const dailyLimit = Math.max(1, cfg.hostedQuotaDailyRefreshLimit);
  const monthlyLimit = Math.max(dailyLimit, cfg.hostedQuotaMonthlyRefreshLimit);
  const dailyRef = db.doc(
    `users/${uid}/_rate_limits/hosted_quota_${safeDocSegment(accountID)}_${dayKey}`
  );
  const monthlyRef = db.doc(
    `users/${uid}/_rate_limits/hosted_quota_${safeDocSegment(accountID)}_${monthKey}`
  );

  await db.runTransaction(async (tx) => {
    const [dailySnap, monthlySnap] = await Promise.all([
      tx.get(dailyRef),
      tx.get(monthlyRef),
    ]);
    const dailyCount = numberField(dailySnap.get("attempts"));
    const monthlyCount = numberField(monthlySnap.get("attempts"));
    if (dailyCount >= dailyLimit) {
      throw new Error(
        `resource-exhausted: hosted quota daily refresh limit reached (${dailyLimit}/day).`
      );
    }
    if (monthlyCount >= monthlyLimit) {
      throw new Error(
        `resource-exhausted: hosted quota monthly refresh limit reached (${monthlyLimit}/month).`
      );
    }
    const updatedAt = Timestamp.fromDate(now);
    tx.set(
      dailyRef,
      {
        attempts: dailyCount + 1,
        window: "daily",
        limit: dailyLimit,
        updatedAt,
        expireAt: Timestamp.fromMillis(now.getTime() + 8 * 24 * 60 * 60 * 1000),
      },
      { merge: true }
    );
    tx.set(
      monthlyRef,
      {
        attempts: monthlyCount + 1,
        window: "monthly",
        limit: monthlyLimit,
        updatedAt,
        expireAt: Timestamp.fromMillis(now.getTime() + 45 * 24 * 60 * 60 * 1000),
      },
      { merge: true }
    );
  });
}

async function fetchHostedRunnerSnapshot(
  account: ProviderAccountDoc,
  credential: string,
  now: string
): Promise<QuotaSnapshotDoc> {
  const { hostedQuotaRunnerURL } = getConfig();
  const runnerToken = hostedQuotaRunnerToken();
  if (!hostedQuotaRunnerURL) {
    throw new Error("failed-precondition: HOSTED_QUOTA_RUNNER_URL is not set.");
  }
  const endpoint = new URL("/v1/quota/refresh", hostedQuotaRunnerURL);
  if (endpoint.protocol !== "https:") {
    throw new Error("failed-precondition: hosted quota runner must use HTTPS.");
  }
  const response = await fetch(endpoint, {
    method: "POST",
    headers: stripUndefined({
      "content-type": "application/json",
      ...(runnerToken
        ? { authorization: `Bearer ${runnerToken}` }
        : {}),
    }),
    body: JSON.stringify({
      provider: account.providerID,
      accountID: account.id,
      credential,
    }),
  });
  if (!response.ok) {
    throw new Error(`hosted runner returned HTTP ${response.status}`);
  }
  const payload = (await response.json()) as Record<string, unknown>;
  const raw =
    payload.snapshot && typeof payload.snapshot === "object"
      ? (payload.snapshot as Record<string, unknown>)
      : payload;
  return normalizeRunnerSnapshot(raw, account, now);
}

function normalizeRunnerSnapshot(
  raw: Record<string, unknown>,
  account: ProviderAccountDoc,
  now: string
): QuotaSnapshotDoc {
  const provider = account.providerID as Provider;
  const buckets = sanitizeBuckets(raw.buckets);
  if (buckets.length === 0) {
    throw new Error("hosted runner returned no quota buckets");
  }
  return stripUndefined({
    sourceKind: "provider",
    sourceId: safeDocSegment(
      trimmedString(raw.sourceId, "hosted-runner", 96) ?? "hosted-runner"
    ),
    provider,
    providerID: account.providerID,
    accountID: account.id,
    accountLabel: account.label,
    accountStorageScope: account.storageScope as ProviderAccountStorageScope,
    fetchedAt: parseISOOrNow(raw.fetchedAt, now),
    source: trimmedString(raw.source, "Hosted quota runner", 160),
    confidence: parseConfidence(raw.confidence),
    managementURL: parseURLString(raw.managementURL),
    statusMessage: trimmedString(raw.statusMessage, undefined, 240),
    buckets,
    schemaVersion: QUOTA_SCHEMA_VERSION,
    updatedAt: now,
  }) as QuotaSnapshotDoc;
}

function sanitizeBuckets(raw: unknown): QuotaBucket[] {
  if (!Array.isArray(raw)) return [];
  return raw.slice(0, 16).flatMap((item): QuotaBucket[] => {
    if (!item || typeof item !== "object") return [];
    const candidate = item as Record<string, unknown>;
    const name = trimmedString(candidate.name, undefined, 80);
    if (!name) return [];
    const used = finiteNumber(candidate.used, 0);
    const limit = finiteNumber(candidate.limit, -1);
    const remaining = finiteNumber(
      candidate.remaining,
      limit >= 0 ? Math.max(0, limit - used) : -1
    );
    return [
      stripUndefined({
        name,
        used,
        limit,
        remaining,
        window: trimmedString(candidate.window, undefined, 64),
        // Pass-through: Firestore Timestamp from the Admin SDK or an ISO
        // 8601 string from legacy writers. Anything else is dropped so we
        // don't store untyped objects in the bucket doc.
        resetsAt: sanitizeResetsAt(candidate.resetsAt),
        meta:
          candidate.meta && typeof candidate.meta === "object"
            ? sanitizeMeta(candidate.meta as Record<string, unknown>)
            : undefined,
      }) as QuotaBucket,
    ];
  });
}

function sanitizeResetsAt(
  value: unknown
): QuotaBucket["resetsAt"] | undefined {
  if (!value) return undefined;
  if (typeof value === "string") {
    return trimmedString(value, undefined, 64);
  }
  // firebase-admin Timestamp has a `.toDate()` method; duck-type rather
  // than import the runtime class at module load (this file is shared
  // between Cloud Functions and other consumers).
  if (
    typeof value === "object" &&
    typeof (value as { toDate?: () => Date }).toDate === "function"
  ) {
    return value as QuotaBucket["resetsAt"];
  }
  return undefined;
}

function sanitizeMeta(meta: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(meta).slice(0, 16)) {
    if (!/^[a-zA-Z0-9_.-]{1,64}$/.test(key)) continue;
    if (isSecretLikeKey(key)) continue;
    if (
      typeof value === "string" ||
      typeof value === "number" ||
      typeof value === "boolean"
    ) {
      out[key] = value;
    }
  }
  return out;
}

function parseConfidence(raw: unknown): QuotaSnapshotDoc["confidence"] {
  return raw === "high" || raw === "medium" || raw === "low" || raw === "stale"
    ? raw
    : "high";
}

function parseURLString(raw: unknown): string | undefined {
  if (typeof raw !== "string" || !raw.trim()) return undefined;
  try {
    const url = new URL(raw.trim());
    return url.protocol === "https:" ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

function parseISOOrNow(raw: unknown, now: string): string {
  if (typeof raw !== "string") return now;
  const ms = Date.parse(raw);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : now;
}

function trimmedString(
  raw: unknown,
  fallback: string | undefined,
  max = 120
): string | undefined {
  if (typeof raw !== "string") return fallback;
  const value = raw.trim();
  if (!value) return fallback;
  return value.slice(0, max);
}

function finiteNumber(raw: unknown, fallback: number): number {
  const n = Number(raw);
  return Number.isFinite(n) ? n : fallback;
}

function numberField(raw: unknown): number {
  return Number.isFinite(Number(raw)) ? Number(raw) : 0;
}

function safeDocSegment(raw: string): string {
  return raw
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "") || "hosted";
}

function isSecretLikeKey(key: string): boolean {
  const lower = key.toLowerCase();
  return (
    lower.includes("token") ||
    lower.includes("secret") ||
    lower.includes("authorization") ||
    lower.includes("credential") ||
    lower.includes("cookie") ||
    lower.includes("password")
  );
}

function stripUndefined<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, v]) => v !== undefined)
  ) as T;
}

export const __testing__ = {
  normalizeRunnerSnapshot,
  sanitizeBuckets,
  safeDocSegment,
};
