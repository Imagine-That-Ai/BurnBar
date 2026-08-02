import { errorMessage, isRecord } from "../guards.js";
import { logError, logInfo } from "../logging.js";
/**
 * @fileoverview Apple App Store Server Notifications V2 webhook.
 *
 * Apple POSTs `{ "signedPayload": "<JWS>" }` to a public HTTPS endpoint
 * configured in App Store Connect. We verify the chain, decode the
 * embedded `signedTransactionInfo` and `signedRenewalInfo` JWS, and
 * reconcile the user's hosted-quota entitlement document.
 *
 * Critical Apple quirks handled:
 *   - Sandbox notifications can hit the same URL; the verifier auto-
 *     fallback environment handles env mismatches.
 *   - We MUST return HTTP 200 once we have processed the notification,
 *     even if the entitlement was already in the desired state.
 *     Otherwise Apple retries with exponential backoff for up to 3 days.
 *   - Idempotency on `notificationUUID` — Apple sends the same UUID for
 *     retries; the audit log uses it as a primary key so we collapse
 *     retries into one write.
 *   - Unknown `notificationType` values are reconciled but logged at
 *     WARN level so new Apple events don't silently drop.
 *
 * Auth: this endpoint must be public — Apple does not sign HTTP-layer
 * requests. Trust comes from JWS verification, not transport auth.
 */

import { onRequest } from "firebase-functions/v2/https";
import type { Request } from "firebase-functions/v2/https";
import type { Response } from "express";
import { getFirestore } from "firebase-admin/firestore";
import { VerificationStatus } from "@apple/app-store-server-library";

import { APP_STORE_SECRETS, loadAppStoreRuntimeConfig } from "./config.js";
import { EntitlementReconcileError, reconcileEntitlement } from "./reconciler.js";
import { getAppleJWSVerifier, JWSVerificationFailure } from "./verifier.js";
import { FUNCTIONS_REGION, HOT_PATH_OPTIONS } from "../runtimeOptions.js";

const REGION = FUNCTIONS_REGION;

/**
 * Apple's `signedPayload` notification bodies are well under 32 KB in
 * practice. We reject anything wildly out-of-range as a cheap pre-JWS
 * filter so a bad actor can't waste verifier CPU with multi-megabyte
 * blobs that would never have been signed by Apple anyway.
 */
const MAX_NOTIFICATION_BODY_BYTES = 64 * 1024; // 64 KB
/**
 * Outer JWS strings from Apple are roughly 5–8 KB; we cap at 32 KB to
 * leave ample headroom while still rejecting unbounded inputs.
 */
const MAX_SIGNED_PAYLOAD_CHARS = 32 * 1024;

/**
 * Validate the inbound HTTP request and extract Apple's `signedPayload`
 * string. Returns the validated payload on success. On any failure this
 * writes the exact error response to `res` and returns `undefined`, so
 * the caller can short-circuit with identical status codes and bodies as
 * the original inline guards.
 */
function extractSignedPayload(req: Request, res: Response): string | undefined {
  if (req.method !== "POST") {
    res.status(405).send("method not allowed");
    return undefined;
  }
  // Apple does not send a Content-Length the spec mandates, but most
  // reverse proxies (incl. Firebase's frontend) set it. If it's
  // present and obviously oversized, drop it before we even parse.
  const declaredLength = Number(req.headers["content-length"] ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > MAX_NOTIFICATION_BODY_BYTES) {
    res.status(413).json({ error: "payload_too_large" });
    return undefined;
  }
  const rawSignedPayload = isRecord(req.body) ? req.body.signedPayload : undefined;
  if (typeof rawSignedPayload !== "string" || !rawSignedPayload) {
    res.status(400).json({ error: "missing signedPayload" });
    return undefined;
  }
  if (rawSignedPayload.length > MAX_SIGNED_PAYLOAD_CHARS) {
    // Could be an attacker probing JWS endpoints with large garbage.
    // 4xx so Apple wouldn't keep retrying if (somehow) the payload
    // ever did genuinely come from them.
    res.status(413).json({ error: "signed_payload_too_large" });
    return undefined;
  }
  return rawSignedPayload;
}

/**
 * Translate a `verifyNotification` rejection into its HTTP response.
 * Distinguishes terminal signature/identity failures (4xx) from transient
 * verifier infrastructure failures (5xx). In particular, Apple's verifier
 * reports OCSP/network failures as `RETRYABLE_VERIFICATION_FAILURE`; returning
 * 4xx for that status would discard a valid notification during an outage.
 *
 * Every verification failure remains fail-closed: no failure path returns 2xx
 * or reaches entitlement reconciliation.
 */
export function respondToAppStoreNotificationVerifyFailure(res: Response, err: unknown): void {
  const failure = appStoreNotificationVerifyFailureResponse(err);
  logError({
    event: "appstore.notifications.verify_failed",
    message: errorMessage(err),
    kind: err instanceof JWSVerificationFailure ? `jws.${err.status}` : "unknown",
    retryable: failure.statusCode >= 500,
  });
  res.status(failure.statusCode).json(failure.body);
}

interface NotificationFailureHttpResponse {
  statusCode: number;
  body: Record<string, unknown>;
}

/**
 * Classify verifier failures using the status contract from Apple's official
 * server library. Only its explicit retryable status is safe to retry. Known
 * signature, certificate, environment, and app-identity failures are terminal.
 * Impossible or future/unknown statuses fail closed with 5xx so we do not
 * silently discard a notification under a library-version mismatch.
 */
export function appStoreNotificationVerifyFailureResponse(err: unknown): NotificationFailureHttpResponse {
  if (!(err instanceof JWSVerificationFailure)) {
    return {
      statusCode: 500,
      body: { error: "internal" },
    };
  }

  switch (err.status) {
    case VerificationStatus.RETRYABLE_VERIFICATION_FAILURE:
      return {
        statusCode: 503,
        body: { error: "jws_verification_unavailable" },
      };
    case VerificationStatus.VERIFICATION_FAILURE:
    case VerificationStatus.INVALID_APP_IDENTIFIER:
    case VerificationStatus.INVALID_ENVIRONMENT:
    case VerificationStatus.INVALID_CHAIN_LENGTH:
    case VerificationStatus.INVALID_CERTIFICATE:
    case VerificationStatus.FAILURE:
      return {
        statusCode: 400,
        body: { error: "jws_invalid" },
      };
    case VerificationStatus.OK:
    default:
      return {
        statusCode: 500,
        body: { error: "internal" },
      };
  }
}

const RETRYABLE_RECONCILE_ERROR_CODES = new Set(["asc_live_status_unavailable"]);

export function appStoreNotificationReconcileFailureResponse(err: unknown): NotificationFailureHttpResponse {
  if (err instanceof EntitlementReconcileError) {
    if (RETRYABLE_RECONCILE_ERROR_CODES.has(err.code)) {
      return {
        statusCode: 503,
        body: { error: "app_store_unavailable", code: err.code },
      };
    }
    return {
      statusCode: 200,
      body: { accepted: false, code: err.code },
    };
  }
  return {
    statusCode: 500,
    body: { error: "internal" },
  };
}

/**
 * Translate a `reconcileEntitlement` rejection into its HTTP response.
 * For internal errors return 500 so Apple retries. For known policy
 * errors (binding mismatch, etc.) return 200 so we don't burn through
 * Apple's retry budget on a doomed payload.
 */
function respondToReconcileFailure(res: Response, err: unknown, type: string, subtype: string): void {
  const failure = appStoreNotificationReconcileFailureResponse(err);
  logError({
    event: "appstore.notifications.reconcile_failed",
    message: errorMessage(err),
    type,
    subtype,
    retryable: failure.statusCode >= 500,
  });
  res.status(failure.statusCode).json(failure.body);
}

export const appStoreServerNotificationsV2 = onRequest(
  {
    region: REGION,
    cors: false,
    invoker: "public",
    maxInstances: 50,
    timeoutSeconds: 30,
    secrets: APP_STORE_SECRETS,
    ...HOT_PATH_OPTIONS,
  },
  async (req, res) => {
    const rawSignedPayload = extractSignedPayload(req, res);
    if (rawSignedPayload === undefined) {
      return;
    }

    const cfg = loadAppStoreRuntimeConfig();
    const verifier = getAppleJWSVerifier(cfg);

    let notification;
    try {
      notification = await verifier.verifyNotification(rawSignedPayload);
    } catch (err) {
      respondToAppStoreNotificationVerifyFailure(res, err);
      return;
    }

    const data = notification.payload.data;
    const signedTransactionJWS = data?.signedTransactionInfo;
    const signedRenewalInfoJWS = data?.signedRenewalInfo;

    if (!signedTransactionJWS) {
      // Some notification types (RESCIND_CONSENT, EXTERNAL_PURCHASE_TOKEN,
      // SUBSCRIPTION_RENEWAL_DATE_EXTENSION summary) carry no transaction
      // info. We acknowledge and move on; logging keeps the audit trail
      // intact.
      logInfo({
        event: "appstore.notifications.no_signed_transaction",
        type: String(notification.payload.notificationType ?? ""),
        subtype: String(notification.payload.subtype ?? ""),
        notification_uuid: String(notification.payload.notificationUUID ?? ""),
      });
      res.status(200).send();
      return;
    }

    const db = getFirestore();
    try {
      await reconcileEntitlement(db, cfg, {
        signedTransactionJWS,
        signedRenewalInfoJWS:
          typeof signedRenewalInfoJWS === "string" && signedRenewalInfoJWS ? signedRenewalInfoJWS : undefined,
        notificationUUID: notification.payload.notificationUUID,
        notificationType:
          typeof notification.payload.notificationType === "string" ? notification.payload.notificationType : undefined,
        notificationSubtype:
          typeof notification.payload.subtype === "string" ? notification.payload.subtype : undefined,
        // No claimed UID for S2S — we resolve uid via the binding doc.
        claimedUid: undefined,
        source: "apple_s2s",
      });
      res.status(200).send();
    } catch (err) {
      respondToReconcileFailure(
        res,
        err,
        String(notification.payload.notificationType ?? ""),
        String(notification.payload.subtype ?? ""),
      );
    }
  },
);
