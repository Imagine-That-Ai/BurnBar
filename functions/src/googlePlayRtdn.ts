/**
 * @fileoverview Google Play Real-time Developer Notifications reconciliation.
 *
 * RTDN is a signal, not an entitlement assertion. Every subscription event is
 * reconciled against purchases.subscriptionsv2 before Firestore is updated.
 * Purchase tokens are never persisted or logged; only SHA-256 hashes are kept.
 */

import { Timestamp } from "firebase-admin/firestore";
import { onMessagePublished } from "firebase-functions/v2/pubsub";

import { db } from "./adminRuntime.js";
import { getConfig } from "./config.js";
import { jsonObject, stripUndefinedObject } from "./guards.js";
import { logError, logInfo } from "./logging.js";
import { externalApiWithResilience } from "./resilienceHelpers.js";
import { FUNCTIONS_REGION, GOOGLE_PLAY_RTDN_TOPIC } from "./runtimeOptions.js";
import { googlePlayBillingRecordPath } from "./callables/googlePlayBillingPaths.js";
import { GOOGLE_PLAY_TOKEN_CLAIMS_COLLECTION } from "./callables/googlePlayTokenClaims.js";
import {
  GOOGLE_PLAY_ACTIVE_STATES,
  reconcileCloudProTopUpReversal,
  safeCloudDocumentID,
  selectGooglePlaySubscriptionLineItem,
  sha256Hex,
  writeBurnBarProEntitlement,
} from "./callables/shared.js";

const GOOGLE_PLAY_RTDN_EVENT_RETENTION_MS = 90 * 24 * 60 * 60 * 1000;
const GOOGLE_PLAY_RTDN_EVENT_LEASE_MS = 5 * 60 * 1000;

interface GooglePlaySubscriptionNotification {
  version?: unknown;
  notificationType?: unknown;
  purchaseToken?: unknown;
  subscriptionId?: unknown;
}

interface GooglePlayOneTimeProductNotification {
  version?: unknown;
  notificationType?: unknown;
  purchaseToken?: unknown;
  sku?: unknown;
}

interface GooglePlayVoidedPurchaseNotification {
  purchaseToken?: unknown;
  orderId?: unknown;
  productType?: unknown;
  refundType?: unknown;
}

export interface GooglePlayDeveloperNotification {
  version?: unknown;
  packageName?: unknown;
  eventTimeMillis?: unknown;
  testNotification?: unknown;
  subscriptionNotification?: GooglePlaySubscriptionNotification;
  oneTimeProductNotification?: GooglePlayOneTimeProductNotification;
  voidedPurchaseNotification?: GooglePlayVoidedPurchaseNotification;
}

interface GooglePlayRtdnEventMeta {
  eventID: string;
  publishTime?: string;
}

interface GooglePlayTokenClaim {
  uid: string;
  productID: string;
  kind: "subscription" | "topup";
}

type GooglePlayNotificationKind = "test" | "subscription" | "one_time_product" | "voided_purchase" | "unknown";

function eventTimeMillis(payload: GooglePlayDeveloperNotification): number {
  const parsed = typeof payload.eventTimeMillis === "string" ? Number(payload.eventTimeMillis) : Number.NaN;
  return Number.isFinite(parsed) && parsed > 0 ? parsed : Date.now();
}

function eventDocumentID(eventID: string): string {
  try {
    return safeCloudDocumentID(eventID, "eventID");
  } catch {
    return sha256Hex(eventID);
  }
}

function terminalEventStatus(status: unknown): boolean {
  return status === "processed" || status === "ignored" || status === "rejected";
}

function notificationKind(payload: GooglePlayDeveloperNotification): GooglePlayNotificationKind {
  if (payload.testNotification && typeof payload.testNotification === "object") return "test";
  if (payload.subscriptionNotification && typeof payload.subscriptionNotification === "object") return "subscription";
  if (payload.oneTimeProductNotification && typeof payload.oneTimeProductNotification === "object") {
    return "one_time_product";
  }
  if (payload.voidedPurchaseNotification && typeof payload.voidedPurchaseNotification === "object") {
    return "voided_purchase";
  }
  return "unknown";
}

function notificationType(payload: GooglePlayDeveloperNotification): number | undefined {
  const raw =
    payload.subscriptionNotification?.notificationType ??
    payload.oneTimeProductNotification?.notificationType ??
    payload.voidedPurchaseNotification?.refundType;
  return typeof raw === "number" && Number.isFinite(raw) ? raw : undefined;
}

function purchaseToken(payload: GooglePlayDeveloperNotification): string | undefined {
  const raw =
    payload.subscriptionNotification?.purchaseToken ??
    payload.oneTimeProductNotification?.purchaseToken ??
    payload.voidedPurchaseNotification?.purchaseToken;
  return typeof raw === "string" && raw.length > 0 && raw.length <= 4096 ? raw : undefined;
}

function preferredSubscriptionProductIDs(
  payload: GooglePlayDeveloperNotification,
  claim: GooglePlayTokenClaim,
): string[] {
  const notifiedProductID = payload.subscriptionNotification?.subscriptionId;
  return [...(typeof notifiedProductID === "string" ? [notifiedProductID] : []), claim.productID];
}

function rtdnEventRef(eventID: string) {
  return db.doc(`google_play_rtdn_events/${eventDocumentID(eventID)}`);
}

function rtdnEventBase(
  payload: GooglePlayDeveloperNotification,
  meta: GooglePlayRtdnEventMeta,
  extra: Record<string, unknown> = {},
): Record<string, unknown> {
  const sourceEventCreatedMillis = eventTimeMillis(payload);
  return stripUndefinedObject({
    eventID: meta.eventID,
    packageName: typeof payload.packageName === "string" ? payload.packageName : undefined,
    notificationKind: notificationKind(payload),
    notificationType: notificationType(payload),
    sourceEventCreatedMillis,
    publishTime: meta.publishTime,
    updatedAt: Timestamp.now(),
    expireAt: Timestamp.fromMillis(sourceEventCreatedMillis + GOOGLE_PLAY_RTDN_EVENT_RETENTION_MS),
    schemaVersion: 1,
    ...extra,
  });
}

type GooglePlayRtdnReservation = "reserved" | "processing" | "terminal";

async function reserveGooglePlayRtdnEvent(
  payload: GooglePlayDeveloperNotification,
  meta: GooglePlayRtdnEventMeta,
): Promise<GooglePlayRtdnReservation> {
  const ref = rtdnEventRef(meta.eventID);
  const nowMillis = Date.now();
  return db.runTransaction(async (transaction) => {
    const existing = await transaction.get(ref);
    const status = existing.get("status");
    if (terminalEventStatus(status)) return "terminal";

    const leaseExpiresAt = existing.get("leaseExpiresAt");
    const leaseExpiresAtMillis =
      leaseExpiresAt instanceof Timestamp
        ? leaseExpiresAt.toMillis()
        : typeof leaseExpiresAt?.toMillis === "function"
          ? leaseExpiresAt.toMillis()
          : 0;
    if (status === "processing" && leaseExpiresAtMillis > nowMillis) {
      return "processing";
    }

    transaction.set(
      ref,
      rtdnEventBase(payload, meta, {
        status: "processing",
        processingStartedAt: Timestamp.fromMillis(nowMillis),
        leaseExpiresAt: Timestamp.fromMillis(nowMillis + GOOGLE_PLAY_RTDN_EVENT_LEASE_MS),
      }),
      { merge: true },
    );
    return "reserved";
  });
}

async function readTokenClaim(tokenHash: string): Promise<GooglePlayTokenClaim | undefined> {
  const snap = await db.doc(`${GOOGLE_PLAY_TOKEN_CLAIMS_COLLECTION}/${tokenHash}`).get();
  if (!snap.exists) return undefined;
  const uid = snap.get("uid");
  const productID = snap.get("productID");
  const kind = snap.get("kind");
  if (typeof uid !== "string" || typeof productID !== "string" || (kind !== "subscription" && kind !== "topup")) {
    return undefined;
  }
  return { uid, productID, kind };
}

async function googlePlayPublisher() {
  const { google } = await import("googleapis");
  const authClient = await google.auth.getClient({
    scopes: ["https://www.googleapis.com/auth/androidpublisher"],
  });
  return google.androidpublisher({ version: "v3", auth: authClient });
}

async function reconcileSubscription(
  payload: GooglePlayDeveloperNotification,
  meta: GooglePlayRtdnEventMeta,
  token: string,
  tokenHash: string,
  claim: GooglePlayTokenClaim,
  forceInactive: boolean,
): Promise<void> {
  const cfg = getConfig();
  const androidpublisher = await googlePlayPublisher();
  const response = await externalApiWithResilience("googleplay.rtdn.subscriptionsv2.get", () =>
    androidpublisher.purchases.subscriptionsv2.get({
      packageName: cfg.googlePlayPackageName,
      token,
    }),
  );
  const purchase = jsonObject(response.data);
  const subscriptionState =
    typeof purchase.subscriptionState === "string" ? purchase.subscriptionState : "SUBSCRIPTION_STATE_UNSPECIFIED";
  const { lineItem, target, expiresAtMillis } = selectGooglePlaySubscriptionLineItem(
    purchase,
    preferredSubscriptionProductIDs(payload, claim),
  );
  const active = !forceInactive && GOOGLE_PLAY_ACTIVE_STATES.has(subscriptionState) && expiresAtMillis > Date.now();
  const sourceEventCreatedMillis = eventTimeMillis(payload);

  await writeBurnBarProEntitlement({
    uid: claim.uid,
    productID: target.canonicalProductID,
    expiresAtMillis,
    source: "google_play_verified",
    platform: "android",
    entitlementID: target.entitlementID,
    purchaseTokenHash: tokenHash,
    rawStatus: forceInactive ? "VOIDED_PURCHASE" : subscriptionState,
    environment: "Production",
    activeOverride: active,
    sourceEventID: meta.eventID,
    sourceEventCreatedMillis,
  });
  await Promise.all([
    db.doc(`${GOOGLE_PLAY_TOKEN_CLAIMS_COLLECTION}/${tokenHash}`).set(
      {
        productID: target.canonicalProductID,
        lastNotificationAt: Timestamp.now(),
        updatedAt: Timestamp.now(),
      },
      { merge: true },
    ),
    db.doc(googlePlayBillingRecordPath(claim.uid, "purchase", tokenHash)).set(
      stripUndefinedObject({
        uid: claim.uid,
        productID: target.canonicalProductID,
        entitlementID: target.entitlementID,
        purchaseTokenHash: tokenHash,
        subscriptionState,
        active,
        expiresAt: new Date(expiresAtMillis).toISOString(),
        lineItemProductID: typeof lineItem.productId === "string" ? lineItem.productId : undefined,
        rtdnEventID: meta.eventID,
        rtdnNotificationType: notificationType(payload),
        lastVerifiedAt: new Date(sourceEventCreatedMillis).toISOString(),
        schemaVersion: 1,
      }),
      { merge: true },
    ),
  ]);
}

async function reverseVoidedTopUp(
  payload: GooglePlayDeveloperNotification,
  meta: GooglePlayRtdnEventMeta,
  tokenHash: string,
  claim: GooglePlayTokenClaim,
): Promise<void> {
  const receiptID = `google_play_${tokenHash}`;
  const reversal = await reconcileCloudProTopUpReversal({
    uid: claim.uid,
    receiptID,
    fullReversalReason: "google_play_voided_purchase",
    sourceEventID: meta.eventID,
    sourceEventCreatedMillis: eventTimeMillis(payload),
  });
  await db.doc(googlePlayBillingRecordPath(claim.uid, "topup", tokenHash)).set(
    {
      purchaseTokenHash: tokenHash,
      rtdnEventID: meta.eventID,
      rtdnNotificationType: notificationType(payload),
      voided: true,
      reversedUnits: reversal.reversedUnits,
      reversalAdjusted: reversal.adjusted,
      lastVerifiedAt: Timestamp.now(),
      schemaVersion: 1,
    },
    { merge: true },
  );
}

export async function processGooglePlayDeveloperNotification(
  payload: GooglePlayDeveloperNotification,
  meta: GooglePlayRtdnEventMeta,
): Promise<void> {
  const ref = rtdnEventRef(meta.eventID);
  const reservation = await reserveGooglePlayRtdnEvent(payload, meta);
  if (reservation !== "reserved") return;

  const cfg = getConfig();
  const kind = notificationKind(payload);
  if (payload.packageName !== cfg.googlePlayPackageName) {
    await ref.set(
      rtdnEventBase(payload, meta, {
        status: "rejected",
        reason: "package_mismatch",
      }),
      { merge: true },
    );
    return;
  }
  if (kind === "test") {
    await ref.set(rtdnEventBase(payload, meta, { status: "processed", testNotification: true }), {
      merge: true,
    });
    return;
  }
  if (kind === "unknown") {
    await ref.set(rtdnEventBase(payload, meta, { status: "rejected", reason: "unknown_notification" }), {
      merge: true,
    });
    return;
  }

  const token = purchaseToken(payload);
  if (!token) {
    await ref.set(rtdnEventBase(payload, meta, { status: "rejected", reason: "missing_purchase_token" }), {
      merge: true,
    });
    return;
  }
  const tokenHash = sha256Hex(token);
  const claim = await readTokenClaim(tokenHash);
  if (!claim) {
    // The client verification path reads current state directly from Google.
    // Therefore an RTDN that races ahead of the first client claim can be
    // acknowledged safely without persisting the raw purchase token.
    await ref.set(
      rtdnEventBase(payload, meta, {
        status: "ignored",
        reason: "unclaimed_purchase_token",
        purchaseTokenHash: tokenHash,
      }),
      { merge: true },
    );
    return;
  }

  if (kind === "subscription" && claim.kind !== "subscription") {
    await ref.set(
      rtdnEventBase(payload, meta, {
        status: "rejected",
        reason: "claim_kind_mismatch",
        purchaseTokenHash: tokenHash,
      }),
      { merge: true },
    );
    return;
  }
  if (kind === "one_time_product" && claim.kind !== "topup") {
    await ref.set(
      rtdnEventBase(payload, meta, {
        status: "rejected",
        reason: "claim_kind_mismatch",
        purchaseTokenHash: tokenHash,
      }),
      { merge: true },
    );
    return;
  }

  try {
    if (kind === "subscription") {
      await reconcileSubscription(payload, meta, token, tokenHash, claim, false);
    } else if (kind === "voided_purchase") {
      if (claim.kind === "subscription") {
        await reconcileSubscription(payload, meta, token, tokenHash, claim, true);
      } else {
        await reverseVoidedTopUp(payload, meta, tokenHash, claim);
      }
    } else if (kind === "one_time_product" && notificationType(payload) === 2) {
      await reverseVoidedTopUp(payload, meta, tokenHash, claim);
    }
    await ref.set(
      rtdnEventBase(payload, meta, {
        status: "processed",
        purchaseTokenHash: tokenHash,
        uid: claim.uid,
        claimKind: claim.kind,
      }),
      { merge: true },
    );
    logInfo({
      event: "google_play_rtdn_processed",
      notification_kind: kind,
      notification_type: notificationType(payload),
      uid: claim.uid,
    });
  } catch (error) {
    await ref
      .set(
        rtdnEventBase(payload, meta, {
          status: "failed",
          leaseExpiresAt: Timestamp.now(),
          purchaseTokenHash: tokenHash,
          uid: claim.uid,
          claimKind: claim.kind,
          errorCode:
            typeof error === "object" && error !== null && typeof Reflect.get(error, "code") === "number"
              ? Reflect.get(error, "code")
              : "unknown",
        }),
        { merge: true },
      )
      .catch(() => undefined);
    logError({
      event: "google_play_rtdn_failed",
      notification_kind: kind,
      notification_type: notificationType(payload),
      uid: claim.uid,
      error: error instanceof Error ? error.name : "unknown",
    });
    throw error;
  }
}

export const googlePlayDeveloperNotifications = onMessagePublished<GooglePlayDeveloperNotification>(
  {
    topic: GOOGLE_PLAY_RTDN_TOPIC,
    region: FUNCTIONS_REGION,
    retry: true,
    maxInstances: 20,
    concurrency: 20,
    timeoutSeconds: 120,
  },
  async (event) => {
    await processGooglePlayDeveloperNotification(event.data.message.json, {
      eventID: event.id,
      publishTime: event.data.message.publishTime,
    });
  },
);
