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
import { getFirestore } from "firebase-admin/firestore";

import {
  APP_STORE_SECRETS,
  hostedQuotaProductID,
  loadAppStoreRuntimeConfig,
} from "./config.js";
import {
  EntitlementReconcileError,
  reconcileEntitlement,
} from "./reconciler.js";
import {
  getAppleJWSVerifier,
  JWSVerificationFailure,
} from "./verifier.js";

const REGION = "us-central1";

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

export const appStoreServerNotificationsV2 = onRequest(
  {
    region: REGION,
    cors: false,
    invoker: "public",
    maxInstances: 50,
    timeoutSeconds: 30,
    secrets: APP_STORE_SECRETS,
  },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).send("method not allowed");
      return;
    }
    // Apple does not send a Content-Length the spec mandates, but most
    // reverse proxies (incl. Firebase's frontend) set it. If it's
    // present and obviously oversized, drop it before we even parse.
    const declaredLength = Number(req.headers["content-length"] ?? 0);
    if (
      Number.isFinite(declaredLength) &&
      declaredLength > MAX_NOTIFICATION_BODY_BYTES
    ) {
      res.status(413).json({ error: "payload_too_large" });
      return;
    }
    const rawSignedPayload =
      req.body && typeof req.body === "object" && "signedPayload" in req.body
        ? (req.body as { signedPayload?: unknown }).signedPayload
        : undefined;
    if (typeof rawSignedPayload !== "string" || !rawSignedPayload) {
      res.status(400).json({ error: "missing signedPayload" });
      return;
    }
    if (rawSignedPayload.length > MAX_SIGNED_PAYLOAD_CHARS) {
      // Could be an attacker probing JWS endpoints with large garbage.
      // 4xx so Apple wouldn't keep retrying if (somehow) the payload
      // ever did genuinely come from them.
      res.status(413).json({ error: "signed_payload_too_large" });
      return;
    }
    const cfg = loadAppStoreRuntimeConfig();
    const productID = hostedQuotaProductID();
    const verifier = getAppleJWSVerifier(cfg);

    let notification;
    try {
      notification = await verifier.verifyNotification(rawSignedPayload);
    } catch (err) {
      console.error("appstore:notifications verify failed", {
        message: (err as Error).message,
        kind:
          err instanceof JWSVerificationFailure
            ? `jws.${err.status}`
            : "unknown",
      });
      // Distinguish "you sent us garbage" (4xx) from "we screwed up"
      // (5xx). Apple treats 4xx as terminal — no retry. That's right
      // for a payload that fails chain verification: it would never
      // become valid on retry.
      if (err instanceof JWSVerificationFailure) {
        res.status(400).json({ error: "jws_invalid" });
        return;
      }
      res.status(500).json({ error: "internal" });
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
      console.info("appstore:notifications no signedTransactionInfo", {
        type: notification.payload.notificationType,
        subtype: notification.payload.subtype,
        notificationUUID: notification.payload.notificationUUID,
      });
      res.status(200).send();
      return;
    }

    const db = getFirestore();
    try {
      await reconcileEntitlement(db, cfg, {
        signedTransactionJWS,
        signedRenewalInfoJWS:
          typeof signedRenewalInfoJWS === "string" && signedRenewalInfoJWS
            ? signedRenewalInfoJWS
            : undefined,
        notificationUUID: notification.payload.notificationUUID,
        notificationType:
          typeof notification.payload.notificationType === "string"
            ? notification.payload.notificationType
            : undefined,
        notificationSubtype:
          typeof notification.payload.subtype === "string"
            ? notification.payload.subtype
            : undefined,
        // No claimed UID for S2S — we resolve uid via the binding doc.
        claimedUid: undefined,
        source: "apple_s2s",
        productID,
      });
      res.status(200).send();
    } catch (err) {
      console.error("appstore:notifications reconcile failed", {
        message: (err as Error).message,
        type: notification.payload.notificationType,
        subtype: notification.payload.subtype,
      });
      // For internal errors return 500 so Apple retries. For known
      // policy errors (binding mismatch, etc.) return 200 so we don't
      // burn through Apple's retry budget on a doomed payload.
      if (err instanceof EntitlementReconcileError) {
        res.status(200).json({ accepted: false, code: err.code });
        return;
      }
      res.status(500).json({ error: "internal" });
    }
  }
);
