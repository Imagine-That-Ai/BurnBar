/**
 * @fileoverview Linux App Check device-host approval guard shared by the
 * identity callables and phone-control relay senders. Extracted from
 * callables/linuxAppCheckDevices (3.5 deploy-codebase split).
 */

import { HttpsError } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { readAppIdFromCallableRequest } from "../appCheckAttestation.js";
import { getConfig } from "../config.js";

export const LINUX_APP_CHECK_REJECTION_REASON = {
  appNotAllowlisted: "linux_app_not_allowlisted",
  approvalRequired: "linux_device_approval_required",
  invalidTrustState: "linux_device_invalid_trust_state",
  keyMismatch: "linux_device_key_mismatch",
  notRegistered: "linux_device_not_registered",
  recordMismatch: "linux_device_record_mismatch",
  revoked: "linux_device_revoked",
} as const;
export const LINUX_APP_CHECK_DEVICE_COLLECTION = "linux_app_check_devices" as const;

export function deviceRef(uid: string, deviceId: string) {
  return db.doc(`users/${uid}/${LINUX_APP_CHECK_DEVICE_COLLECTION}/${deviceId}`);
}

export async function requireApprovedLinuxAppCheckIrohHost(
  request: { app?: { appId?: string } },
  uid: string,
  deviceId: string,
): Promise<{ deviceId: string; platform: "Linux" }> {
  const liveAppId = readAppIdFromCallableRequest(request);
  const expectedAppId = getConfig().linuxAppCheckAppID;
  if (liveAppId !== expectedAppId) {
    throw new HttpsError("permission-denied", "Linux host approval requires the configured Linux App Check app.", {
      reason: LINUX_APP_CHECK_REJECTION_REASON.appNotAllowlisted,
    });
  }
  const snapshot = await deviceRef(uid, deviceId).get();
  if (
    !snapshot.exists ||
    snapshot.get("trustState") !== "approved" ||
    snapshot.get("appId") !== expectedAppId ||
    snapshot.get("deviceId") !== deviceId
  ) {
    throw new HttpsError("permission-denied", "This Linux host is not approved for App Check and iroh publication.", {
      reason: !snapshot.exists
        ? LINUX_APP_CHECK_REJECTION_REASON.notRegistered
        : LINUX_APP_CHECK_REJECTION_REASON.recordMismatch,
    });
  }
  return { deviceId, platform: "Linux" };
}

