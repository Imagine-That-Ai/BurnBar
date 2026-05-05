/**
 * @fileoverview OpenBurnBar Cloud Functions v2 — main entry point.
 *
 * Exports:
 *   Callable:
 *     - connectProviderCredential
 *     - deleteProviderCredential
 *     - refreshProviderQuota
 *     - rebuildUsageRollups
 *   Background:
 *     - onUsageWritten       (Firestore trigger)
 *     - rebuildRollups       (scheduled, every 5 min)
 *     - refreshAllProviderQuotas (scheduled, every 15 min)
 *
 * Before deploying, ensure Firebase Admin is initialized (no args needed in
 * GCP because ADC is automatic; for local emulation set GOOGLE_APPLICATION_CREDENTIALS).
 */

import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { Timestamp, type Firestore } from "firebase-admin/firestore";
import { createHash, randomBytes } from "node:crypto";

import { getConfig } from "./config.js";
import { enforceAuthAndAppCheck } from "./auth.js";
import {
  storeCredential,
  destroyCredential,
} from "./secrets.js";
import {
  providerAccountSecretRefPath,
  refreshUserProviderAccountQuota,
  refreshUserProviderQuota,
} from "./quota.js";
import { computeUserRollups, writeUserRollups } from "./rollups.js";
import {
  isHermesConnectionDoc,
  pairingCodeDigest,
  parseHermesConnectionMode,
  parseHermesPlatform,
  randomPairingCode,
  safeEqualHex,
  sanitizeHermesCapabilities,
  validateHermesEndpointURL,
} from "./hermes.js";
import { minimaxAdapter } from "./providers/minimax.js";
import { zaiAdapter } from "./providers/zai.js";
import { factoryAdapter } from "./providers/factory.js";
import { cursorAdapter } from "./providers/cursor.js";
import { openaiAdapter } from "./providers/openai.js";

import type {
  Provider,
  SUPPORTED_PROVIDERS,
  ProviderAccountDoc,
  ProviderAccountSecretRefDoc,
  ProviderConnectionDoc,
  QuotaSnapshotDoc,
  HermesConnectionDoc,
  HermesConnectionMode,
  HermesPairingDoc,
  HermesConnectionAuditEventDoc,
  RollupJobDoc,
} from "./types.js";

import { onUsageWritten } from "./triggers.js";
import { rebuildRollups, refreshAllProviderQuotas } from "./scheduled.js";
import { HOSTED_RUNNER_SECRETS } from "./hostedRunnerConfig.js";

// ---------------------------------------------------------------------------
// Admin initialization
// ---------------------------------------------------------------------------
initializeApp();
const db = getFirestore();

// ---------------------------------------------------------------------------
// Provider adapter registry
// ---------------------------------------------------------------------------
const ADAPTERS = {
  openai: openaiAdapter,
  minimax: minimaxAdapter,
  zai: zaiAdapter,
  factory: factoryAdapter,
  cursor: cursorAdapter,
} as const;

const ALLOWED_PROVIDERS = new Set<string>([
  "openai",
  "minimax",
  "zai",
  "factory",
  "cursor",
  "claude-code",
  "codex",
]);

const CONNECTION_SCHEMA_VERSION = 1;
const ACCOUNT_SCHEMA_VERSION = 1;
const HERMES_SCHEMA_VERSION = 1;
const HERMES_PAIRING_TTL_MS = 10 * 60 * 1000;
const HERMES_PAIRING_AUDIT_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const HERMES_MAX_FAILED_PAIRING_ATTEMPTS = 5;
const HOSTED_QUOTA_PROVIDERS = new Set<string>(["codex"]);
const SELF_HOSTED_QUOTA_PROVIDERS = new Set<string>(["claude-code", "codex"]);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function assertProvider(provider: unknown): asserts provider is Provider {
  if (typeof provider !== "string" || !ALLOWED_PROVIDERS.has(provider)) {
    throw new Error(`Invalid or unsupported provider: ${String(provider)}`);
  }
}

function nowISO(): string {
  return new Date().toISOString();
}

function safeIdentifier(raw: unknown, prefix: string): string {
  const value = typeof raw === "string" ? raw.trim() : "";
  const safe = value
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return safe || `${prefix}_${randomBytes(8).toString("hex")}`;
}

function requiredIdentifier(raw: unknown, fieldName: string): string {
  if (typeof raw !== "string" || raw.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${fieldName} is required.`);
  }
  const safe = raw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  if (!safe) {
    throw new HttpsError("invalid-argument", `${fieldName} must contain letters or numbers.`);
  }
  return safe;
}

function optionalTrimmedString(raw: unknown): string | undefined {
  if (typeof raw !== "string") {
    return undefined;
  }
  const value = raw.trim();
  return value.length > 0 ? value : undefined;
}

function boundedTrimmedString(
  raw: unknown,
  fieldName: string,
  maxLength: number,
  required = false
): string | undefined {
  const value = optionalTrimmedString(raw);
  if (!value) {
    if (required) {
      throw new HttpsError("invalid-argument", `${fieldName} is required.`);
    }
    return undefined;
  }
  if (value.length > maxLength) {
    throw new HttpsError("invalid-argument", `${fieldName} must be ${maxLength} characters or fewer.`);
  }
  return value;
}

function stripUndefined<T extends object>(value: T): T {
  const output = {} as T;
  for (const [key, item] of Object.entries(value)) {
    if (item !== undefined) {
      (output as Record<string, unknown>)[key] = item;
    }
  }
  return output;
}

function normalizedSearchTerms(raw: string): string[] {
  const stopwords = new Set(["the", "and", "for", "with", "that", "this", "from", "how", "what", "where", "when", "why", "are", "was"]);
  return Array.from(
    new Set(
      raw
        .toLowerCase()
        .split(/[^a-z0-9]+/u)
        .map((part) => part.trim())
        .filter((part) => part.length >= 2 && !stopwords.has(part))
    )
  ).slice(0, 8);
}

function searchScore(text: string, terms: string[]): number {
  const lower = text.toLowerCase();
  return terms.reduce((score, term) => score + (lower.includes(term) ? 1 : 0), 0);
}

function sha256Hex(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

function callableDate(value: unknown): string | undefined {
  if (value instanceof Timestamp) {
    return value.toDate().toISOString();
  }
  if (value instanceof Date) {
    return value.toISOString();
  }
  if (typeof value === "string") {
    return value;
  }
  return undefined;
}

function serializeUsageForCallable(documentID: string, data: FirebaseFirestore.DocumentData): Record<string, unknown> {
  const provider = typeof data.provider === "string" ? data.provider : "unknown";
  const startTime = callableDate(data.startTime) ?? new Date(0).toISOString();
  const endTime = callableDate(data.endTime) ?? startTime;
  return stripUndefined({
    id: typeof data.id === "string" ? data.id : documentID,
    provider,
    sessionId: typeof data.sessionId === "string" ? data.sessionId : "",
    projectName: typeof data.projectName === "string" ? data.projectName : "",
    model: typeof data.model === "string" ? data.model : "unknown",
    inputTokens: typeof data.inputTokens === "number" ? data.inputTokens : 0,
    outputTokens: typeof data.outputTokens === "number" ? data.outputTokens : 0,
    cacheCreationTokens: typeof data.cacheCreationTokens === "number" ? data.cacheCreationTokens : 0,
    cacheReadTokens: typeof data.cacheReadTokens === "number" ? data.cacheReadTokens : 0,
    reasoningTokens: typeof data.reasoningTokens === "number" ? data.reasoningTokens : 0,
    totalTokens: typeof data.totalTokens === "number" ? data.totalTokens : 0,
    cost: typeof data.cost === "number" ? data.cost : 0,
    startTime,
    endTime,
    createdAt: callableDate(data.createdAt) ?? startTime,
    usageSource: typeof data.usageSource === "string" ? data.usageSource : "provider_log",
    sourceDeviceId: typeof data.deviceId === "string" ? data.deviceId : undefined,
    sourceDeviceName: typeof data.deviceName === "string" ? data.deviceName : undefined,
    isRemote: true,
    providerID: typeof data.providerID === "string" ? data.providerID : provider,
    providerAccountID: typeof data.providerAccountID === "string" ? data.providerAccountID : undefined,
    providerAccountLabel: typeof data.providerAccountLabel === "string" ? data.providerAccountLabel : undefined,
    providerAccountSource: typeof data.providerAccountSource === "string" ? data.providerAccountSource : undefined,
    provenanceMethod: "cloud_sync",
    provenanceConfidence: "exact",
    estimatorVersion: "",
  });
}

async function writeHermesAuditEvent(
  uid: string,
  event: Omit<HermesConnectionAuditEventDoc, "id" | "observedAt" | "schemaVersion" | "expireAt">
): Promise<void> {
  const id = `${Date.now()}_${randomBytes(6).toString("hex")}`;
  const expireAt = Timestamp.fromMillis(Date.now() + HERMES_PAIRING_AUDIT_TTL_MS);
  const doc: HermesConnectionAuditEventDoc = {
    id,
    ...event,
    observedAt: nowISO(),
    schemaVersion: HERMES_SCHEMA_VERSION,
    expireAt,
  };
  await db.doc(`users/${uid}/hermes_audit_events/${id}`).set(stripUndefined(doc));
}

function accountIDFor(provider: string, requestedAccountID?: string): string {
  const raw = requestedAccountID?.trim() || `${provider}_default`;
  const safe = raw
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  if (!safe) {
    throw new Error("invalid-argument: accountID must contain letters or numbers.");
  }
  return safe;
}

function connectionDocFromAccount(account: ProviderAccountDoc): ProviderConnectionDoc {
  return {
    provider: account.providerID as Provider,
    status:
      account.status === "disabled" || account.status === "deleted"
        ? "disconnected"
        : account.status,
    lastValidatedAt: account.lastValidatedAt,
    lastRefreshAt: account.lastRefreshAt,
    lastErrorCode: account.lastErrorCode,
    credentialKind: account.credentialKind,
    redactedLabel: account.redactedLabel,
    schemaVersion: CONNECTION_SCHEMA_VERSION,
  };
}

function assertHostedProvider(provider: string): asserts provider is Provider {
  assertProvider(provider);
  if (!HOSTED_QUOTA_PROVIDERS.has(provider)) {
    throw new HttpsError(
      "invalid-argument",
      "Hosted quota sync is currently available for Codex only."
    );
  }
}

function assertSelfHostedProvider(provider: string): asserts provider is Provider {
  assertProvider(provider);
  if (!SELF_HOSTED_QUOTA_PROVIDERS.has(provider)) {
    throw new HttpsError(
      "invalid-argument",
      "Self-hosted quota sync is available for Claude Code and Codex only."
    );
  }
}

async function assertActiveHostedQuotaEntitlement(uid: string): Promise<void> {
  const snap = await db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get();
  if (!snap.exists) {
    throw new HttpsError("permission-denied", "Hosted Quota Sync subscription required.");
  }
  const entitlement = snap.data() as {
    active?: boolean;
    productID?: string;
    expiresAt?: string;
  };
  const expiresAt = entitlement.expiresAt ? Date.parse(entitlement.expiresAt) : 0;
  if (
    entitlement.active !== true ||
    entitlement.productID !== getConfig().hostedQuotaProductID ||
    !Number.isFinite(expiresAt) ||
    expiresAt <= Date.now()
  ) {
    throw new HttpsError("permission-denied", "Hosted Quota Sync subscription is inactive.");
  }
}

function normalizeHostedCredential(raw: unknown): string {
  const credential = boundedTrimmedString(raw, "credential", getConfig().maxCredentialLength, true);
  if (!credential) {
    throw new HttpsError("invalid-argument", "credential is required.");
  }
  try {
    const candidate = credential.startsWith("{")
      ? credential
      : Buffer.from(credential, "base64").toString("utf8");
    JSON.parse(candidate);
    return credential;
  } catch {
    throw new HttpsError(
      "invalid-argument",
      "Codex hosted credentials must be ~/.codex/auth.json JSON or base64 JSON."
    );
  }
}

function safeSnapshotSourceID(raw: unknown): string {
  return (typeof raw === "string" ? raw : "self-hosted-runner")
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "") || "self-hosted-runner";
}

function sanitizeUploadedQuotaSnapshot(
  account: ProviderAccountDoc,
  raw: Record<string, unknown>
): QuotaSnapshotDoc {
  const now = nowISO();
  const bucketsRaw = Array.isArray(raw.buckets) ? raw.buckets : [];
  const buckets = bucketsRaw.slice(0, 16).flatMap((item): QuotaSnapshotDoc["buckets"] => {
    if (!item || typeof item !== "object") return [];
    const b = item as Record<string, unknown>;
    const name = boundedTrimmedString(b.name, "bucket.name", 80);
    if (!name) return [];
    const used = Number(b.used);
    const limit = Number(b.limit);
    const remaining = Number(b.remaining);
    if (!Number.isFinite(used) || !Number.isFinite(limit) || !Number.isFinite(remaining)) {
      return [];
    }
    return [stripUndefined({
      name,
      used,
      limit,
      remaining,
      window: boundedTrimmedString(b.window, "bucket.window", 64),
      meta: b.meta && typeof b.meta === "object"
        ? Object.fromEntries(
            Object.entries(b.meta as Record<string, unknown>)
              .filter(([key, value]) =>
                /^[a-zA-Z0-9_.-]{1,64}$/.test(key) &&
                !isSecretLikeMetadataKey(key) &&
                (typeof value === "string" ||
                  typeof value === "number" ||
                  typeof value === "boolean")
              )
              .slice(0, 16)
          )
        : undefined,
    })];
  });
  if (buckets.length === 0) {
    throw new HttpsError("invalid-argument", "At least one quota bucket is required.");
  }
  const confidence = raw.confidence === "high" ||
    raw.confidence === "medium" ||
    raw.confidence === "low" ||
    raw.confidence === "stale"
    ? raw.confidence
    : "high";
  return stripUndefined({
    sourceKind: "provider",
    sourceId: safeSnapshotSourceID(raw.sourceId),
    provider: account.providerID as Provider,
    providerID: account.providerID,
    accountID: account.id,
    accountLabel: account.label,
    accountStorageScope: account.storageScope,
    fetchedAt:
      typeof raw.fetchedAt === "string" && Number.isFinite(Date.parse(raw.fetchedAt))
        ? new Date(Date.parse(raw.fetchedAt)).toISOString()
        : now,
    source: boundedTrimmedString(raw.source, "source", 160) ?? "Self-hosted quota runner",
    confidence,
    managementURL:
      typeof raw.managementURL === "string" && raw.managementURL.startsWith("https://")
        ? raw.managementURL.slice(0, 2048)
        : undefined,
    statusMessage: boundedTrimmedString(raw.statusMessage, "statusMessage", 240),
    buckets,
    schemaVersion: 2,
    updatedAt: now,
  }) as QuotaSnapshotDoc;
}

function isSecretLikeMetadataKey(key: string): boolean {
  const lower = key.toLowerCase();
  return lower.includes("token")
    || lower.includes("secret")
    || lower.includes("authorization")
    || lower.includes("credential")
    || lower.includes("cookie")
    || lower.includes("password");
}

async function writePrivateSecretRef(
  uid: string,
  accountID: string,
  provider: Provider,
  secretVersionName: string,
  createdAt: string,
  updatedAt: string
): Promise<void> {
  const refDoc: ProviderAccountSecretRefDoc = {
    uid,
    providerID: provider,
    accountID,
    secretVersionName,
    createdAt,
    updatedAt,
  };
  await db.doc(providerAccountSecretRefPath(uid, accountID)).set(refDoc, { merge: true });
}

async function connectProviderAccountInternal(params: {
  uid: string;
  provider: Provider;
  credential: string;
  label?: string;
  accountID?: string;
  isDefault?: boolean;
}): Promise<ProviderAccountDoc> {
  const { uid, provider, credential } = params;
  const accountID = accountIDFor(provider, params.accountID);
  const label = params.label?.trim() || "Default";

  const adapter = ADAPTERS[provider as keyof typeof ADAPTERS];
  if (!adapter) {
    if (provider === "claude-code" || provider === "codex") {
      throw new Error("invalid-argument: Claude Code / Codex do not support backend credential connections.");
    }
    throw new Error("internal: no adapter for provider.");
  }

  const testResult = await adapter.testCredential(credential);
  if (!testResult.valid) {
    throw new Error(`invalid-argument: ${testResult.errorCode} — ${testResult.errorMessage}`);
  }

  const now = nowISO();
  const existing = await db.doc(`users/${uid}/provider_accounts/${accountID}`).get();
  const secretVersionName = await storeCredential(uid, provider, credential, accountID);
  await writePrivateSecretRef(
    uid,
    accountID,
    provider,
    secretVersionName,
    existing.exists ? (existing.get("createdAt") as string | undefined) ?? now : now,
    now
  );

  const accountDoc: ProviderAccountDoc = {
    id: accountID,
    providerID: provider,
    label,
    identityHint: undefined,
    status: "connected",
    credentialKind: testResult.credentialKind,
    storageScope: "cloud_refreshable",
    redactedLabel: testResult.redactedLabel,
    sourceDeviceID: undefined,
    linkedSwitcherProfileID: undefined,
    isDefault: params.isDefault ?? accountID.endsWith("_default"),
    sortKey: accountID.endsWith("_default") ? 0 : Date.now(),
    lastValidatedAt: now,
    lastRefreshAt: now,
    lastErrorCode: undefined,
    schemaVersion: ACCOUNT_SCHEMA_VERSION,
    createdAt: existing.exists ? (existing.get("createdAt") as string | undefined) ?? now : now,
    updatedAt: now,
  };

  await db.runTransaction(async (tx) => {
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    tx.set(accountRef, accountDoc, { merge: true });

    if (accountDoc.isDefault) {
      const legacyRef = db.doc(`users/${uid}/provider_connections/${provider}`);
      tx.set(legacyRef, connectionDocFromAccount(accountDoc), { merge: true });
    }
  });

  try {
    await refreshUserProviderAccountQuota(db, uid, accountID);
    if (accountDoc.isDefault) {
      await refreshUserProviderQuota(db, uid, provider);
    }
  } catch (quotaErr) {
    console.warn(`Initial quota refresh failed for ${uid}/${accountID}:`, quotaErr);
  }

  return accountDoc;
}

/**
 * Enforce rate limit for refreshProviderQuota per user+provider.
 * Uses Firestore as a lightweight TTL store.
 */
async function checkRefreshRateLimit(
  db: Firestore,
  uid: string,
  provider: string
): Promise<void> {
  const { refreshRateLimitSeconds } = getConfig();
  const ref = db.doc(`users/${uid}/_rate_limits/refresh_${provider}`);
  const snap = await ref.get();
  if (snap.exists) {
    const ts = snap.get("lastRefreshAt") as FirebaseFirestore.Timestamp;
    if (ts) {
      const elapsed = Date.now() - ts.toMillis();
      if (elapsed < refreshRateLimitSeconds * 1000) {
        throw new Error(
          `Rate limited: wait ${Math.ceil(
            (refreshRateLimitSeconds * 1000 - elapsed) / 1000
          )}s before refreshing ${provider}.`
        );
      }
    }
  }
  await ref.set({ lastRefreshAt: Timestamp.now() }, { merge: true });
}

async function checkHermesRateLimit(
  uid: string,
  action: string,
  windowSeconds: number
): Promise<void> {
  const ref = db.doc(`users/${uid}/_rate_limits/hermes_${action}`);
  const snap = await ref.get();
  if (snap.exists) {
    const ts = snap.get("lastAt") as FirebaseFirestore.Timestamp | undefined;
    if (ts) {
      const elapsed = Date.now() - ts.toMillis();
      if (elapsed < windowSeconds * 1000) {
        throw new HttpsError(
          "resource-exhausted",
          `Please wait ${Math.ceil((windowSeconds * 1000 - elapsed) / 1000)}s before retrying.`
        );
      }
    }
  }
  await ref.set({ lastAt: Timestamp.now() }, { merge: true });
}

// ---------------------------------------------------------------------------
// Callable: connectProviderAccount
// ---------------------------------------------------------------------------

export const connectProviderAccount = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      provider: string;
      credential: string;
      label?: string;
      accountID?: string;
    }>
  ) => {
    const { provider, credential, label, accountID } = request.data;
    const uid = request.auth?.uid;

    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);
    assertProvider(provider);

    if (typeof credential !== "string" || !credential) {
      throw new Error("invalid-argument: credential must be a non-empty string.");
    }
    if (credential.length > getConfig().maxCredentialLength) {
      throw new Error("invalid-argument: credential exceeds max length.");
    }

    return connectProviderAccountInternal({
      uid,
      provider,
      credential,
      label,
      accountID,
      isDefault: accountID == null,
    });
  }
);

// ---------------------------------------------------------------------------
// Callable: connectProviderCredential (legacy compatibility)
// ---------------------------------------------------------------------------

export const connectProviderCredential = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ provider: string; credential: string }>) => {
    const { provider, credential } = request.data;
    const uid = request.auth?.uid;

    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);

    assertProvider(provider);

    if (typeof credential !== "string" || !credential) {
      throw new Error("invalid-argument: credential must be a non-empty string.");
    }
    if (credential.length > getConfig().maxCredentialLength) {
      throw new Error("invalid-argument: credential exceeds max length.");
    }

    const accountDoc = await connectProviderAccountInternal({
      uid,
      provider: provider as Provider,
      credential,
      label: "Default",
      accountID: `${provider}_default`,
      isDefault: true,
    });

    return connectionDocFromAccount(accountDoc);
  }
);

// ---------------------------------------------------------------------------
// Callable: connectHostedQuotaAccount
// ---------------------------------------------------------------------------

export const connectHostedQuotaAccount = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      provider: string;
      credential: string;
      label?: string;
      accountID?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before adding hosted quota sync.");
    }
    enforceAuthAndAppCheck(request, uid);
    const provider = String(request.data.provider ?? "");
    assertHostedProvider(provider);
    await assertActiveHostedQuotaEntitlement(uid);

    const credential = normalizeHostedCredential(request.data.credential);
    const accountID = accountIDFor(provider, request.data.accountID);
    const label = boundedTrimmedString(request.data.label, "label", 80) ?? "Hosted Codex";
    const now = nowISO();
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const existing = await accountRef.get();
    const createdAt = existing.exists
      ? (existing.get("createdAt") as string | undefined) ?? now
      : now;
    const secretVersionName = await storeCredential(uid, provider, credential, accountID);
    await writePrivateSecretRef(uid, accountID, provider, secretVersionName, createdAt, now);

    const accountDoc: ProviderAccountDoc = {
      id: accountID,
      providerID: provider,
      label,
      identityHint: undefined,
      status: "connected",
      credentialKind: "session",
      storageScope: "server_private",
      redactedLabel: "Codex auth.json stored in Secret Manager",
      sourceDeviceID: undefined,
      linkedSwitcherProfileID: undefined,
      isDefault: request.data.accountID == null || accountID.endsWith("_default"),
      sortKey: accountID.endsWith("_default") ? 0 : Date.now(),
      lastValidatedAt: now,
      lastRefreshAt: undefined,
      lastErrorCode: undefined,
      schemaVersion: ACCOUNT_SCHEMA_VERSION,
      createdAt,
      updatedAt: now,
    };

    await db.runTransaction(async (tx) => {
      tx.set(accountRef, stripUndefined(accountDoc), { merge: true });
      if (accountDoc.isDefault) {
        tx.set(
          db.doc(`users/${uid}/provider_connections/${provider}`),
          connectionDocFromAccount(accountDoc),
          { merge: true }
        );
      }
    });
    return accountDoc;
  }
);

// ---------------------------------------------------------------------------
// Callable: connectSelfHostedQuotaAccount
// ---------------------------------------------------------------------------

export const connectSelfHostedQuotaAccount = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      provider: string;
      label?: string;
      accountID?: string;
      sourceDeviceID?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before adding self-hosted quota sync.");
    }
    enforceAuthAndAppCheck(request, uid);
    const provider = String(request.data.provider ?? "");
    assertSelfHostedProvider(provider);

    const accountID = accountIDFor(provider, request.data.accountID);
    const label =
      boundedTrimmedString(request.data.label, "label", 80) ??
      `${provider === "codex" ? "Codex" : "Claude Code"} self-hosted`;
    const now = nowISO();
    const existing = await db.doc(`users/${uid}/provider_accounts/${accountID}`).get();
    const accountDoc: ProviderAccountDoc = {
      id: accountID,
      providerID: provider,
      label,
      identityHint: undefined,
      status: "connected",
      credentialKind: "session",
      storageScope: "local_only",
      redactedLabel: "Self-hosted runner",
      sourceDeviceID: boundedTrimmedString(request.data.sourceDeviceID, "sourceDeviceID", 128),
      linkedSwitcherProfileID: undefined,
      isDefault: request.data.accountID == null || accountID.endsWith("_default"),
      sortKey: accountID.endsWith("_default") ? 0 : Date.now(),
      lastValidatedAt: now,
      lastRefreshAt: undefined,
      lastErrorCode: undefined,
      schemaVersion: ACCOUNT_SCHEMA_VERSION,
      createdAt: existing.exists ? (existing.get("createdAt") as string | undefined) ?? now : now,
      updatedAt: now,
    };

    await db.runTransaction(async (tx) => {
      tx.set(db.doc(`users/${uid}/provider_accounts/${accountID}`), stripUndefined(accountDoc), { merge: true });
      if (accountDoc.isDefault) {
        tx.set(
          db.doc(`users/${uid}/provider_connections/${provider}`),
          connectionDocFromAccount(accountDoc),
          { merge: true }
        );
      }
    });
    return accountDoc;
  }
);

// ---------------------------------------------------------------------------
// Callable: uploadProviderQuotaSnapshot
// ---------------------------------------------------------------------------

export const uploadProviderQuotaSnapshot = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<Record<string, unknown>>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before uploading quota snapshots.");
    }
    enforceAuthAndAppCheck(request, uid);
    const accountID = requiredIdentifier(request.data.accountID, "accountID");
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const accountSnap = await accountRef.get();
    if (!accountSnap.exists) {
      throw new HttpsError("not-found", "Provider account not found.");
    }
    const account = accountSnap.data() as ProviderAccountDoc;
    if (account.storageScope !== "local_only") {
      throw new HttpsError(
        "failed-precondition",
        "Only self-hosted local-only accounts can upload runner snapshots."
      );
    }
    assertSelfHostedProvider(account.providerID);
    const snapshot = sanitizeUploadedQuotaSnapshot(account, request.data);
    const snapshotID = `${account.providerID}_${account.id}_${snapshot.sourceId}`;
    const now = nowISO();
    await db.runTransaction(async (tx) => {
      tx.set(db.doc(`users/${uid}/quota_snapshots/${snapshotID}`), snapshot, { merge: true });
      tx.update(accountRef, {
        status: "connected",
        lastRefreshAt: now,
        lastErrorCode: null,
        updatedAt: now,
      });
    });
    return snapshot;
  }
);

// ---------------------------------------------------------------------------
// Callable: deleteHostedQuotaCredentials
// ---------------------------------------------------------------------------

export const deleteHostedQuotaCredentials = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ accountID: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before deleting hosted credentials.");
    }
    enforceAuthAndAppCheck(request, uid);
    const accountID = accountIDFor("account", request.data.accountID);
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const accountSnap = await accountRef.get();
    if (!accountSnap.exists) {
      throw new HttpsError("not-found", "Provider account not found.");
    }
    const account = accountSnap.data() as ProviderAccountDoc;
    if (account.storageScope !== "server_private") {
      throw new HttpsError("failed-precondition", "Account is not a hosted quota account.");
    }
    const privateRef = db.doc(providerAccountSecretRefPath(uid, accountID));
    const privateSnap = await privateRef.get();
    const secretVersionName = privateSnap.exists
      ? (privateSnap.get("secretVersionName") as string | undefined)
      : undefined;
    if (secretVersionName) {
      await destroyCredential(secretVersionName);
    }
    const now = nowISO();
    await db.runTransaction(async (tx) => {
      tx.delete(privateRef);
      tx.set(
        accountRef,
        {
          status: "deleted",
          lastValidatedAt: null,
          lastRefreshAt: null,
          lastErrorCode: null,
          updatedAt: now,
        },
        { merge: true }
      );
    });
    return { success: true, accountID };
  }
);

// ---------------------------------------------------------------------------
// Callable: updateProviderAccount
// ---------------------------------------------------------------------------

export const updateProviderAccount = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      accountID: string;
      label?: string;
      isDefault?: boolean;
      disabled?: boolean;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);

    const accountID = accountIDFor("account", request.data.accountID);
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const snap = await accountRef.get();
    if (!snap.exists) {
      throw new Error("not-found: provider account does not exist.");
    }
    const current = snap.data() as ProviderAccountDoc;
    const now = nowISO();
    const next: Partial<ProviderAccountDoc> = {
      updatedAt: now,
    };
    if (typeof request.data.label === "string" && request.data.label.trim()) {
      next.label = request.data.label.trim();
    }
    if (typeof request.data.isDefault === "boolean") {
      next.isDefault = request.data.isDefault;
    }
    if (typeof request.data.disabled === "boolean") {
      next.status = request.data.disabled ? "disabled" : "connected";
    }

    await db.runTransaction(async (tx) => {
      if (next.isDefault === true) {
        const siblingSnap = await db
          .collection(`users/${uid}/provider_accounts`)
          .where("providerID", "==", current.providerID)
          .where("isDefault", "==", true)
          .get();

        for (const sibling of siblingSnap.docs) {
          if (sibling.id !== accountID) {
            tx.set(sibling.ref, { isDefault: false, updatedAt: now }, { merge: true });
          }
        }
      }

      tx.set(accountRef, next, { merge: true });
    });

    const updatedSnap = await accountRef.get();
    const updated = updatedSnap.data() as ProviderAccountDoc;
    if (updated.isDefault) {
      await db.doc(`users/${uid}/provider_connections/${updated.providerID}`).set(
        connectionDocFromAccount(updated),
        { merge: true }
      );
    }
    if (current.isDefault && !updated.isDefault) {
      await db.doc(`users/${uid}/provider_connections/${updated.providerID}`).set(
        { status: "disconnected", updatedAt: now },
        { merge: true }
      );
    }
    return updated;
  }
);

// ---------------------------------------------------------------------------
// Callable: deleteProviderCredential
// ---------------------------------------------------------------------------

export const deleteProviderAccount = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ accountID: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);

    const accountID = accountIDFor("account", request.data.accountID);
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const accountSnap = await accountRef.get();
    if (!accountSnap.exists) {
      throw new Error("not-found: provider account does not exist.");
    }
    const account = accountSnap.data() as ProviderAccountDoc;

    const privateRef = db.doc(providerAccountSecretRefPath(uid, accountID));
    const privateSnap = await privateRef.get();
    const secretVersionName = privateSnap.exists
      ? (privateSnap.get("secretVersionName") as string | undefined)
      : undefined;

    if (secretVersionName) {
      try {
        await destroyCredential(secretVersionName);
      } catch (err) {
        console.warn(`Failed to destroy provider account secret for ${accountID}:`, err);
      }
    }

    const now = nowISO();
    await db.runTransaction(async (tx) => {
      tx.delete(privateRef);
      tx.set(
        accountRef,
        {
          status: "deleted",
          lastValidatedAt: null,
          lastRefreshAt: null,
          lastErrorCode: null,
          updatedAt: now,
        },
        { merge: true }
      );
      if (account.isDefault) {
        tx.set(
          db.doc(`users/${uid}/provider_connections/${account.providerID}`),
          {
            status: "disconnected",
            lastValidatedAt: null,
            lastRefreshAt: null,
            lastErrorCode: null,
            updatedAt: now,
          },
          { merge: true }
        );
      }
    });

    const snapshotQuery = await db
      .collection(`users/${uid}/quota_snapshots`)
      .where("accountID", "==", accountID)
      .get();
    const batch = db.batch();
    for (const doc of snapshotQuery.docs) {
      batch.set(
        doc.ref,
        {
          confidence: "stale",
          statusMessage: "Credential deleted; snapshot is stale.",
          updatedAt: now,
        },
        { merge: true }
      );
    }
    await batch.commit();

    return { success: true, accountID };
  }
);

export const deleteProviderCredential = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ provider: string }>) => {
    const { provider } = request.data;
    const uid = request.auth?.uid;

    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);
    assertProvider(provider);

    const accountID = `${provider}_default`;
    const privateRef = db.doc(providerAccountSecretRefPath(uid, accountID));
    const privateSnap = await privateRef.get();
    const secretVersionName = privateSnap.exists
      ? (privateSnap.get("secretVersionName") as string | undefined)
      : undefined;

    // Destroy the secret payload if we know where it lives.
    if (secretVersionName) {
      try {
        await destroyCredential(secretVersionName);
      } catch (err) {
        console.warn(`Failed to destroy provider credential secret for ${uid}/${accountID}:`, err);
      }
    }

    const now = nowISO();
    await privateRef.delete();
    await db.doc(`users/${uid}/provider_accounts/${accountID}`).set(
      {
        status: "deleted",
        lastValidatedAt: null,
        lastRefreshAt: null,
        lastErrorCode: null,
        updatedAt: now,
      },
      { merge: true }
    );
    const connRef = db.doc(`users/${uid}/provider_connections/${provider}`);
    await connRef.set(
      {
        status: "disconnected",
        lastValidatedAt: null,
        lastRefreshAt: null,
        lastErrorCode: null,
        updatedAt: now,
      },
      { merge: true }
    );

    // Stale-mark the quota snapshot.
    const snapRef = db.doc(`users/${uid}/quota_snapshots/${provider}_default`);
    await snapRef.set(
      {
        confidence: "stale",
        statusMessage: "Credential deleted; snapshot is stale.",
        updatedAt: now,
      },
      { merge: true }
    );

    return { success: true, provider };
  }
);

// ---------------------------------------------------------------------------
// Callable: refreshProviderQuota
// ---------------------------------------------------------------------------

export const refreshProviderAccountQuota = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
    secrets: HOSTED_RUNNER_SECRETS,
  },
  async (request: CallableRequest<{ accountID: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);

    const accountID = accountIDFor("account", request.data.accountID);
    const snapshot = await refreshUserProviderAccountQuota(db, uid, accountID);
    if (!snapshot) {
      throw new Error("failed-precondition: quota refresh returned no snapshot.");
    }
    return snapshot;
  }
);

export const refreshProviderQuota = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
    secrets: HOSTED_RUNNER_SECRETS,
  },
  async (request: CallableRequest<{ provider: string }>) => {
    const { provider } = request.data;
    const uid = request.auth?.uid;

    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);
    assertProvider(provider);

    await checkRefreshRateLimit(db, uid, provider);

    const accountSnapshot = await db
      .collection(`users/${uid}/provider_accounts`)
      .where("providerID", "==", provider)
      .where("status", "==", "connected")
      .get();

    if (!accountSnapshot.empty) {
      const snapshots = [];
      const skippedAccountIDs: string[] = [];
      const errors: Array<{ accountID: string; message: string }> = [];

      for (const doc of accountSnapshot.docs) {
        const account = doc.data() as ProviderAccountDoc;
        if (account.storageScope !== "cloud_refreshable") {
          skippedAccountIDs.push(account.id);
          continue;
        }

        try {
          const snapshot = await refreshUserProviderAccountQuota(db, uid, account.id);
          if (snapshot) {
            snapshots.push(snapshot);
          }
        } catch (err) {
          errors.push({
            accountID: account.id,
            message: (err as Error).message,
          });
        }
      }

      if (snapshots.length === 0 && errors.length > 0) {
        throw new Error(
          `failed-precondition: no ${provider} accounts refreshed: ${errors
            .map((err) => `${err.accountID}: ${err.message}`)
            .join("; ")}`
        );
      }

      return {
        success: true,
        provider,
        refreshedAccountIDs: snapshots.map((snapshot) => snapshot.accountID),
        skippedAccountIDs,
        errorAccountIDs: errors.map((err) => err.accountID),
        snapshots,
      };
    }

    const snapshot = await refreshUserProviderQuota(db, uid, provider as Provider);
    if (!snapshot) {
      throw new Error("failed-precondition: legacy quota refresh returned no snapshot.");
    }

    return {
      success: true,
      provider,
      refreshedAccountIDs: [snapshot.accountID ?? `${provider}_default`],
      skippedAccountIDs: [],
      errorAccountIDs: [],
      snapshots: [snapshot],
    };
  }
);

// ---------------------------------------------------------------------------
// Callable: Hermes pairing and connection management
// ---------------------------------------------------------------------------

export const createHermesPairing = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      deviceId?: string;
      platform?: "ios" | "ipados" | "macos" | "web";
      displayName?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before creating a Hermes pairing.");
    }
    enforceAuthAndAppCheck(request, uid);
    await checkHermesRateLimit(uid, "create_pairing", 5);

    const code = randomPairingCode();
    const id = `pair_${randomBytes(12).toString("hex")}`;
    const now = nowISO();
    const expiresAt = new Date(Date.now() + HERMES_PAIRING_TTL_MS).toISOString();
    const expireAt = Timestamp.fromMillis(Date.now() + HERMES_PAIRING_TTL_MS);
    const doc: HermesPairingDoc = {
      id,
      status: "pending",
      codeHash: pairingCodeDigest(code),
      failedAttempts: 0,
      requestedByDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      requestedByPlatform: parseHermesPlatform(request.data.platform),
      displayName: boundedTrimmedString(request.data.displayName, "displayName", 80),
      expiresAt,
      expireAt,
      createdAt: now,
      updatedAt: now,
      schemaVersion: HERMES_SCHEMA_VERSION,
    };

    await db.doc(`users/${uid}/hermes_pairings/${id}`).set(stripUndefined(doc));
    await writeHermesAuditEvent(uid, {
      eventType: "pairing_created",
      pairingId: id,
      actorDeviceId: doc.requestedByDeviceId,
    });

    return { id, code, expiresAt };
  }
);

export const completeHermesPairing = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      pairingId: string;
      code: string;
      connectionId?: string;
      displayName?: string;
      mode?: HermesConnectionMode;
      profileName?: string;
      endpointURL?: string;
      advertisedModel?: string;
      capabilities?: string[];
      deviceId?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before completing a Hermes pairing.");
    }
    enforceAuthAndAppCheck(request, uid);
    await checkHermesRateLimit(uid, "complete_pairing", 1);

    const pairingId = requiredIdentifier(request.data.pairingId, "pairingId");
    const code = boundedTrimmedString(request.data.code, "code", 32, true);
    if (!code) {
      throw new HttpsError("invalid-argument", "code is required.");
    }

    const pairingRef = db.doc(`users/${uid}/hermes_pairings/${pairingId}`);
    const connectionId = safeIdentifier(request.data.connectionId, "hermes");
    const connectionRef = db.doc(`users/${uid}/hermes_connections/${connectionId}`);
    const now = nowISO();
    let failedAttempt = false;

    let connection: HermesConnectionDoc;
    try {
      connection = await db.runTransaction(async (tx) => {
      const pairingSnap = await tx.get(pairingRef);
      if (!pairingSnap.exists) {
        throw new HttpsError("not-found", "Pairing session not found.");
      }
      const pairing = pairingSnap.data() as HermesPairingDoc;
      if (Date.parse(pairing.expiresAt) <= Date.now() && pairing.status === "pending") {
        tx.set(pairingRef, { status: "expired", updatedAt: now }, { merge: true });
        throw new HttpsError("deadline-exceeded", "Pairing code has expired.");
      }
      if (!safeEqualHex(pairingCodeDigest(code), pairing.codeHash)) {
        failedAttempt = true;
        const failedAttempts = (pairing.failedAttempts ?? 0) + 1;
        tx.set(
          pairingRef,
          {
            failedAttempts,
            status: failedAttempts >= HERMES_MAX_FAILED_PAIRING_ATTEMPTS ? "revoked" : pairing.status,
            updatedAt: now,
          },
          { merge: true }
        );
        throw new HttpsError("permission-denied", "Pairing code mismatch.");
      }
      if (pairing.status === "completed") {
        const completedConnectionId = pairing.connectionId ?? connectionId;
        const existingSnap = await tx.get(db.doc(`users/${uid}/hermes_connections/${completedConnectionId}`));
        const existing = existingSnap.data() as Partial<HermesConnectionDoc> | undefined;
        if (existingSnap.exists && existing && isHermesConnectionDoc(existing)) {
          return existing;
        }
        throw new HttpsError("failed-precondition", "Pairing is completed but its connection is unavailable.");
      }
      if (pairing.status !== "pending") {
        throw new HttpsError("failed-precondition", "Pairing session is no longer pending.");
      }

      const mode = parseHermesConnectionMode(request.data.mode ?? "directURL");
      const endpointURL = validateHermesEndpointURL(request.data.endpointURL, mode);
      const capabilities = sanitizeHermesCapabilities(request.data.capabilities);
      const displayName =
        boundedTrimmedString(request.data.displayName, "displayName", 80) ??
        pairing.displayName ??
        "Hermes Host";
      const doc: HermesConnectionDoc = {
        id: connectionId,
        displayName,
        mode,
        status: "online",
        profileName: boundedTrimmedString(request.data.profileName, "profileName", 80),
        endpointURL,
        advertisedModel: boundedTrimmedString(request.data.advertisedModel, "advertisedModel", 160),
        capabilities,
        lastSeenAt: now,
        createdAt: now,
        updatedAt: now,
        schemaVersion: HERMES_SCHEMA_VERSION,
      };
      tx.set(connectionRef, stripUndefined(doc), { merge: true });
      tx.set(
        pairingRef,
        { status: "completed", connectionId, updatedAt: now },
        { merge: true }
      );
      return doc;
      });
    } catch (err) {
      if (failedAttempt) {
        await writeHermesAuditEvent(uid, {
          eventType: "pairing_failed",
          connectionId,
          pairingId,
          actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
        });
      }
      throw err;
    }

    await writeHermesAuditEvent(uid, {
      eventType: "pairing_completed",
      connectionId,
      pairingId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
    });
    await writeHermesAuditEvent(uid, {
      eventType: "connection_created",
      connectionId: connection.id,
      pairingId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      detail: { mode: connection.mode },
    });

    return stripUndefined(connection);
  }
);

export const listHermesConnections = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ includeRevoked?: boolean }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before listing Hermes connections.");
    }
    enforceAuthAndAppCheck(request, uid);

    const snap = await db.collection(`users/${uid}/hermes_connections`).get();
    const connections = snap.docs
      .map((doc) => doc.data() as Partial<HermesConnectionDoc>)
      .filter(isHermesConnectionDoc)
      .filter((doc) => request.data.includeRevoked === true || doc.status !== "revoked")
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
    return { connections };
  }
);

export const revokeHermesConnection = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ connectionId: string; deviceId?: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before revoking a Hermes connection.");
    }
    enforceAuthAndAppCheck(request, uid);
    await checkHermesRateLimit(uid, "revoke_connection", 2);

    const connectionId = requiredIdentifier(request.data.connectionId, "connectionId");
    const now = nowISO();
    const ref = db.doc(`users/${uid}/hermes_connections/${connectionId}`);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Hermes connection not found.");
      }
      tx.update(ref, { status: "revoked", updatedAt: now });
    });
    await writeHermesAuditEvent(uid, {
      eventType: "connection_revoked",
      connectionId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
    });
    return { success: true, connectionId };
  }
);

export const updateHermesConnectionStatus = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      connectionId: string;
      status: HermesConnectionDoc["status"];
      advertisedModel?: string;
      capabilities?: string[];
      deviceId?: string;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before updating a Hermes connection.");
    }
    enforceAuthAndAppCheck(request, uid);
    await checkHermesRateLimit(uid, "update_connection_status", 2);

    const allowedStatus = new Set<HermesConnectionDoc["status"]>([
      "pending",
      "online",
      "offline",
      "unauthorized",
      "revoked",
      "degraded",
    ]);
    if (!allowedStatus.has(request.data.status)) {
      throw new HttpsError("invalid-argument", "Unknown Hermes connection status.");
    }

    const connectionId = requiredIdentifier(request.data.connectionId, "connectionId");
    const now = nowISO();
    const update: Partial<HermesConnectionDoc> = {
      status: request.data.status,
      updatedAt: now,
    };
    const advertisedModel = boundedTrimmedString(request.data.advertisedModel, "advertisedModel", 160);
    if (advertisedModel) {
      update.advertisedModel = advertisedModel;
    }
    if (request.data.status === "online") {
      update.lastSeenAt = now;
    }
    if (Array.isArray(request.data.capabilities)) {
      update.capabilities = sanitizeHermesCapabilities(request.data.capabilities);
    }
    const ref = db.doc(`users/${uid}/hermes_connections/${connectionId}`);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Hermes connection not found.");
      }
      const current = snap.data() as Partial<HermesConnectionDoc>;
      if (current.status === "revoked") {
        throw new HttpsError("failed-precondition", "Revoked Hermes connections cannot be reactivated.");
      }
      tx.update(ref, stripUndefined(update));
    });
    await writeHermesAuditEvent(uid, {
      eventType: "connection_status_updated",
      connectionId,
      actorDeviceId: boundedTrimmedString(request.data.deviceId, "deviceId", 128),
      detail: { status: request.data.status },
    });
    return { success: true, connectionId };
  }
);

// ---------------------------------------------------------------------------
// Callable: searchStreams
// ---------------------------------------------------------------------------

export const searchStreams = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ query?: unknown; limit?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before searching streams.");
    }
    enforceAuthAndAppCheck(request, uid);

    const query = boundedTrimmedString(request.data.query, "query", 200, true) ?? "";
    const limitRaw = typeof request.data.limit === "number" ? request.data.limit : 25;
    const limit = Math.max(1, Math.min(Math.floor(limitRaw), 50));
    const terms = normalizedSearchTerms(query);
    if (terms.length === 0) {
      return { hits: [] };
    }

    const chunkSnap = await db
      .collectionGroup("chunks")
      .where("uid", "==", uid)
      .where("terms", "array-contains", terms[0])
      .select("docId", "sessionId", "deviceId", "bodyHash", "title", "snippet", "projectName", "model", "terms")
      .limit(200)
      .get();

    const scored = chunkSnap.docs
      .map((doc) => {
        const data = doc.data();
        const indexedTerms = Array.isArray(data.terms)
          ? data.terms.filter((term): term is string => typeof term === "string")
          : [];
        const haystack = `${data.title ?? ""} ${data.snippet ?? ""} ${data.projectName ?? ""} ${data.model ?? ""} ${indexedTerms.join(" ")}`;
        return { doc, data, score: searchScore(haystack, terms) };
      })
      .filter((item) => item.score > 0)
      .sort((a, b) => b.score - a.score || String(a.data.docId ?? "").localeCompare(String(b.data.docId ?? "")))
      .slice(0, limit * 3);

    const hits: Array<Record<string, unknown>> = [];
    const seenSessions = new Set<string>();

    for (const item of scored) {
      const deviceId = typeof item.data.deviceId === "string" ? item.data.deviceId : "";
      const sessionId = typeof item.data.sessionId === "string" ? item.data.sessionId : "";
      const docId = typeof item.data.docId === "string" ? item.data.docId : "";
      const bodyHash = typeof item.data.bodyHash === "string" ? item.data.bodyHash : "";
      if (!deviceId || !sessionId || !docId || !bodyHash) {
        continue;
      }

      const manifest = await db.doc(`users/${uid}/session_logs/${docId}`).get();
      if (!manifest.exists || manifest.get("bodyHash") !== bodyHash) {
        continue;
      }

      const dedupeKey = `${deviceId}:${sessionId}`;
      if (seenSessions.has(dedupeKey)) {
        continue;
      }

      const usageSnap = await db
        .collection(`users/${uid}/usage`)
        .where("deviceId", "==", deviceId)
        .where("sessionId", "==", sessionId)
        .limit(1)
        .get();
      const usageDoc = usageSnap.docs[0];
      if (!usageDoc) {
        continue;
      }

      const usage = serializeUsageForCallable(usageDoc.id, usageDoc.data());
      seenSessions.add(dedupeKey);
      hits.push({
        id: `${sha256Hex(`${docId}:${item.doc.id}`).slice(0, 16)}_${item.doc.id}`,
        title: item.data.title ?? usage.projectName ?? usage.model ?? "Stream",
        snippet: item.data.snippet ?? "",
        score: item.score / terms.length,
        usage,
      });
      if (hits.length >= limit) {
        break;
      }
    }

    return { hits };
  }
);

// ---------------------------------------------------------------------------
// Callable: rebuildUsageRollups
// ---------------------------------------------------------------------------

export const rebuildUsageRollups = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 10,
  },
  async (request: CallableRequest<Record<string, never>>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error("unauthenticated");
    }
    enforceAuthAndAppCheck(request, uid);

    const rollups = await computeUserRollups(db, uid);
    await writeUserRollups(db, uid, rollups);

    return {
      success: true,
      computedAt: rollups.all_time.computedAt,
      windows: ["today", "7d", "30d", "90d", "all_time"] as const,
    };
  }
);

// ---------------------------------------------------------------------------
// Re-export background functions so `firebase deploy --only functions` picks
// them up from a single entry point.
// ---------------------------------------------------------------------------
export { onUsageWritten, rebuildRollups, refreshAllProviderQuotas };

// ---------------------------------------------------------------------------
// Apple App Store JWS verification surface.
//
// Trust pipeline: every entitlement field is derived from a JWS verified
// against AppleRootCA-G3 / G2 / AppleInc Root, then reconciled with live
// state from the App Store Server API. See `appstore/` for details.
// ---------------------------------------------------------------------------
export {
  beginEntitlementBinding,
  verifyHostedQuotaEntitlement,
  restoreHostedQuotaEntitlement,
  appStoreServerNotificationsV2,
  reconcileHostedEntitlementsDaily,
} from "./appstore/index.js";
