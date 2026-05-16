/**
 * @fileoverview Mercury Phase 5 — VoIP push trigger.
 *
 * `triggerVoIPCall` is called from the Mac when the user starts a 1:1
 * call. It verifies the calling Mac's `hosted_media_sync` entitlement
 * (Decision 2) and forwards an APNs VoIP push to the paired iPhone, or
 * a high-priority FCM data message to the paired Android device. Phase
 * 6 added the Android branch: when the request's `voipDeviceToken` is
 * empty / stale and an FCM token doc under
 * `users/{uid}/devices/{deviceId}/fcm_token` is fresher, the function
 * emits an `fcm_outbound` document that `sendFcmOutbound`
 * (`fcmAndroidSender.ts`) drains through `admin.messaging().send(...)`.
 *
 * Schema:
 *   {
 *     callId: string         — UUID
 *     connectionId: string   — iroh connection id
 *     pairedDeviceId: string — iroh NodeId of the paired client
 *     displayName: string    — what the CallKit / IncomingCallActivity sheet shows
 *     isVideo: boolean
 *     voipDeviceToken?: string — hex APNs VoIP token cached from the paired iPhone, optional
 *     androidDeviceId?: string — `Settings.Secure.ANDROID_ID` SHA-256 hash for the paired Android
 *   }
 */

import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

const MEDIA_ENTITLEMENT_DOC_ID = "hosted_media_sync";
const PRO_ENTITLEMENT_DOC_ID = "burnbar_pro";

interface TriggerRequest {
  callId: string;
  connectionId: string;
  pairedDeviceId: string;
  displayName: string;
  isVideo: boolean;
  voipDeviceToken?: string;
  androidDeviceId?: string;
}

interface ResolvedFanOut {
  /** APNs hex token (or undefined when the freshest token is Android). */
  apnsToken?: string;
  /** Android device id (`users/{uid}/devices/{deviceId}/fcm_token`). */
  androidDeviceId?: string;
  /** FCM registration token resolved from the Android device doc. */
  fcmToken?: string;
}

/**
 * Pick the freshest push channel for the paired client. Reads the
 * Android FCM token doc under `users/{uid}/devices/{deviceId}/fcm_token`
 * — when it's strictly newer than the request's APNs token timestamp
 * (recorded as `voipDeviceTokenUpdatedAtMillis` by the iPhone), the
 * Android branch wins. The function exports the helper so unit tests
 * can pin the ordering.
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
  // The iOS client writes its APNs token to `users/{uid}/devices/{deviceId}/voip_token`
  // and includes `updated_at_millis` for staleness. When the caller didn't
  // pass either, fall back to the request-provided token.
  let resolvedApns = apnsToken;
  let resolvedAndroidDeviceId = args.androidDeviceId?.trim();
  let fcmToken: string | undefined;
  if (resolvedAndroidDeviceId) {
    const snap = await firestore
      .doc(`users/${args.uid}/devices/${resolvedAndroidDeviceId}`)
      .get();
    const data = snap.exists ? (snap.data() as Record<string, unknown>) : undefined;
    fcmToken = (data?.["fcm_token"] as string | undefined)?.trim() || undefined;
    const fcmUpdatedAt = Number(data?.["updated_at_millis"] ?? 0);
    if (fcmToken) {
      // If we have both, prefer the freshest one. With only an FCM
      // token, that's our channel. If FCM is older than APNs, drop it
      // so we don't double-page the user.
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

async function macHasActiveMediaEntitlement(uid: string): Promise<boolean> {
  const firestore = getFirestore();
  const [media, pro] = await Promise.all([
    firestore.doc(`users/${uid}/entitlements/${MEDIA_ENTITLEMENT_DOC_ID}`).get(),
    firestore.doc(`users/${uid}/entitlements/${PRO_ENTITLEMENT_DOC_ID}`).get(),
  ]);
  for (const snap of [media, pro]) {
    if (!snap.exists) continue;
    const data = snap.data() ?? {};
    if (data.active !== true) continue;
    const expireAt = data.expireAt as Timestamp | undefined;
    if (!expireAt) continue;
    if (expireAt.toMillis() <= Date.now()) continue;
    return true;
  }
  return false;
}

export const triggerVoIPCall = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const data = request.data as TriggerRequest;
    if (!data?.callId || !data.connectionId || !data.pairedDeviceId) {
      throw new HttpsError("invalid-argument", "Missing required call fields.");
    }
    if (!data.voipDeviceToken && !data.androidDeviceId) {
      throw new HttpsError(
        "invalid-argument",
        "Either voipDeviceToken (APNs) or androidDeviceId (FCM) must be provided."
      );
    }
    if (!(await macHasActiveMediaEntitlement(request.auth.uid))) {
      throw new HttpsError(
        "permission-denied",
        "Hosted Media Sync entitlement required to start a call."
      );
    }

    const firestore = getFirestore();
    const fanOut = await resolveFanOut({
      uid: request.auth.uid,
      apnsToken: data.voipDeviceToken,
      androidDeviceId: data.androidDeviceId,
      firestore,
    });

    const sharedFields = {
      callId: data.callId,
      connectionId: data.connectionId,
      pairedDeviceId: data.pairedDeviceId,
      displayName: data.displayName,
      isVideo: data.isVideo,
    };

    const writes: Array<Promise<unknown>> = [];

    if (fanOut.apnsToken) {
      const apnsPayload = {
        "aps": {
          "content-available": 1,
        },
        ...sharedFields,
      };
      writes.push(
        firestore.collection("voip_outbound").add({
          uid: request.auth.uid,
          payload: apnsPayload,
          voipDeviceToken: fanOut.apnsToken,
          createdAt: Timestamp.now(),
          status: "pending",
        })
      );
    }

    if (fanOut.fcmToken) {
      const fcmPayload: Record<string, string> = {
        type: "media_incoming_call",
        connection_id: sharedFields.connectionId,
        caller_name: sharedFields.displayName,
        caller_initial: (sharedFields.displayName ?? "M").slice(0, 1).toUpperCase(),
        feature: sharedFields.isVideo ? "videoCall" : "voiceCall",
        call_id: sharedFields.callId,
        paired_device_id: sharedFields.pairedDeviceId,
      };
      writes.push(
        firestore.collection("fcm_outbound").add({
          uid: request.auth.uid,
          payload: fcmPayload,
          fcmToken: fanOut.fcmToken,
          androidDeviceId: fanOut.androidDeviceId ?? null,
          createdAt: Timestamp.now(),
          status: "pending",
        })
      );
    }

    if (writes.length === 0) {
      throw new HttpsError(
        "failed-precondition",
        "No push channel available for the paired device."
      );
    }

    await Promise.all(writes);

    return {
      ok: true,
      channels: {
        apns: Boolean(fanOut.apnsToken),
        fcm: Boolean(fanOut.fcmToken),
      },
    };
  }
);
