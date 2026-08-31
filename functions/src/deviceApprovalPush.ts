/**
 * @fileoverview Cross-platform push notifications for pending device approvals.
 *
 * When a new browser (or companion device) registers for escrow trust, this module
 * fans out high-priority push notifications to the user's existing trusted companion
 * devices (iOS, macOS, Android) so they can approve with one tap or review safely.
 */

import { getFirestore } from "firebase-admin/firestore";
import { getMessaging, type Message } from "firebase-admin/messaging";
import { logError, logInfo } from "./logging.js";
import { errorCode } from "./guards.js";
import { pushWithResilience } from "./resilienceHelpers.js";

const DEVICE_COLLECTION = "devices";

interface FanoutDeviceApprovalArgs {
  uid: string;
  deviceId: string;
  deviceName: string;
  platform: string;
  safetyCode?: string;
  firestore?: FirebaseFirestore.Firestore;
  messaging?: Pick<ReturnType<typeof getMessaging>, "send">;
}

interface FanoutDeviceApprovalResult {
  sent: number;
  skipped: number;
  failed: number;
}

export async function fanoutDeviceApprovalRequest(
  args: FanoutDeviceApprovalArgs,
): Promise<FanoutDeviceApprovalResult> {
  const firestore = args.firestore ?? getFirestore();
  const messaging = args.messaging ?? getMessaging();
  const title = "New Device Approval Request";
  const body = `${args.deviceName} (${args.platform}) is requesting access to your end-to-end vault.`;
  const deepLink = `openburnbar://approve-device?deviceId=${encodeURIComponent(args.deviceId)}`;

  const devicesSnap = await firestore
    .collection("users")
    .doc(args.uid)
    .collection(DEVICE_COLLECTION)
    .get();

  let sent = 0;
  let skipped = 0;
  let failed = 0;
  const nowMillis = Date.now();

  for (const doc of devicesSnap.docs) {
    // Don't send approval notification to the device that is requesting approval
    if (doc.id === args.deviceId) {
      skipped += 1;
      continue;
    }

    const data = doc.data() ?? {};
    const fcmToken = (typeof data.fcmToken === "string" && data.fcmToken) ||
      (typeof data.fcm_token === "string" && data.fcm_token) || undefined;
    const platform = typeof data.platform === "string" ? data.platform.toLowerCase() : "unknown";

    if (!fcmToken) {
      skipped += 1;
      continue;
    }

    const msgData: Record<string, string> = {
      type: "device_approval_request",
      device_id: args.deviceId,
      device_name: args.deviceName,
      platform: args.platform,
      safety_code: args.safetyCode ?? "",
      deep_link: deepLink,
      created_at_millis: String(nowMillis),
    };

    const message: Message = {
      token: fcmToken,
      data: msgData,
      android: {
        priority: "high",
        collapseKey: `device-approval-${args.deviceId}`,
        ttl: 15 * 60 * 1000,
      },
    };

    if (platform !== "android") {
      message.notification = { title, body };
      message.apns = {
        payload: {
          aps: {
            category: "DEVICE_APPROVAL_REQUEST",
            sound: "default",
          },
        },
        headers: {
          "apns-push-type": "alert",
          "apns-priority": "10",
        },
      };
    }

    try {
      await pushWithResilience("fcm.device_approval", () => messaging.send(message));
      sent += 1;
    } catch (err) {
      const code = errorCode(err);
      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token" ||
        code === "messaging/mismatched-credential"
      ) {
        await doc.ref.set(
          {
            pushTokenInvalidatedAtMillis: nowMillis,
            pushTokenInvalidationReason: code,
            updated_at_millis: nowMillis,
          },
          { merge: true },
        ).catch(() => undefined);
      } else {
        failed += 1;
        logError({
          event: "device_approval_push_failed",
          device_id: doc.id,
          target_device_id: args.deviceId,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
  }

  logInfo({
    event: "device_approval_push_fanout_complete",
    requesting_device_id: args.deviceId,
    requesting_platform: args.platform,
    sent,
    skipped,
    failed,
  });

  return { sent, skipped, failed };
}
