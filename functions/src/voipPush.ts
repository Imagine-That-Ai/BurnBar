/**
 * @fileoverview Mercury Phase 5 — VoIP push fan-out helpers.
 *
 * `triggerVoIPCall` lives in `callables/voipPush.ts`. This module owns
 * request parsing, entitlement checks, and push-channel resolution shared
 * with unit tests (`scripts/test-fcm-android.mjs`).
 *
 * Schema for the callable request:
 *   {
 *     callId: string
 *     connectionId: string
 *     pairedDeviceId: string
 *     displayName: string
 *     isVideo: boolean
 *     voipDeviceToken?: string
 *     androidDeviceId?: string
 *   }
 */

import { getFirestore } from "firebase-admin/firestore";
import { isRecord, isTimestampWithToMillis, stringField } from "./guards.js";

const MEDIA_ENTITLEMENT_DOC_ID = "hosted_media_sync";
const CLOUD_PRO_ENTITLEMENT_DOC_ID = "burnbar_pro_max";
const CLOUD_PRO_PRODUCT_IDS = new Set([
  "com.openburnbar.proMax.v2.monthly",
  "com.openburnbar.proMax.monthly",
  "com.openburnbar.proMax.annual",
  "com.openburnbar.proMax.bundle.monthly",
]);

export interface TriggerRequest {
  callId: string;
  connectionId: string;
  pairedDeviceId: string;
  displayName: string;
  isVideo: boolean;
  voipDeviceToken?: string;
  androidDeviceId?: string;
}

export function parseTriggerRequest(raw: unknown): TriggerRequest | undefined {
  if (!isRecord(raw)) return undefined;
  const callId = stringField(raw, "callId");
  const connectionId = stringField(raw, "connectionId");
  const pairedDeviceId = stringField(raw, "pairedDeviceId");
  const displayName = stringField(raw, "displayName");
  if (!callId || !connectionId || !pairedDeviceId || !displayName) return undefined;
  return {
    callId,
    connectionId,
    pairedDeviceId,
    displayName,
    isVideo: raw.isVideo === true,
    voipDeviceToken: stringField(raw, "voipDeviceToken"),
    androidDeviceId: stringField(raw, "androidDeviceId"),
  };
}

interface ResolvedFanOut {
  apnsToken?: string;
  androidDeviceId?: string;
  fcmToken?: string;
}

/**
 * Pick the freshest push channel for the paired client.
 */
export async function resolveFanOut(args: {
  uid: string;
  pairedDeviceId: string;
  firestore?: FirebaseFirestore.Firestore;
}): Promise<ResolvedFanOut> {
  const firestore = args.firestore ?? getFirestore();
  const deviceId = args.pairedDeviceId?.trim() ?? "";
  if (!deviceId) {
    return {};
  }
  const snap = await firestore.doc(`users/${args.uid}/devices/${deviceId}`).get();
  if (!snap.exists) {
    return {};
  }
  const data = snap.data();
  const apnsToken = isRecord(data)
    ? (stringField(data, "voipDeviceToken") ?? stringField(data, "voip_token"))?.trim()
    : undefined;
  const fcmToken = isRecord(data) ? stringField(data, "fcm_token")?.trim() : undefined;
  const platform = isRecord(data) ? stringField(data, "platform")?.trim().toLowerCase() : undefined;
  if (platform === "android" || (fcmToken && !apnsToken)) {
    return {
      androidDeviceId: deviceId,
      fcmToken,
    };
  }
  if (apnsToken) {
    return { apnsToken };
  }
  if (fcmToken) {
    return {
      androidDeviceId: deviceId,
      fcmToken,
    };
  }
  return {};
}

export async function macHasActiveMediaEntitlement(
  uid: string,
  firestore: FirebaseFirestore.Firestore = getFirestore(),
): Promise<boolean> {
  const [media, pro] = await Promise.all([
    firestore.doc(`users/${uid}/entitlements/${MEDIA_ENTITLEMENT_DOC_ID}`).get(),
    firestore.doc(`users/${uid}/entitlements/${CLOUD_PRO_ENTITLEMENT_DOC_ID}`).get(),
  ]);
  if (media.exists && activeEntitlement(media.data())) {
    return true;
  }
  if (pro.exists && activeEntitlement(pro.data(), CLOUD_PRO_PRODUCT_IDS)) {
    return true;
  }
  return false;
}

function activeEntitlement(data: FirebaseFirestore.DocumentData | undefined, allowedProductIDs?: Set<string>): boolean {
  const entitlement = data ?? {};
  if (entitlement.active !== true) return false;
  if (allowedProductIDs) {
    const productID = typeof entitlement.productID === "string" ? entitlement.productID : "";
    if (!allowedProductIDs.has(productID)) return false;
  }
  const expireAt = entitlement.expireAt;
  if (!isTimestampWithToMillis(expireAt)) return false;
  return expireAt.toMillis() > Date.now();
}
