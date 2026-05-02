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
import { onCall, type CallableRequest } from "firebase-functions/v2/https";
import { Timestamp, type Firestore } from "firebase-admin/firestore";

import { getConfig } from "./config.js";
import { enforceAuthAndAppCheck } from "./auth.js";
import {
  storeCredential,
  destroyCredential,
  initialSecretVersionName,
} from "./secrets.js";
import { refreshUserProviderQuota } from "./quota.js";
import { computeUserRollups, writeUserRollups } from "./rollups.js";
import { minimaxAdapter } from "./providers/minimax.js";
import { zaiAdapter } from "./providers/zai.js";
import { factoryAdapter } from "./providers/factory.js";
import { cursorAdapter } from "./providers/cursor.js";

import type {
  Provider,
  SUPPORTED_PROVIDERS,
  ProviderConnectionDoc,
  RollupJobDoc,
} from "./types.js";

import { onUsageWritten } from "./triggers.js";
import { rebuildRollups, refreshAllProviderQuotas } from "./scheduled.js";

// ---------------------------------------------------------------------------
// Admin initialization
// ---------------------------------------------------------------------------
initializeApp();
const db = getFirestore();

// ---------------------------------------------------------------------------
// Provider adapter registry
// ---------------------------------------------------------------------------
const ADAPTERS = {
  minimax: minimaxAdapter,
  zai: zaiAdapter,
  factory: factoryAdapter,
  cursor: cursorAdapter,
} as const;

const ALLOWED_PROVIDERS = new Set<string>([
  "minimax",
  "zai",
  "factory",
  "cursor",
  "claude-code",
  "codex",
]);

const CONNECTION_SCHEMA_VERSION = 1;

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

// ---------------------------------------------------------------------------
// Callable: connectProviderCredential
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

    // Test credential before storing anything.
    const adapter = ADAPTERS[provider as keyof typeof ADAPTERS];
    if (!adapter) {
      // Local-only providers do not support backend credential testing.
      if (provider === "claude-code" || provider === "codex") {
        throw new Error("invalid-argument: Claude Code / Codex do not support backend credential connections.");
      }
      throw new Error("internal: no adapter for provider.");
    }

    const testResult = await adapter.testCredential(credential);
    if (!testResult.valid) {
      throw new Error(`invalid-argument: ${testResult.errorCode} — ${testResult.errorMessage}`);
    }

    // Store encrypted credential in Secret Manager.
    const secretVersionName = await storeCredential(uid, provider, credential);

    const now = nowISO();
    const connDoc: ProviderConnectionDoc = {
      provider: provider as Provider,
      status: "connected",
      lastValidatedAt: now,
      lastRefreshAt: now,
      credentialKind: testResult.credentialKind,
      redactedLabel: testResult.redactedLabel,
      schemaVersion: CONNECTION_SCHEMA_VERSION,
      warningMessage: testResult.warningMessage,
    };

    // Write connection metadata + secret reference atomically.
    await db.runTransaction(async (tx) => {
      const connRef = db.doc(`users/${uid}/provider_connections/${provider}`);
      tx.set(connRef, { ...connDoc, secretVersionName }, { merge: true });
    });

    // Immediately write a backend quota snapshot.
    try {
      await refreshUserProviderQuota(db, uid, provider as Provider);
    } catch (quotaErr) {
      // Non-fatal: connection succeeded even if initial quota fetch fails.
      console.warn(`Initial quota refresh failed for ${uid}/${provider}:`, quotaErr);
    }

    return { success: true, provider, redactedLabel: testResult.redactedLabel };
  }
);

// ---------------------------------------------------------------------------
// Callable: deleteProviderCredential
// ---------------------------------------------------------------------------

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

    const connRef = db.doc(`users/${uid}/provider_connections/${provider}`);
    const snap = await connRef.get();
    const secretVersionName = snap.exists
      ? (snap.get("secretVersionName") as string | undefined)
      : undefined;

    // Destroy the secret payload if we know where it lives.
    if (secretVersionName) {
      try {
        await destroyCredential(secretVersionName);
      } catch (err) {
        console.warn(`Failed to destroy secret ${secretVersionName}:`, err);
      }
    }

    const now = nowISO();
    await connRef.set(
      {
        status: "disconnected",
        lastValidatedAt: null,
        lastRefreshAt: null,
        secretVersionName: null,
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

export const refreshProviderQuota = onCall(
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

    await checkRefreshRateLimit(db, uid, provider);

    const snapshot = await refreshUserProviderQuota(db, uid, provider as Provider);
    if (!snapshot) {
      throw new Error("failed-precondition: quota refresh returned no snapshot.");
    }

    return { success: true, provider, fetchedAt: snapshot.fetchedAt };
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
