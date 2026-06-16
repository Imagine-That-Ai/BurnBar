/**
 * @fileoverview Mercury VoIP / FCM call trigger callable.
 */

import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

import { assertAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import {
  buildFcmCallPayload,
  buildVoipApnsPayload,
  ephemeralCallCorrelationId,
  macHasActiveMediaEntitlement,
  parseTriggerRequest,
  resolveFanOut,
  VOIP_OUTBOUND_TTL_MS,
} from "../voipPush.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

function pushQueueTimestamps(nowMillis: number = Date.now()): { createdAt: Timestamp; expireAt: Timestamp } {
  return {
    createdAt: Timestamp.fromMillis(nowMillis),
    expireAt: Timestamp.fromMillis(nowMillis + VOIP_OUTBOUND_TTL_MS),
  };
}

export const triggerVoIPCall = onCall(
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck },
  wrapCallableHandler("triggerVoIPCall", async (request) => {
    assertAppCheck(request);
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const data = parseTriggerRequest(request.data);
    if (!data) {
      throw new HttpsError("invalid-argument", "Missing required call fields.");
    }
    if (!data.pairedDeviceId) {
      throw new HttpsError("invalid-argument", "pairedDeviceId is required.");
    }
    if (!(await macHasActiveMediaEntitlement(request.auth.uid))) {
      throw new HttpsError("permission-denied", "Hosted Media Sync entitlement required to start a call.");
    }

    const firestore = getFirestore();
    const fanOut = await resolveFanOut({
      uid: request.auth.uid,
      pairedDeviceId: data.pairedDeviceId,
      firestore,
    });

    // T-PRV-01 / T-PRV-07: the push payload that leaves our trust boundary
    // (APNs / FCM, both readable by a cross-service push processor) carries NO
    // cleartext caller displayName and NO stable correlators (connection_id /
    // paired_device_id). The client resolves the real caller + connection from
    // its own sealed session state keyed on `callId`. A fresh, per-push
    // `correlationId` lets the device dedupe duplicate fan-outs without exposing
    // a stable identifier that links the device across sessions.
    const correlationId = ephemeralCallCorrelationId();
    const now = Timestamp.now();
    // T-PRV-02 / F-RR09-001: stamp a TTL so undelivered push documents
    // self-expire from Firestore (matched by a ttl:true index on `expireAt`).
    const queueTimestamps = pushQueueTimestamps(now.toMillis());

    const writes: Array<Promise<unknown>> = [];

    if (fanOut.apnsToken) {
      writes.push(
        firestore.collection("voip_outbound").add({
          uid: request.auth.uid,
          payload: buildVoipApnsPayload({ callId: data.callId, isVideo: data.isVideo, correlationId }),
          voipDeviceToken: fanOut.apnsToken,
          createdAt: queueTimestamps.createdAt,
          expireAt: queueTimestamps.expireAt,
          status: "pending",
        }),
      );
    }

    if (fanOut.fcmToken) {
      // T-PRV-07: the persisted `fcm_outbound` doc deliberately omits
      // `androidDeviceId`. Delivery routing is keyed solely on `fcmToken`
      // (the only field read back by `sendFcmOutbound` and the stuck-push
      // sweeper in `fcmAndroidSender.ts`); the stable per-device id is never
      // consumed from the persisted doc, so persisting it would only leave a
      // stable cross-session correlator at rest inside this short-lived
      // (15-min TTL) queue document. `uid` remains for account-erase fan-out.
      writes.push(
        firestore.collection("fcm_outbound").add({
          uid: request.auth.uid,
          payload: buildFcmCallPayload({ callId: data.callId, isVideo: data.isVideo, correlationId }),
          fcmToken: fanOut.fcmToken,
          createdAt: queueTimestamps.createdAt,
          expireAt: queueTimestamps.expireAt,
          status: "pending",
        }),
      );
    }

    if (writes.length === 0) {
      throw new HttpsError(
        "failed-precondition",
        "No push channel available for the paired device. Ensure the phone has registered push tokens.",
      );
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
