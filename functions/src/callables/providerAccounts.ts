/**
 * @fileoverview Provider account connect, quota, and credential callables
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db, auth } from "../adminRuntime.js";
import { logError } from "../logging.js";
import {
  ACCOUNT_SCHEMA_VERSION,
  assertProvider,
  nowISO,
  requiredIdentifier,
  boundedTrimmedString,
  accountIDFor,
  connectionDocFromAccount,
  assertHostedProvider,
  hostedProviderLabel,
  hostedCredentialKind,
  assertSelfHostedProvider,
  assertActiveHostedQuotaEntitlement,
  normalizeHostedCredential,
  sanitizeUploadedQuotaSnapshot,
  writePrivateSecretRef,
  connectProviderAccountInternal,
  checkRefreshRateLimit,
} from "./shared.js";
import {
  storeCredential,
  destroyCredential,
} from "../secrets.js";
import {
  providerAccountSecretRefPath,
  refreshUserProviderAccountQuota,
  refreshUserProviderQuota,
} from "../quota.js";
import {
  revokeAllLinksForAccount,
  upsertDeviceLink,
} from "../providerAccountDeviceLinks.js";
import { eraseUserAccount } from "../accountDeletion.js";
import { HOSTED_RUNNER_SECRETS } from "../hostedRunnerConfig.js";
import {
  errorMessage,
  optionalStringField,
  requireProviderAccountDoc,
  stripUndefinedObject,
} from "../guards.js";
import type { ProviderAccountConnectContext, ProviderAccountDoc } from "../types.js";

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
      sourceDeviceID?: string;
      deviceDisplayName?: string;
      endpointProfileID?: string;
      region?: ProviderAccountConnectContext["region"];
      tokenPlanTier?: ProviderAccountConnectContext["tokenPlanTier"];
      tokenPlanBillingCycle?: ProviderAccountConnectContext["tokenPlanBillingCycle"];
      authMethodID?: string;
    }>
  ) => {
    const {
      provider,
      credential,
      label,
      accountID,
      sourceDeviceID,
      deviceDisplayName,
      endpointProfileID,
      region,
      tokenPlanTier,
      tokenPlanBillingCycle,
      authMethodID,
    } = request.data;
    const uid = request.auth?.uid;

    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before adding a provider account.");
    }
    enforceAuthAndAppCheck(request, uid);
    assertProvider(provider);

    if (typeof credential !== "string" || credential.trim().length === 0) {
      throw new HttpsError("invalid-argument", "credential must be a non-empty string.");
    }
    if (credential.length > getConfig().maxCredentialLength) {
      throw new HttpsError(
        "invalid-argument",
        `credential exceeds max length (${getConfig().maxCredentialLength} characters).`
      );
    }

    return connectProviderAccountInternal({
      uid,
      provider,
      credential,
      label,
      accountID,
      sourceDeviceID,
      deviceDisplayName,
      endpointProfileID,
      region,
      tokenPlanTier,
      tokenPlanBillingCycle,
      authMethodID,
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
      throw new HttpsError("unauthenticated", "Sign in before connecting a provider.");
    }
    enforceAuthAndAppCheck(request, uid);

    assertProvider(provider);

    if (typeof credential !== "string" || credential.trim().length === 0) {
      throw new HttpsError("invalid-argument", "credential must be a non-empty string.");
    }
    if (credential.length > getConfig().maxCredentialLength) {
      throw new HttpsError(
        "invalid-argument",
        `credential exceeds max length (${getConfig().maxCredentialLength} characters).`
      );
    }

    const accountDoc = await connectProviderAccountInternal({
      uid,
      provider,
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
      sourceDeviceID?: string;
      deviceDisplayName?: string;
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

    const credential = normalizeHostedCredential(provider, request.data.credential);
    const accountID = accountIDFor(provider, request.data.accountID);
    const providerLabel = hostedProviderLabel(provider);
    const accountRedactedLabel = `${providerLabel} credential stored in Secret Manager`;
    const label = boundedTrimmedString(request.data.label, "label", 80) ?? `Hosted ${providerLabel}`;
    const now = nowISO();
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const existing = await accountRef.get();
    const createdAt = existing.exists
      ? optionalStringField(existing.get("createdAt")) ?? now
      : now;
    const secretVersionName = await storeCredential(uid, provider, credential, accountID);
    await writePrivateSecretRef(uid, accountID, provider, secretVersionName, createdAt, now);

    const accountDoc: ProviderAccountDoc = {
      id: accountID,
      providerID: provider,
      label,
      identityHint: undefined,
      status: "connected",
      credentialKind: hostedCredentialKind(provider),
      storageScope: "server_private",
      redactedLabel: accountRedactedLabel,
      sourceDeviceID: boundedTrimmedString(request.data.sourceDeviceID, "sourceDeviceID", 128),
      linkedSwitcherProfileID: undefined,
      isDefault: request.data.accountID == null || accountID.endsWith("_default"),
      sortKey: accountID.endsWith("_default") ? 0 : Date.now(),
      lastValidatedAt: now,
      lastRefreshAt: now,
      lastErrorCode: undefined,
      schemaVersion: ACCOUNT_SCHEMA_VERSION,
      createdAt,
      updatedAt: now,
    };

    await db.runTransaction(async (tx) => {
      tx.set(accountRef, stripUndefinedObject(accountDoc), { merge: true });
      if (accountDoc.isDefault) {
        tx.set(
          db.doc(`users/${uid}/provider_connections/${provider}`),
          connectionDocFromAccount(accountDoc),
          { merge: true }
        );
      }
    });
    if (accountDoc.sourceDeviceID) {
      await upsertDeviceLink({
        db,
        uid,
        accountID,
        deviceID: accountDoc.sourceDeviceID,
        deviceDisplayName: request.data.deviceDisplayName ?? accountDoc.sourceDeviceID,
        capability: "owner",
      });
    }
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
      deviceDisplayName?: string;
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
      `${hostedProviderLabel(provider)} self-hosted`;
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
      createdAt: existing.exists ? optionalStringField(existing.get("createdAt")) ?? now : now,
      updatedAt: now,
    };

    await db.runTransaction(async (tx) => {
      tx.set(db.doc(`users/${uid}/provider_accounts/${accountID}`), stripUndefinedObject(accountDoc), { merge: true });
      if (accountDoc.isDefault) {
        tx.set(
          db.doc(`users/${uid}/provider_connections/${provider}`),
          connectionDocFromAccount(accountDoc),
          { merge: true }
        );
      }
    });

    if (accountDoc.sourceDeviceID) {
      try {
        await upsertDeviceLink({
          db,
          uid,
          accountID,
          deviceID: accountDoc.sourceDeviceID,
          deviceDisplayName: request.data.deviceDisplayName ?? accountDoc.sourceDeviceID,
          capability: "owner",
        });
      } catch (linkErr) {
        logError({ event: "callable_warn", message: `device_links upsert failed for ${uid}/${accountID}:`, detail: String(linkErr) });
      }
    }
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
    const account = requireProviderAccountDoc(accountSnap.data());
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
  async (request: CallableRequest<{ accountID: string; provider?: string }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before deleting hosted credentials.");
    }
    enforceAuthAndAppCheck(request, uid);
    const provider = typeof request.data.provider === "string" && request.data.provider.trim()
      ? request.data.provider.trim()
      : "codex";
    assertHostedProvider(provider);
    const accountID = accountIDFor(provider, request.data.accountID);
    const accountRef = db.doc(`users/${uid}/provider_accounts/${accountID}`);
    const accountSnap = await accountRef.get();
    if (!accountSnap.exists) {
      throw new HttpsError("not-found", "Provider account not found.");
    }
    const account = requireProviderAccountDoc(accountSnap.data());
    if (account.storageScope !== "server_private") {
      throw new HttpsError("failed-precondition", "Account is not a hosted quota account.");
    }
    const privateRef = db.doc(providerAccountSecretRefPath(uid, accountID));
    const privateSnap = await privateRef.get();
    const secretVersionName = privateSnap.exists
      ? optionalStringField(privateSnap.get("secretVersionName"))
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
    const current = requireProviderAccountDoc(snap.data());
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
    const updated = requireProviderAccountDoc(updatedSnap.data());
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
    const account = requireProviderAccountDoc(accountSnap.data());

    const privateRef = db.doc(providerAccountSecretRefPath(uid, accountID));
    const privateSnap = await privateRef.get();
    const secretVersionName = privateSnap.exists
      ? optionalStringField(privateSnap.get("secretVersionName"))
      : undefined;

    if (secretVersionName) {
      try {
        await destroyCredential(secretVersionName);
      } catch (err) {
        logError({ event: "callable_warn", message: `Failed to destroy provider account secret for ${accountID}:`, detail: String(err) });
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

    try {
      await revokeAllLinksForAccount(db, uid, accountID);
    } catch (linkErr) {
      logError({ event: "callable_warn", message: `device_links cascade revoke failed for ${uid}/${accountID}:`, detail: String(linkErr) });
    }

    return { success: true, accountID };
  }
);

// ---------------------------------------------------------------------------
// Callable: deleteUserCloudData
// ---------------------------------------------------------------------------

export const deleteUserCloudData = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
    timeoutSeconds: 540,
    memory: "1GiB",
  },
  async (request: CallableRequest<Record<string, never>>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before deleting cloud data.");
    }
    enforceAuthAndAppCheck(request, uid);

    const summary = await eraseUserAccount(db, uid, {
      destroyCredential,
      deleteAuthUser: async (targetUID) => {
        await auth.deleteUser(targetUID);
      },
    });
    if (summary.failedSecretDestroys > 0) {
      throw new HttpsError(
        "internal",
        "Cloud data was deleted, but one or more hosted credential secrets could not be destroyed. Contact support.",
        summary
      );
    }

    return {
      success: true,
      ...summary,
    };
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
      ? optionalStringField(privateSnap.get("secretVersionName"))
      : undefined;

    // Destroy the secret payload if we know where it lives.
    if (secretVersionName) {
      try {
        await destroyCredential(secretVersionName);
      } catch (err) {
        logError({ event: "callable_warn", message: `Failed to destroy provider credential secret for ${uid}/${accountID}:`, detail: String(err) });
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
      .where("status", "in", ["connected", "stale", "error"])
      .get();

    if (!accountSnapshot.empty) {
      const snapshots = [];
      const skippedAccountIDs: string[] = [];
      const errors: Array<{ accountID: string; message: string }> = [];

      for (const doc of accountSnapshot.docs) {
        const account = requireProviderAccountDoc(doc.data());
        if (account.storageScope !== "cloud_refreshable" && account.storageScope !== "server_private") {
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
            message: errorMessage(err),
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

    assertProvider(provider);
    const snapshot = await refreshUserProviderQuota(db, uid, provider);
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

