/**
 * @fileoverview Mercury media SKU lifecycle callables.
 *
 * - `grantMediaGrandfather` — one-shot grandfather for existing hosted_quota_sync
 *   subscribers (90-day hosted_media_sync entitlement).
 * - `validateMediaPurchase` — retired standalone media purchase path. Kept as a
 *   fail-closed callable so old clients receive a controlled error instead of
 *   writing a client-attested entitlement.
 */

import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

import { assertAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { isRecord, stringField } from "../guards.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const MEDIA_SKU = "com.openburnbar.hostedMediaSync.monthly";
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
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck },
  wrapCallableHandler("grantMediaGrandfather", async (request) => {
    assertAppCheck(request);
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    if (request.auth.token?.mediaSkuAdmin !== true) {
      throw new HttpsError("permission-denied", "mediaSkuAdmin claim required.");
    }

    const firestore = getFirestore();
    const subs = await firestore.collectionGroup("entitlements").where("active", "==", true).get();

    let granted = 0;
    let skipped = 0;

    for (const doc of subs.docs) {
      const segments = doc.ref.path.split("/");
      if (segments.length !== 4 || segments[0] !== "users") continue;
      const uid = segments[1];
      const entitlementId = segments[3];
      if (entitlementId !== QUOTA_SKU_DOC_ID) continue;

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
        productID: MEDIA_SKU,
        expireAt: nowPlusDays(GRANDFATHER_WINDOW_DAYS),
        features: {
          fileTransfer: true,
          screenShare: false,
          videoCall: false,
        },
        grantedBy: "grandfather",
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
  }),
);

export const validateMediaPurchase = onCall(
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck },
  wrapCallableHandler("validateMediaPurchase", async (request) => {
    assertAppCheck(request);
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    throw new HttpsError(
      "failed-precondition",
      "The standalone media subscription is retired. Upgrade to BurnBar Cloud Pro for Floo.",
    );
  }),
);
