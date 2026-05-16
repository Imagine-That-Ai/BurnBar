/**
 * @fileoverview Mercury Phase 5 — VoIP push trigger.
 *
 * `triggerVoIPCall` is called from the Mac when the user starts a 1:1
 * call. It verifies the calling Mac's `hosted_media_sync` entitlement
 * (Decision 2) and forwards an APNs VoIP push to the paired iPhone.
 *
 * Schema:
 *   {
 *     callId: string         — UUID
 *     connectionId: string   — iroh connection id
 *     pairedDeviceId: string — iroh NodeId of the paired iPhone
 *     displayName: string    — what the iPhone CallKit UI shows
 *     isVideo: boolean
 *     voipDeviceToken: string — hex APNs VoIP token cached from iPhone
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
  voipDeviceToken: string;
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
    if (!data?.callId || !data.connectionId || !data.pairedDeviceId || !data.voipDeviceToken) {
      throw new HttpsError("invalid-argument", "Missing required call fields.");
    }
    if (!(await macHasActiveMediaEntitlement(request.auth.uid))) {
      throw new HttpsError(
        "permission-denied",
        "Hosted Media Sync entitlement required to start a call."
      );
    }

    const payload = {
      "aps": {
        "content-available": 1,
      },
      "callId": data.callId,
      "connectionId": data.connectionId,
      "pairedDeviceId": data.pairedDeviceId,
      "displayName": data.displayName,
      "isVideo": data.isVideo,
    };

    // Forward via APNs HTTP/2 push. The actual sender lives in
    // `appstore/apnsClient.ts` (existing Apple push infrastructure for
    // notification flows) — we route through it so the JWT signing +
    // p8 key handling stays centralized. Phase 5b deliverable: surface
    // the apnsClient hook here. For now we emit a Firestore event the
    // existing apnsRouter triggers off so the call surface stays
    // uniform with hermesPairing notifications.
    const firestore = getFirestore();
    await firestore.collection("voip_outbound").add({
      uid: request.auth.uid,
      payload,
      voipDeviceToken: data.voipDeviceToken,
      createdAt: Timestamp.now(),
      status: "pending",
    });

    return { ok: true };
  }
);
