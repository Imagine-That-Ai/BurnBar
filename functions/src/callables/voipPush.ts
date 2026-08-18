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
import { checkVoIPCallRateLimit } from "./publicRateLimit.js";

function pushQueueTimestamps(nowMillis: number = Date.now()): { createdAt: Timestamp; expireAt: Timestamp } {
  return {
    createdAt: Timestamp.fromMillis(nowMillis),
    expireAt: Timestamp.fromMillis(nowMillis + VOIP_OUTBOUND_TTL_MS),
  };
}

const INCOMING_CALL_CONTEXT_COLLECTION = "incoming_call_contexts";

export const triggerVoIPCall = onCall(
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck },
  wrapCallableHandler("triggerVoIPCall", async (request) => {
    assertAppCheck(request);
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    await checkVoIPCallRateLimit(request.auth.uid);
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

    // T-PRV-01 / T-PRV-07: payloads that leave our trust boundary carry NO
    // cleartext caller displayName and NO stable routing ids. Android resolves
    // the active connection from this owner-scoped, TTL-bound context after
    // receiving the push, keyed by the fresh per-push `correlationId`.
    const correlationId = ephemeralCallCorrelationId();
    const now = Timestamp.now();
    // T-PRV-02 / F-RR09-001: stamp a TTL so undelivered push documents
    // self-expire from Firestore (matched by a ttl:true index on `expireAt`).
    const queueTimestamps = pushQueueTimestamps(now.toMillis());
    // Same instant the queue document self-expires, so the client-side replay
    // window can never outlive the push it came from.
    const pushExpiresAtMillis = queueTimestamps.expireAt.toMillis();

    const writes: Array<Promise<unknown>> = [];

    if (fanOut.apnsToken) {
      writes.push(
        firestore.collection("voip_outbound").add({
          uid: request.auth.uid,
          payload: buildVoipApnsPayload({
            callId: data.callId,
            isVideo: data.isVideo,
            correlationId,
            uid: request.auth.uid,
            expiresAtMillis: pushExpiresAtMillis,
          }),
          voipDeviceToken: fanOut.apnsToken,
          createdAt: queueTimestamps.createdAt,
          expireAt: queueTimestamps.expireAt,
          status: "pending",
        }),
      );
    }

    if (fanOut.fcmToken) {
      writes.push(
        firestore
          .collection("users")
          .doc(request.auth.uid)
          .collection(INCOMING_CALL_CONTEXT_COLLECTION)
          .doc(correlationId)
          .set({
            id: correlationId,
            callId: data.callId,
            connectionId: data.connectionId,
            createdAt: queueTimestamps.createdAt,
            expireAt: queueTimestamps.expireAt,
            schemaVersion: 1,
          }),
      );
      writes.push(
        firestore.collection("fcm_outbound").add({
          uid: request.auth.uid,
          payload: buildFcmCallPayload({
            callId: data.callId,
            isVideo: data.isVideo,
            correlationId,
            uid: request.auth.uid,
            expiresAtMillis: pushExpiresAtMillis,
          }),
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
