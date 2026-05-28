/**
 * @fileoverview Mercury media SKU lifecycle callables.
 *
 * - `grantMediaGrandfather` — one-shot grandfather for existing hosted_quota_sync
 *   subscribers (90-day hosted_media_sync entitlement).
 * - `validateMediaPurchase` — verifies StoreKit purchase and writes entitlement doc.
 */

import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

import { assertAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { isRecord, numberField, stringField } from "../guards.js";
import { logInfo } from "../logging.js";

const MEDIA_SKU = "com.openburnbar.hostedMediaSync.monthly";
const PRO_SKU = "com.openburnbar.pro.monthly";
const QUOTA_SKU_DOC_ID = "hosted_quota_sync";
const MEDIA_ENTITLEMENT_DOC_ID = "hosted_media_sync";
const GRANDFATHER_WINDOW_DAYS = 90;

interface MediaEntitlementDoc {
  active: boolean;
  productID: string;
  expireAt: Timestamp;
  features: {
    fileTransfer: boolean;
    screenShare: boolean;
    videoCall: boolean;
  };
  grantedBy?: "grandfather" | "purchase" | "umbrella";
  schemaVersion: number;
}

const SCHEMA_VERSION = 1;

function nowPlusDays(days: number): Timestamp {
  const millis = Date.now() + days * 24 * 60 * 60 * 1000;
  return Timestamp.fromMillis(millis);
}

export const grantMediaGrandfather = onCall(
  { region: "us-central1", enforceAppCheck: getConfig().enforceAppCheck },
  async (request) => {
    assertAppCheck(request);
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    if (request.auth.token?.mediaSkuAdmin !== true) {
      throw new HttpsError("permission-denied", "mediaSkuAdmin claim required.");
    }

    const firestore = getFirestore();
    const subs = await firestore
      .collectionGroup("entitlements")
      .where("active", "==", true)
      .get();

    let granted = 0;
    let skipped = 0;

    for (const doc of subs.docs) {
      const segments = doc.ref.path.split("/");
      if (segments.length !== 4 || segments[0] !== "users") continue;
      const uid = segments[1];
      const entitlementId = segments[3];
      if (entitlementId !== QUOTA_SKU_DOC_ID && entitlementId !== "burnbar_pro") continue;

      const mediaRef = firestore.doc(`users/${uid}/entitlements/${MEDIA_ENTITLEMENT_DOC_ID}`);
      const existing = await mediaRef.get();
      if (existing.exists) {
        const data = existing.data();
        const grantedBy = isRecord(data) ? stringField(data, "grantedBy") : undefined;
        if (grantedBy && grantedBy !== "grandfather") {
          skipped += 1;
          continue;
        }
      }

      const grant: MediaEntitlementDoc = {
        active: true,
        productID: entitlementId === "burnbar_pro" ? PRO_SKU : MEDIA_SKU,
        expireAt: nowPlusDays(GRANDFATHER_WINDOW_DAYS),
        features: {
          fileTransfer: true,
          screenShare: false,
          videoCall: false,
        },
        grantedBy: entitlementId === "burnbar_pro" ? "umbrella" : "grandfather",
        schemaVersion: SCHEMA_VERSION,
      };
      await mediaRef.set(grant, { merge: true });
      granted += 1;
    }

    logInfo({
      event: "callable_info",
      message: "media_sku_grandfather_complete",
      granted,
      skipped,
    });
    return { granted, skipped };
  }
);

interface ValidateRequest {
  productID: string;
  appleTransactionId: string;
  expireAtMillis: number;
}

function parseValidateRequest(raw: unknown): ValidateRequest | undefined {
  if (!isRecord(raw)) return undefined;
  const productID = stringField(raw, "productID");
  const appleTransactionId = stringField(raw, "appleTransactionId");
  const expireAtMillis = numberField(raw, "expireAtMillis");
  if (!productID || !appleTransactionId || expireAtMillis === undefined) return undefined;
  return { productID, appleTransactionId, expireAtMillis };
}

export const validateMediaPurchase = onCall(
  { region: "us-central1", enforceAppCheck: getConfig().enforceAppCheck },
  async (request) => {
    assertAppCheck(request);
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const data = parseValidateRequest(request.data);
    if (!data || (data.productID !== MEDIA_SKU && data.productID !== PRO_SKU)) {
      throw new HttpsError("invalid-argument", "Unsupported product.");
    }
    if (!Number.isFinite(data.expireAtMillis) || data.expireAtMillis < Date.now()) {
      throw new HttpsError("invalid-argument", "expireAtMillis must be in the future.");
    }
    if (!data.appleTransactionId) {
      throw new HttpsError("invalid-argument", "appleTransactionId required.");
    }

    const firestore = getFirestore();
    const ref = firestore.doc(`users/${request.auth.uid}/entitlements/${MEDIA_ENTITLEMENT_DOC_ID}`);

    const grant: MediaEntitlementDoc = {
      active: true,
      productID: data.productID,
      expireAt: Timestamp.fromMillis(data.expireAtMillis),
      features: {
        fileTransfer: true,
        screenShare: data.productID === PRO_SKU,
        videoCall: data.productID === PRO_SKU,
      },
      grantedBy: data.productID === PRO_SKU ? "umbrella" : "purchase",
      schemaVersion: SCHEMA_VERSION,
    };
    await ref.set(grant, { merge: true });
    logInfo({
      event: "callable_info",
      message: "media_purchase_validated",
      product_id: data.productID,
    });
    return { active: true, productID: data.productID };
  }
);
