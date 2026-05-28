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
const PRO_ENTITLEMENT_DOC_ID = "burnbar_pro";

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
  apnsToken?: string;
  apnsTokenUpdatedAtMillis?: number;
  androidDeviceId?: string;
  firestore?: FirebaseFirestore.Firestore;
}): Promise<ResolvedFanOut> {
  const firestore = args.firestore ?? getFirestore();
  const apnsToken = args.apnsToken?.trim();
  const apnsUpdatedAt = args.apnsTokenUpdatedAtMillis ?? 0;
  let resolvedApns = apnsToken;
  let resolvedAndroidDeviceId = args.androidDeviceId?.trim();
  let fcmToken: string | undefined;
  if (resolvedAndroidDeviceId) {
    const snap = await firestore
      .doc(`users/${args.uid}/devices/${resolvedAndroidDeviceId}`)
      .get();
    const data = snap.exists ? snap.data() : undefined;
    fcmToken = isRecord(data) ? stringField(data, "fcm_token")?.trim() : undefined;
    const fcmUpdatedAt = isRecord(data) ? Number(data.updated_at_millis ?? 0) : 0;
    if (fcmToken) {
      if (!resolvedApns) {
        // Android only.
      } else if (fcmUpdatedAt > apnsUpdatedAt) {
        resolvedApns = undefined;
      } else {
        fcmToken = undefined;
        resolvedAndroidDeviceId = undefined;
      }
    } else {
      resolvedAndroidDeviceId = undefined;
    }
  }
  return {
    apnsToken: resolvedApns,
    androidDeviceId: resolvedAndroidDeviceId,
    fcmToken,
  };
}

export async function macHasActiveMediaEntitlement(uid: string): Promise<boolean> {
  const firestore = getFirestore();
  const [media, pro] = await Promise.all([
    firestore.doc(`users/${uid}/entitlements/${MEDIA_ENTITLEMENT_DOC_ID}`).get(),
    firestore.doc(`users/${uid}/entitlements/${PRO_ENTITLEMENT_DOC_ID}`).get(),
  ]);
  for (const snap of [media, pro]) {
    if (!snap.exists) continue;
    const data = snap.data() ?? {};
    if (data.active !== true) continue;
    const expireAt = data.expireAt;
    if (!isTimestampWithToMillis(expireAt)) continue;
    if (expireAt.toMillis() <= Date.now()) continue;
    return true;
  }
  return false;
}
