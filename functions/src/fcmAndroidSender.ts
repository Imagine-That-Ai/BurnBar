import { errorCode, errorMessage, isRecord, stringValue } from "./guards.js";
/**
 * @fileoverview Mercury Phase 6 — Android FCM data-message sender.
 *
 * Counterpart to `apnsSender.ts` for the Android branch. Android does
 * not have PushKit / VoIP pushes — instead Mercury uses a **high
 * priority data-only FCM message** routed to `MercuryFcmService`, which
 * in turn launches `IncomingCallActivity` via a full-screen
 * notification intent.
 *
 * Lifecycle of an `fcm_outbound` document:
 *   created → status: "pending"
 *   sent successfully → status: "sent", deliveredAt: Timestamp
 *   transient failure (5xx, network) → status: "pending" with retryAt
 *   permanent failure (UNREGISTERED, INVALID_ARGUMENT, …) → status: "rejected"
 *
 * The companion `triggerVoIPCall` callable in `voipPush.ts` chooses
 * between `voip_outbound` (APNs) and `fcm_outbound` (Android) based on
 * the freshness of the per-device token doc the paired client wrote to
 * `users/{uid}/devices/{deviceId}/fcm_token` versus the APNs token
 * cached on the call request. This module owns the Android branch in
 * isolation so APNs flows stay unchanged.
 */

import { Timestamp, getFirestore, type Firestore } from "firebase-admin/firestore";
import { getMessaging, type Message } from "firebase-admin/messaging";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import {
  claimPendingPush,
  collectRetryablePushRefs,
  finishClaimedPush,
  nextPushRetryAt,
  pushWithResilience,
} from "./resilienceHelpers.js";

export interface SendResult {
  status: "sent" | "rejected" | "retry";
  messageId?: string;
  errorCode?: string;
  reason?: string;
}

/**
 * Push the given payload to FCM. Pure function so unit tests can mock
 * `getMessaging()` via an injected sender.
 *
 * Permanent vs transient classification follows the official Admin SDK
 * error codes documented at
 * https://firebase.google.com/docs/cloud-messaging/send-message#admin
 *
 * | error code                                | classification |
 * | ----------------------------------------- | -------------- |
 * | `messaging/registration-token-not-registered` | rejected — uninstall / token wipe |
 * | `messaging/invalid-registration-token`        | rejected — token corrupt |
 * | `messaging/invalid-argument`                  | rejected — payload malformed |
 * | `messaging/quota-exceeded` etc.               | retry — transient |
 * | network / 5xx                                  | retry — transient |
 */
export async function pushAndroidFcm(args: {
  fcmToken: string;
  data: Record<string, string>;
  documentId: string;
  sender?: (msg: Message) => Promise<string>;
}): Promise<SendResult> {
  const data: Record<string, string> = {};
  for (const [key, value] of Object.entries(args.data ?? {})) {
    if (typeof value === "string") data[key] = value;
    else if (value !== undefined && value !== null) data[key] = String(value);
  }
  // Pin a stable correlation id so the Android service can dedupe
  // duplicate fan-outs.
  if (!data["outbound_id"]) data["outbound_id"] = args.documentId;

  const message: Message = {
    token: args.fcmToken,
    data,
    android: {
      priority: "high",
      // Encourage immediate delivery even when Doze is active. Android
      // honours `priority: high` for data-only messages but still
      // dedupes via `collapse_key`; supplying the outbound id keeps
      // collapsing per-call.
      collapseKey: `mercury-${args.documentId}`,
      ttl: 30_000,
      data,
    },
    apns: undefined,
    fcmOptions: undefined,
  };

  const send = args.sender ?? ((msg) => getMessaging().send(msg));
  try {
    const messageId = await pushWithResilience("fcm.mercury", () => send(message));
    return { status: "sent", messageId };
  } catch (err) {
    const code = errorCode(err);
    const reason = errorMessage(err);
    if (
      code === "messaging/registration-token-not-registered" ||
      code === "messaging/invalid-registration-token" ||
      code === "messaging/invalid-argument" ||
      code === "messaging/mismatched-credential"
    ) {
      return { status: "rejected", errorCode: typeof code === "string" ? code : undefined, reason };
    }
    return { status: "retry", errorCode: typeof code === "string" ? code : undefined, reason };
  }
}

/**
 * Firestore trigger — fires for each new `fcm_outbound` document. Mirrors
 * `sendVoIPOutbound` but routes Android-bound pushes through FCM.
 */
export const sendFcmOutbound = onDocumentCreated(
  {
    document: "fcm_outbound/{docId}",
    region: "us-central1",
  },
  async (event) => {
    if (!event.data) return;
    await processFcmOutboundRef(event.data.ref, event.params.docId);
  },
);

export async function processFcmOutboundRef(
  ref: FirebaseFirestore.DocumentReference,
  documentId = ref.id,
): Promise<"sent" | "rejected" | "retry" | "skipped"> {
  const claim = await claimPendingPush(ref);
  if (!claim) return "skipped";
  const data = claim.data;
  if (!isRecord(data)) return "skipped";

  const fcmToken = stringValue(data.fcmToken);
  if (!fcmToken) {
    await finishClaimedPush(ref, claim.leaseId, {
      status: "rejected",
      reason: "missing fcmToken",
      rejectedAt: Timestamp.now(),
    });
    return "rejected";
  }

  const payload = isRecord(data.payload)
    ? Object.fromEntries(
        Object.entries(data.payload).flatMap(([key, value]) => (typeof value === "string" ? [[key, value]] : [])),
      )
    : {};

  const result = await pushAndroidFcm({
    fcmToken,
    data: payload,
    documentId,
  });

  switch (result.status) {
    case "sent":
      await finishClaimedPush(ref, claim.leaseId, {
        status: "sent",
        deliveredAt: Timestamp.now(),
        fcmMessageId: result.messageId ?? null,
        retryAt: null,
        lastFailureReason: null,
      });
      return "sent";
    case "rejected":
      await finishClaimedPush(ref, claim.leaseId, {
        status: "rejected",
        rejectedAt: Timestamp.now(),
        errorCode: result.errorCode ?? null,
        reason: result.reason ?? null,
        retryAt: null,
      });
      return "rejected";
    case "retry":
      await finishClaimedPush(ref, claim.leaseId, {
        status: "pending",
        lastFailureReason: result.reason ?? null,
        retryAt: nextPushRetryAt(Date.now(), claim.attemptCount),
      });
      return "retry";
  }
}

export async function retryPendingFcmPushes(firestore: Firestore = getFirestore(), limit = 50): Promise<number> {
  const refs = await collectRetryablePushRefs(firestore, "fcm_outbound", { limit });
  let processed = 0;
  for (const ref of refs) {
    const result = await processFcmOutboundRef(ref, ref.id);
    if (result !== "skipped") processed += 1;
  }
  return processed;
}

export const retryPendingFcmOutbound = onSchedule(
  {
    schedule: "every 1 minutes",
    region: "us-central1",
  },
  async () => {
    await retryPendingFcmPushes();
  },
);
