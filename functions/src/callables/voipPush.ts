/**
 * @fileoverview Mercury VoIP / FCM call trigger callable.
 */

import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

import { assertAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import { macHasActiveMediaEntitlement, parseTriggerRequest, resolveFanOut } from "../voipPush.js";

export const triggerVoIPCall = onCall(
  { region: "us-central1", enforceAppCheck: getConfig().enforceAppCheck },
  wrapCallableHandler("triggerVoIPCall", async (request) => {
    assertAppCheck(request);
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const data = parseTriggerRequest(request.data);
    if (!data) {
      throw new HttpsError("invalid-argument", "Missing required call fields.");
    }
    if (!data.voipDeviceToken && !data.androidDeviceId) {
      throw new HttpsError(
        "invalid-argument",
        "Either voipDeviceToken (APNs) or androidDeviceId (FCM) must be provided.",
      );
    }
    if (!(await macHasActiveMediaEntitlement(request.auth.uid))) {
      throw new HttpsError("permission-denied", "Hosted Media Sync entitlement required to start a call.");
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
        aps: {
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
        }),
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
        }),
      );
    }

    if (writes.length === 0) {
      throw new HttpsError("failed-precondition", "No push channel available for the paired device.");
    }

    await Promise.all(writes);

    logInfo({
      event: "callable_info",
      message: "voip_call_triggered",
      call_id: data.callId,
      apns: Boolean(fanOut.apnsToken),
      fcm: Boolean(fanOut.fcmToken),
    });

    return {
      ok: true,
      channels: {
        apns: Boolean(fanOut.apnsToken),
        fcm: Boolean(fanOut.fcmToken),
      },
    };
  }),
);
