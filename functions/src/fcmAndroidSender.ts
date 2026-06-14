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

import { Timestamp, getFirestore } from "firebase-admin/firestore";
import type { QueryDocumentSnapshot } from "firebase-admin/firestore";
import { getMessaging, type Message } from "firebase-admin/messaging";
import * as logger from "firebase-functions/logger";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { pushWithResilience } from "./resilienceHelpers.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

interface SendResult {
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

// ---------------------------------------------------------------------------
// Stuck-FCM retry sweeper
//
// The Firestore create trigger only runs once. A transient FCM outage used to
// leave `fcm_outbound` documents pending forever after the first retryAt write.
// This mirrors the APNs stuck-push sweeper so both mobile push planes have the
// same durable recovery semantics.
// ---------------------------------------------------------------------------

/** Backoff base for transient retries (matches `sendFcmOutbound`'s first retry). */
const FCM_RETRY_BACKOFF_BASE_MS = 30_000;
/** Hard ceiling on a single backoff interval so token outages do not disappear for days. */
const FCM_RETRY_BACKOFF_MAX_MS = 15 * 60_000;
/** After this many attempts a still-failing push is sealed rejected for operator visibility. */
export const MAX_FCM_RETRY_ATTEMPTS = 8;
/** Max documents handled per scheduled tick. */
const FCM_SWEEP_BATCH_LIMIT = 50;

type FcmPushFn = (args: {
  fcmToken: string;
  data: Record<string, string>;
  documentId: string;
}) => Promise<SendResult>;

/** Outcome of processing a single stuck FCM document. */
type StuckFcmOutcome = "sent" | "rejected" | "rescheduled" | "skipped";

export function nextFcmRetryDelayMs(attempt: number): number {
  const exponent = Math.max(0, attempt - 1);
  const raw = FCM_RETRY_BACKOFF_BASE_MS * 2 ** exponent;
  return Math.min(FCM_RETRY_BACKOFF_MAX_MS, raw);
}

function stringPayloadFromRecord(payload: unknown): Record<string, string> {
  if (!isRecord(payload)) return {};
  return Object.fromEntries(
    Object.entries(payload).flatMap(([key, value]) => (typeof value === "string" ? [[key, value]] : [])),
  );
}

/**
 * Re-push a due `fcm_outbound` document and persist its next state.
 *
 * Success and permanent rejection use the same fields as the create trigger.
 * Transient failures are rescheduled with bounded exponential backoff until the
 * retry budget is exhausted, at which point the document becomes `rejected`
 * instead of remaining invisible as pending work.
 */
export async function processStuckFcmPush(
  snapshot: QueryDocumentSnapshot,
  push: FcmPushFn,
  now: Date = new Date(),
): Promise<StuckFcmOutcome> {
  const data = snapshot.data();
  if (!isRecord(data)) return "skipped";
  if (data.status !== "pending") return "skipped";

  const fcmToken = stringValue(data.fcmToken);
  const priorAttempts = typeof data.attemptCount === "number" ? data.attemptCount : 0;

  if (!fcmToken) {
    await snapshot.ref.update({
      status: "rejected",
      rejectedAt: Timestamp.fromDate(now),
      reason: "missing fcmToken",
    });
    return "rejected";
  }

  const result = await push({
    fcmToken,
    data: stringPayloadFromRecord(data.payload),
    documentId: snapshot.id,
  });

  switch (result.status) {
    case "sent":
      await snapshot.ref.update({
        status: "sent",
        deliveredAt: Timestamp.fromDate(now),
        fcmMessageId: result.messageId ?? null,
      });
      return "sent";
    case "rejected":
      await snapshot.ref.update({
        status: "rejected",
        rejectedAt: Timestamp.fromDate(now),
        errorCode: result.errorCode ?? null,
        reason: result.reason ?? null,
      });
      return "rejected";
    case "retry": {
      const attemptCount = priorAttempts + 1;
      if (attemptCount >= MAX_FCM_RETRY_ATTEMPTS) {
        await snapshot.ref.update({
          status: "rejected",
          rejectedAt: Timestamp.fromDate(now),
          attemptCount,
          errorCode: result.errorCode ?? null,
          reason: result.reason ?? `exhausted ${MAX_FCM_RETRY_ATTEMPTS} retry attempts`,
        });
        return "rejected";
      }
      await snapshot.ref.update({
        status: "pending",
        attemptCount,
        lastAttemptAt: Timestamp.fromDate(now),
        lastFailureReason: result.reason ?? null,
        retryAt: Timestamp.fromMillis(now.getTime() + nextFcmRetryDelayMs(attemptCount)),
      });
      return "rescheduled";
    }
  }
}

export async function sweepStuckFcmPushes(
  db: ReturnType<typeof getFirestore>,
  push: FcmPushFn,
  now: Date = new Date(),
): Promise<Record<StuckFcmOutcome, number>> {
  const snapshot = await db
    .collectionGroup("fcm_outbound")
    .where("status", "==", "pending")
    .where("retryAt", "<=", Timestamp.fromDate(now))
    .orderBy("retryAt", "asc")
    .limit(FCM_SWEEP_BATCH_LIMIT)
    .get();

  const tally: Record<StuckFcmOutcome, number> = { sent: 0, rejected: 0, rescheduled: 0, skipped: 0 };
  for (const doc of snapshot.docs) {
    try {
      const outcome = await processStuckFcmPush(doc, push, now);
      tally[outcome] += 1;
    } catch (err) {
      tally.skipped += 1;
      logger.error("retryStuckFcmPushes: failed to process document", {
        documentPath: doc.ref.path,
        error: errorMessage(err),
      });
    }
  }
  return tally;
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

    const result = await pushAndroidFcm({
      fcmToken,
      data: stringPayloadFromRecord(data.payload),
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
          retryAt: Timestamp.fromMillis(Date.now() + nextFcmRetryDelayMs(1)),
          attemptCount: (typeof data.attemptCount === "number" ? data.attemptCount : 0) + 1,
        });
        return;
    }
  },
);

export const retryStuckFcmPushes = onSchedule(
  {
    schedule: "every 1 minutes",
    region: FUNCTIONS_REGION,
  },
  async () => {
    const tally = await sweepStuckFcmPushes(getFirestore(), (args) => pushAndroidFcm(args));
    if (tally.sent || tally.rejected || tally.rescheduled || tally.skipped) {
      logger.info("retryStuckFcmPushes swept stuck FCM pushes", tally);
    }
  },
);
