/**
 * @fileoverview Apple-verified hosted quota entitlement callables.
 *
 * Three callables are exposed:
 *
 *   - `beginEntitlementBinding`      — mint an `appAccountToken` for purchase.
 *   - `verifyHostedQuotaEntitlement` — verify a client-supplied JWS and
 *     reconcile the entitlement document.
 *   - `restoreHostedQuotaEntitlement` — re-run live ASC reconciliation
 *     for the signed-in user's known `originalTransactionId`. Used by
 *     "Restore Purchases" UI.
 *
 * All three require Firebase Auth + (configurable) App Check, just like
 * the existing OpenBurnBar callable surface.
 */

import { onCall, type CallableRequest } from "firebase-functions/v2/https";
import * as functions from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import type { HostedQuotaEntitlementDoc } from "../types.js";

import {
  APP_STORE_SECRETS,
  hostedQuotaProductID,
  loadAppStoreRuntimeConfig,
} from "./config.js";
import {
  beginBinding,
  EntitlementReconcileError,
  reconcileEntitlement,
} from "./reconciler.js";
import { JWSVerificationFailure } from "./verifier.js";
import { fetchLiveSubscriptionStatus } from "./client.js";

const REGION = "us-central1";

// ---------------------------------------------------------------------------
// beginEntitlementBinding
// ---------------------------------------------------------------------------

export const beginEntitlementBinding = onCall(
  {
    region: REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: APP_STORE_SECRETS,
  },
  async (
    request: CallableRequest<{
      productID?: string;
      clientPlatform?: "ios" | "ipados" | "macos";
    }>
  ): Promise<{ appAccountToken: string }> => {
    const uid = request.auth?.uid;
    if (!uid) throw httpsError("unauthenticated", "auth required");
    enforceAuthAndAppCheck(request, uid);
    const productID = request.data.productID ?? hostedQuotaProductID();
    const db = getFirestore();
    return beginBinding(db, uid, productID, request.data.clientPlatform);
  }
);

// ---------------------------------------------------------------------------
// verifyHostedQuotaEntitlement
// ---------------------------------------------------------------------------

export const verifyHostedQuotaEntitlement = onCall(
  {
    region: REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
    secrets: APP_STORE_SECRETS,
  },
  async (
    request: CallableRequest<{
      signedTransactionJWS: string;
      signedRenewalInfoJWS?: string;
      productID?: string;
    }>
  ): Promise<HostedQuotaEntitlementDoc> => {
    const uid = request.auth?.uid;
    if (!uid) throw httpsError("unauthenticated", "auth required");
    enforceAuthAndAppCheck(request, uid);
    const signedTransactionJWS = String(
      request.data.signedTransactionJWS ?? ""
    ).trim();
    if (!signedTransactionJWS) {
      throw httpsError(
        "invalid-argument",
        "signedTransactionJWS is required"
      );
    }
    if (signedTransactionJWS.split(".").length !== 3) {
      throw httpsError(
        "invalid-argument",
        "signedTransactionJWS must be a JWS"
      );
    }
    const cfg = loadAppStoreRuntimeConfig();
    const productID = request.data.productID ?? hostedQuotaProductID();
    const db = getFirestore();
    try {
      const result = await reconcileEntitlement(db, cfg, {
        signedTransactionJWS,
        signedRenewalInfoJWS: request.data.signedRenewalInfoJWS,
        claimedUid: uid,
        source: "client_callable",
        productID,
      });
      return result.entitlement;
    } catch (err) {
      throw mapReconcileError(err);
    }
  }
);

// ---------------------------------------------------------------------------
// restoreHostedQuotaEntitlement
// ---------------------------------------------------------------------------

/**
 * Three legitimate restore scenarios this callable handles:
 *
 *   1. Reinstall on a new device (no server entitlement, but `Transaction.currentEntitlements`
 *      surfaces a JWS): client supplies the JWS, server verifies it and writes a fresh
 *      entitlement doc for the signed-in UID.
 *   2. Same device, server doc already exists: client supplies no JWS; server pulls
 *      `originalTransactionID` from the existing doc and reconciles via ASC.
 *   3. Sandbox tester replaying state: same as (1) or (2).
 *
 * Apple's HIG REQUIRES a "Restore Purchases" affordance on every app with auto-renewing
 * subscriptions. This callable is the server side of that contract.
 */
export const restoreHostedQuotaEntitlement = onCall(
  {
    region: REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: APP_STORE_SECRETS,
  },
  async (
    request: CallableRequest<{
      productID?: string;
      /**
       * Optional JWS the iOS client harvested from `Transaction.currentEntitlements`
       * after calling `AppStore.sync()`. Preferred over the server-side fallback
       * because it works even on a fresh install where no entitlement doc exists yet.
       */
      signedTransactionJWS?: string;
    }>
  ): Promise<HostedQuotaEntitlementDoc> => {
    const uid = request.auth?.uid;
    if (!uid) throw httpsError("unauthenticated", "auth required");
    enforceAuthAndAppCheck(request, uid);
    const cfg = loadAppStoreRuntimeConfig();
    const productID = request.data.productID ?? hostedQuotaProductID();
    const db = getFirestore();

    // Scenario (1): client harvested a JWS. Forward it through the same
    // reconciliation pipeline as `verifyHostedQuotaEntitlement`.
    const clientJWS = String(request.data.signedTransactionJWS ?? "").trim();
    if (clientJWS) {
      if (clientJWS.split(".").length !== 3) {
        throw httpsError(
          "invalid-argument",
          "signedTransactionJWS must be a JWS"
        );
      }
      try {
        const result = await reconcileEntitlement(db, cfg, {
          signedTransactionJWS: clientJWS,
          claimedUid: uid,
          source: "client_callable",
          productID,
        });
        return result.entitlement;
      } catch (err) {
        throw mapReconcileError(err);
      }
    }

    // Scenario (2): server-side fallback. Read existing entitlement doc;
    // if `originalTransactionID` is on file, pull live state from ASC.
    const docRef = db.doc(`users/${uid}/entitlements/hosted_quota_sync`);
    const snap = await docRef.get();
    if (!snap.exists) {
      throw httpsError(
        "failed-precondition",
        "no entitlement on file. Call from the iOS client with " +
          "signedTransactionJWS after running AppStore.sync() and " +
          "iterating Transaction.currentEntitlements."
      );
    }
    const existing = snap.data() as HostedQuotaEntitlementDoc;
    const original = existing.originalTransactionID;
    if (!original) {
      throw httpsError(
        "failed-precondition",
        "entitlement has no originalTransactionID"
      );
    }
    const live = await fetchLiveSubscriptionStatus(
      cfg,
      existing.environment ?? cfg.environment,
      original
    );
    const seedJWS = live.pairs[0]?.signedTransactionInfo;
    if (!seedJWS) {
      throw httpsError(
        "failed-precondition",
        "ASC returned no signed transactions for this subscription"
      );
    }
    try {
      const result = await reconcileEntitlement(db, cfg, {
        signedTransactionJWS: seedJWS,
        signedRenewalInfoJWS: live.pairs[0]?.signedRenewalInfo,
        claimedUid: uid,
        source: "client_callable",
        productID,
      });
      return result.entitlement;
    } catch (err) {
      throw mapReconcileError(err);
    }
  }
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function httpsError(
  code: functions.FunctionsErrorCode,
  message: string
): functions.HttpsError {
  return new functions.HttpsError(code, message);
}

function mapReconcileError(err: unknown): functions.HttpsError {
  if (err instanceof functions.HttpsError) return err;
  if (err instanceof JWSVerificationFailure) {
    return httpsError("permission-denied", err.message);
  }
  if (err instanceof EntitlementReconcileError) {
    if (
      err.code === "binding_mismatch" ||
      err.code === "binding_unknown" ||
      err.code === "uid_unresolved" ||
      err.code === "bundle_id_mismatch"
    ) {
      return httpsError("permission-denied", err.message);
    }
    if (err.code === "no_active_transaction") {
      return httpsError("failed-precondition", err.message);
    }
    if (err.code === "asc_live_status_unavailable") {
      return httpsError("unavailable", err.message);
    }
    if (err.code === "missing_field") {
      return httpsError("invalid-argument", err.message);
    }
  }
  return httpsError(
    "internal",
    err instanceof Error ? err.message : "entitlement verification failed"
  );
}
