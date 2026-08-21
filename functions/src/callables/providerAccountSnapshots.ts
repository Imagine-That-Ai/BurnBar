/**
 * @fileoverview Provider quota snapshot upload + legacy credential deletion callables
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { logError, wrapCallableHandler } from "../logging.js";
import {
  assertProvider,
  assertSelfHostedProvider,
  nowISO,
  requiredIdentifier,
  sanitizeUploadedQuotaSnapshot,
} from "./shared.js";
import { destroyCredential } from "../secrets.js";
import { providerAccountSecretRefPath } from "../quota.js";
import { optionalStringField, requireProviderAccountDoc } from "../guards.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

// ---------------------------------------------------------------------------
// Callable: uploadProviderQuotaSnapshot
// ---------------------------------------------------------------------------

export const uploadProviderQuotaSnapshot = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("uploadProviderQuotaSnapshot", async (request: CallableRequest<Record<string, unknown>>) => {
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
      throw new HttpsError("failed-precondition", "Only self-hosted local-only accounts can upload runner snapshots.");
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
  }),
);

// ---------------------------------------------------------------------------
// Callable: deleteProviderCredential (legacy default-account credential delete)
// ---------------------------------------------------------------------------

export const deleteProviderCredential = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("deleteProviderCredential", async (request: CallableRequest<{ provider: string }>) => {
    const { provider } = request.data;
    const uid = request.auth?.uid;

    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before deleting provider credentials.");
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
        logError({
          event: "destroy_provider_credential_secret_failed",
          uid,
          accountID,
          detail: String(err),
        });
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
      { merge: true },
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
      { merge: true },
    );

    // Stale-mark the quota snapshot.
    const snapRef = db.doc(`users/${uid}/quota_snapshots/${provider}_default`);
    await snapRef.set(
      {
        confidence: "stale",
        statusMessage: "Credential deleted; snapshot is stale.",
        updatedAt: now,
      },
      { merge: true },
    );

    return { success: true, provider };
  }),
);
