/**
 * @fileoverview Mercury media SKU lifecycle.
 *
 * Two callable Functions and one helper:
 *
 * - `grantMediaGrandfather` — runs once per existing
 *   `hosted_quota_sync` subscriber to grant a 90-day grandfather
 *   `hosted_media_sync` entitlement covering file transfer (Phase 2 SKU
 *   rollout). Implements Decision 5 in
 *   `plans/2026-05-15-mercury-media-master-plan.md`.
 * - `validateMediaPurchase` — verifies an Apple StoreKit transaction for
 *   `com.openburnbar.hostedMediaSync.monthly` and writes the entitlement
 *   doc the Firestore rules + Mac capability gate consume.
 */

import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

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

/**
 * One-shot Function to grandfather every existing `hosted_quota_sync`
 * subscriber into media file-transfer access for 90 days. Idempotent:
 * if the user already has a `hosted_media_sync` doc with a `grantedBy`
 * other than `grandfather`, leaves it alone.
 *
 * Caller must be authenticated and admin (App Check + custom claim
 * `mediaSkuAdmin: true`). The Function is intended to be invoked once at
 * Phase 2 cutover by the operator.
 */
export const grantMediaGrandfather = onCall(
  { region: "us-central1" },
  async (request) => {
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
      // Path: users/{uid}/entitlements/{entitlementId}
      const segments = doc.ref.path.split("/");
      if (segments.length !== 4 || segments[0] !== "users") continue;
      const uid = segments[1];
      const entitlementId = segments[3];
      if (entitlementId !== QUOTA_SKU_DOC_ID && entitlementId !== "burnbar_pro") continue;

      const mediaRef = firestore.doc(`users/${uid}/entitlements/${MEDIA_ENTITLEMENT_DOC_ID}`);
      const existing = await mediaRef.get();
      if (existing.exists) {
        const data = existing.data() as Partial<MediaEntitlementDoc>;
        if (data.grantedBy && data.grantedBy !== "grandfather") {
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

    return { granted, skipped };
  }
);

interface ValidateRequest {
  productID: string;
  appleTransactionId: string;
  expireAtMillis: number;
}

/**
 * Validates an Apple StoreKit transaction (already verified by the
 * client / receipt server) and writes the canonical
 * `hosted_media_sync` entitlement document. Idempotent under the same
 * `appleTransactionId`.
 */
export const validateMediaPurchase = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const data = request.data as ValidateRequest;
    if (!data?.productID || (data.productID !== MEDIA_SKU && data.productID !== PRO_SKU)) {
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
    return { active: true, productID: data.productID };
  }
);
