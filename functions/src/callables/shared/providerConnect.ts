/**
 * @fileoverview Provider adapter registry, hosted-credential normalization, uploaded
 * quota-snapshot sanitization, secret-ref writes, account connection, and rate limits.
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import type { Firestore } from "firebase-admin/firestore";

import { getConfig } from "../../config.js";
import { storeCredential } from "../../secrets.js";
import {
  providerAccountSecretRefPath,
  refreshUserProviderAccountQuota,
  refreshUserProviderQuota,
} from "../../quota.js";
import { upsertDeviceLink } from "../../domains/device-links/index.js";
import { minimaxAdapter } from "../../providers/minimax.js";
import { zaiAdapter } from "../../providers/zai.js";
import { xaiAdapter } from "../../providers/xai.js";
import { mimoAdapter } from "../../providers/mimo.js";
import { kimiAdapter } from "../../providers/kimi.js";
import { factoryAdapter } from "../../providers/factory.js";
import { cursorAdapter } from "../../providers/cursor.js";
import { openaiAdapter } from "../../providers/openai.js";
import type {
  Provider,
  ProviderAccountDoc,
  ProviderAccountConnectContext,
  ProviderAccountSecretRefDoc,
  QuotaBucket,
  QuotaSnapshotDoc,
} from "../../types.js";
import { isTimestampWithToMillis, optionalStringField, recordOrUndefined } from "../../guards.js";
import { logError } from "../../logging.js";
import { db } from "../../adminRuntime.js";
import { assertProvider, boundedTrimmedString, nowISO } from "./validators.js";
import { accountIDFor, ACCOUNT_SCHEMA_VERSION, connectionDocFromAccount } from "./accounts.js";

function backendAdapterFor(provider: Provider) {
  switch (provider) {
    case "openai":
      return openaiAdapter;
    case "minimax":
      return minimaxAdapter;
    case "zai":
      return zaiAdapter;
    case "factory":
      return factoryAdapter;
    case "cursor":
      return cursorAdapter;
    case "xai":
      return xaiAdapter;
    case "mimo":
      return mimoAdapter;
    case "kimi":
      return kimiAdapter;
    default:
      return undefined;
  }
}

const KNOWN_AUTH_METHODS_BY_PROVIDER: Partial<Record<Provider, ReadonlySet<string>>> = {
  openai: new Set(["openai-api-key", "openai-admin-key", "openai-codex-oauth"]),
  minimax: new Set(["minimax-coding-plan", "minimax-open-platform"]),
  zai: new Set(["zai-coding-plan"]),
  kimi: new Set(["kimi-session-token", "moonshot-api-key"]),
  xai: new Set(["xai-api-key", "xai-management-key"]),
  mimo: new Set(["mimo-token-plan", "mimo-payg"]),
};

const CLOUD_CONNECT_AUTH_METHODS_BY_PROVIDER: Partial<Record<Provider, ReadonlySet<string>>> = {
  openai: new Set(["openai-api-key", "openai-admin-key"]),
  minimax: new Set(["minimax-coding-plan", "minimax-open-platform"]),
  zai: new Set(["zai-coding-plan"]),
  kimi: new Set(["moonshot-api-key"]),
  xai: new Set(["xai-management-key"]),
  mimo: new Set(["mimo-token-plan", "mimo-payg"]),
};

export function normalizeCloudConnectAuthMethodID(
  provider: Provider,
  authMethodID: unknown,
  credential?: string,
): string | undefined {
  if (authMethodID === undefined || authMethodID === null) {
    return assertCloudConnectAuthMethodID(provider, inferredCloudConnectAuthMethodID(provider, credential));
  }
  const normalized = boundedTrimmedString(authMethodID, "authMethodID", 96);
  if (!normalized)
    return assertCloudConnectAuthMethodID(provider, inferredCloudConnectAuthMethodID(provider, credential));
  const knownMethods = KNOWN_AUTH_METHODS_BY_PROVIDER[provider];
  if (knownMethods && !knownMethods.has(normalized)) {
    throw new HttpsError("invalid-argument", "Unsupported provider credential method.");
  }
  return assertCloudConnectAuthMethodID(provider, normalized);
}

function assertCloudConnectAuthMethodID(provider: Provider, authMethodID: string | undefined): string | undefined {
  if (!authMethodID) return undefined;
  const cloudMethods = CLOUD_CONNECT_AUTH_METHODS_BY_PROVIDER[provider];
  if (cloudMethods && !cloudMethods.has(authMethodID)) {
    throw new HttpsError(
      "failed-precondition",
      "That credential method is local-only or daemon-managed. Use the Mac app provider setup, hosted quota sync, or self-hosted quota sync for that provider.",
    );
  }
  return authMethodID;
}

function inferredCloudConnectAuthMethodID(provider: Provider, credential?: string): string | undefined {
  const trimmed = credential?.trim() ?? "";
  switch (provider) {
    case "openai":
      return trimmed.startsWith("sk-admin-") ? "openai-admin-key" : undefined;
    case "xai":
      return "xai-management-key";
    case "kimi":
      return "moonshot-api-key";
    case "mimo":
      if (trimmed.startsWith("tp-")) return "mimo-token-plan";
      if (trimmed.startsWith("sk-")) return "mimo-payg";
      return undefined;
    default:
      return undefined;
  }
}

export function normalizeHostedCredential(provider: string, raw: unknown): string {
  const credential = boundedTrimmedString(raw, "credential", getConfig().maxCredentialLength, true);
  if (!credential) {
    throw new HttpsError("invalid-argument", "credential is required.");
  }
  try {
    const candidate = credential.startsWith("{") ? credential : Buffer.from(credential, "base64").toString("utf8");
    JSON.parse(candidate);
    return credential;
  } catch {
    throw new HttpsError(
      "invalid-argument",
      "Codex hosted credentials must be ~/.codex/auth.json JSON or base64 JSON.",
    );
  }
}

function safeSnapshotSourceID(raw: unknown): string {
  return (
    (typeof raw === "string" ? raw : "self-hosted-runner")
      .toLowerCase()
      .replace(/[^a-z0-9_-]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "") || "self-hosted-runner"
  );
}

export function sanitizeUploadedQuotaSnapshot(
  account: ProviderAccountDoc,
  raw: Record<string, unknown>,
): QuotaSnapshotDoc {
  const now = nowISO();
  const bucketsRaw = Array.isArray(raw.buckets) ? raw.buckets : [];
  const buckets = bucketsRaw.slice(0, 16).flatMap((item): QuotaBucket[] => {
    const b = recordOrUndefined(item);
    if (!b) return [];
    const name = boundedTrimmedString(b.name, "bucket.name", 80);
    if (!name) return [];
    const used = Number(b.used);
    const limit = Number(b.limit);
    const remaining = Number(b.remaining);
    if (!Number.isFinite(used) || !Number.isFinite(limit) || !Number.isFinite(remaining)) {
      return [];
    }
    const bucket: QuotaBucket = {
      name,
      used,
      limit,
      remaining,
      ...(boundedTrimmedString(b.window, "bucket.window", 64)
        ? { window: boundedTrimmedString(b.window, "bucket.window", 64) }
        : {}),
      ...(recordOrUndefined(b.meta)
        ? {
            meta: Object.fromEntries(
              Object.entries(recordOrUndefined(b.meta) ?? {})
                .filter(
                  ([key, value]) =>
                    /^[a-zA-Z0-9_.-]{1,64}$/.test(key) &&
                    !isSecretLikeMetadataKey(key) &&
                    (typeof value === "string" || typeof value === "number" || typeof value === "boolean"),
                )
                .slice(0, 16),
            ),
          }
        : {}),
    };
    return [bucket];
  });
  if (buckets.length === 0) {
    throw new HttpsError("invalid-argument", "At least one quota bucket is required.");
  }
  const confidence =
    raw.confidence === "high" || raw.confidence === "medium" || raw.confidence === "low" || raw.confidence === "stale"
      ? raw.confidence
      : "high";
  assertProvider(account.providerID);
  const snapshot: QuotaSnapshotDoc = {
    sourceKind: "provider",
    sourceId: safeSnapshotSourceID(raw.sourceId),
    provider: account.providerID,
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
  };
  return snapshot;
}

function isSecretLikeMetadataKey(key: string): boolean {
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

export async function writePrivateSecretRef(
  uid: string,
  accountID: string,
  provider: Provider,
  secretVersionName: string,
  createdAt: string,
  updatedAt: string,
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

export async function connectProviderAccountInternal(params: {
  uid: string;
  provider: Provider;
  credential: string;
  label?: string;
  accountID?: string;
  isDefault?: boolean;
  sourceDeviceID?: string;
  deviceDisplayName?: string;
  endpointProfileID?: string;
  region?: ProviderAccountConnectContext["region"];
  tokenPlanTier?: ProviderAccountConnectContext["tokenPlanTier"];
  tokenPlanBillingCycle?: ProviderAccountConnectContext["tokenPlanBillingCycle"];
  authMethodID?: string;
}): Promise<ProviderAccountDoc> {
  const { uid, provider, credential } = params;
  const accountID = accountIDFor(provider, params.accountID);
  const label = params.label?.trim() || "Default";
  const accountContext: ProviderAccountConnectContext = {
    endpointProfileID: params.endpointProfileID,
    region: params.region,
    tokenPlanTier: params.tokenPlanTier,
    tokenPlanBillingCycle: params.tokenPlanBillingCycle,
    authMethodID: normalizeCloudConnectAuthMethodID(provider, params.authMethodID, credential),
  };

  const adapter = backendAdapterFor(provider);
  if (!adapter) {
    if (provider === "codex") {
      throw new HttpsError(
        "failed-precondition",
        "Codex is a runner-based provider and doesn't support backend credential connections. Connect it through hosted quota sync or the OpenBurnBar Mac app instead.",
      );
    }
    throw new HttpsError(
      "unimplemented",
      `OpenBurnBar doesn't have a server-side connector for ${provider} yet. Connect it on the macOS app, or pick a supported provider (OpenAI, Factory, Cursor, Z.ai, MiniMax, Kimi).`,
    );
  }

  const testResult = await adapter.testCredential(credential, accountContext);
  if (!testResult.valid) {
    const message = testResult.errorMessage?.trim() || "We couldn't validate that credential.";
    const detail = testResult.errorCode ? `${message} (${testResult.errorCode})` : message;
    throw new HttpsError("invalid-argument", detail, {
      provider,
      errorCode: testResult.errorCode,
    });
  }

  const now = nowISO();
  const existing = await db.doc(`users/${uid}/provider_accounts/${accountID}`).get();
  const secretVersionName = await storeCredential(uid, provider, credential, accountID);
  await writePrivateSecretRef(
    uid,
    accountID,
    provider,
    secretVersionName,
    existing.exists ? (optionalStringField(existing.get("createdAt")) ?? now) : now,
    now,
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
    sourceDeviceID: boundedTrimmedString(params.sourceDeviceID, "sourceDeviceID", 128),
    linkedSwitcherProfileID: undefined,
    endpointProfileID: params.endpointProfileID,
    region: params.region,
    tokenPlanTier: params.tokenPlanTier,
    tokenPlanBillingCycle: params.tokenPlanBillingCycle,
    authMethodID: accountContext.authMethodID,
    isDefault: params.isDefault ?? accountID.endsWith("_default"),
    sortKey: accountID.endsWith("_default") ? 0 : Date.now(),
    lastValidatedAt: now,
    lastRefreshAt: now,
    lastErrorCode: undefined,
    schemaVersion: ACCOUNT_SCHEMA_VERSION,
    createdAt: existing.exists ? (optionalStringField(existing.get("createdAt")) ?? now) : now,
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

  if (accountDoc.sourceDeviceID) {
    await upsertDeviceLink({
      db,
      uid,
      accountID,
      deviceID: accountDoc.sourceDeviceID,
      deviceDisplayName: params.deviceDisplayName ?? accountDoc.sourceDeviceID,
      capability: "owner",
    });
  }

  try {
    await refreshUserProviderAccountQuota(db, uid, accountID);
    if (accountDoc.isDefault) {
      await refreshUserProviderQuota(db, uid, provider);
    }
  } catch (quotaErr) {
    logError({
      // Pass uid/accountID as discrete fields (uid is truncated to
      // user_id_hash by the scrubber) instead of interpolating the raw 28-char
      // UID into a free-form message string the scrubber cannot redact
      // (F-RR09-002).
      event: "initial_quota_refresh_failed",
      uid,
      accountID,
      detail: String(quotaErr),
    });
  }

  return accountDoc;
}

/**
 * Enforce rate limit for refreshProviderQuota per user+provider.
 * Uses Firestore as a lightweight TTL store.
 */
export async function checkRefreshRateLimit(db: Firestore, uid: string, provider: string): Promise<void> {
  const { refreshRateLimitSeconds } = getConfig();
  const ref = db.doc(`users/${uid}/_rate_limits/refresh_${provider}`);
  const snap = await ref.get();
  if (snap.exists) {
    const ts = snap.get("lastRefreshAt");
    if (isTimestampWithToMillis(ts)) {
      const elapsed = Date.now() - ts.toMillis();
      if (elapsed < refreshRateLimitSeconds * 1000) {
        throw new HttpsError(
          "resource-exhausted",
          `Please wait ${Math.ceil((refreshRateLimitSeconds * 1000 - elapsed) / 1000)}s before refreshing ${provider}.`,
        );
      }
    }
  }
  await ref.set({ lastRefreshAt: Timestamp.now() }, { merge: true });
}

export async function checkHermesRateLimit(uid: string, action: string, windowSeconds: number): Promise<void> {
  const ref = db.doc(`users/${uid}/_rate_limits/hermes_${action}`);
  const snap = await ref.get();
  if (snap.exists) {
    const ts = snap.get("lastAt");
    if (isTimestampWithToMillis(ts)) {
      const elapsed = Date.now() - ts.toMillis();
      if (elapsed < windowSeconds * 1000) {
        throw new HttpsError(
          "resource-exhausted",
          `Please wait ${Math.ceil((windowSeconds * 1000 - elapsed) / 1000)}s before retrying.`,
        );
      }
    }
  }
  await ref.set({ lastAt: Timestamp.now() }, { merge: true });
}

export async function checkPiAgentRateLimit(uid: string, action: string, windowSeconds: number): Promise<void> {
  const ref = db.doc(`users/${uid}/_rate_limits/pi_agent_${action}`);
  const snap = await ref.get();
  if (snap.exists) {
    const ts = snap.get("lastAt");
    if (isTimestampWithToMillis(ts)) {
      const elapsed = Date.now() - ts.toMillis();
      if (elapsed < windowSeconds * 1000) {
        throw new HttpsError(
          "resource-exhausted",
          `Please wait ${Math.ceil((windowSeconds * 1000 - elapsed) / 1000)}s before retrying.`,
        );
      }
    }
  }
  await ref.set({ lastAt: Timestamp.now() }, { merge: true });
}
