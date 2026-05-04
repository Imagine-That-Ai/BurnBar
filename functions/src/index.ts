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
} from "./secrets.js";
import {
  providerAccountSecretRefPath,
  refreshUserProviderAccountQuota,
  refreshUserProviderQuota,
} from "./quota.js";
import { computeUserRollups, writeUserRollups } from "./rollups.js";
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
