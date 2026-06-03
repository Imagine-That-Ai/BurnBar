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

import { Timestamp } from "firebase-admin/firestore";
import { getMessaging, type Message } from "firebase-admin/messaging";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { pushWithResilience } from "./resilienceHelpers.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

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
    region: FUNCTIONS_REGION,
  },
  async (event) => {
    const data = event.data?.data();
    if (!isRecord(data)) return;
    if (data.status && data.status !== "pending") return;
    const fcmToken = stringValue(data.fcmToken);
    if (!fcmToken) {
      await event.data?.ref.update({
        status: "rejected",
        reason: "missing fcmToken",
        rejectedAt: Timestamp.now(),
      });
      return;
    }

    const payload = isRecord(data.payload)
      ? Object.fromEntries(
          Object.entries(data.payload).flatMap(([key, value]) => (typeof value === "string" ? [[key, value]] : [])),
        )
      : {};

    const result = await pushAndroidFcm({
      fcmToken,
      data: payload,
      documentId: event.params.docId,
    });

    switch (result.status) {
      case "sent":
        await event.data?.ref.update({
          status: "sent",
          deliveredAt: Timestamp.now(),
          fcmMessageId: result.messageId ?? null,
        });
        return;
      case "rejected":
        await event.data?.ref.update({
          status: "rejected",
          rejectedAt: Timestamp.now(),
          errorCode: result.errorCode ?? null,
          reason: result.reason ?? null,
        });
        return;
      case "retry":
        await event.data?.ref.update({
          status: "pending",
          lastAttemptAt: Timestamp.now(),
          lastFailureReason: result.reason ?? null,
          retryAt: Timestamp.fromMillis(Date.now() + 30_000),
          attemptCount: (typeof data.attemptCount === "number" ? data.attemptCount : 0) + 1,
        });
        return;
    }
  },
);
