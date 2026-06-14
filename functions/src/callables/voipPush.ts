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
} from "../voipPush.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

// F-RR09-001: bound retention of push-queue docs (which carry uid + cleartext
// caller name + live push tokens). Delivery + retry settle in minutes, so a
// 7-day TTL never races delivery — it caps how long an undelivered/terminal
// doc lingers. Account deletion additionally sweeps these by uid; this TTL is
// the safety net for docs that belong to a still-active account.
const PUSH_QUEUE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

function pushQueueTimestamps(nowMillis: number = Date.now()): { createdAt: Timestamp; expireAt: Timestamp } {
  return {
    createdAt: Timestamp.fromMillis(nowMillis),
    expireAt: Timestamp.fromMillis(nowMillis + PUSH_QUEUE_TTL_MS),
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
    // T-PRV-02 / F-RR09-001: stamp a TTL so undelivered push documents self-expire from
    // Firestore (matched by a ttl:true index on `expireAt`). Use 7-day retention.
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
      writes.push(
        firestore.collection("fcm_outbound").add({
          uid: request.auth.uid,
          payload: buildFcmCallPayload({ callId: data.callId, isVideo: data.isVideo, correlationId }),
          fcmToken: fanOut.fcmToken,
          androidDeviceId: fanOut.androidDeviceId ?? null,
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
