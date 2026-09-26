/**
 * @fileoverview Server-owned push endpoint registration for user device docs.
 */

import { FieldValue } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "@openburnbar/functions-shared/adminRuntime.js";
import { enforceAuthAndAppCheck } from "@openburnbar/functions-shared/auth.js";
import { getConfig } from "@openburnbar/functions-shared/config.js";
import { logInfo, wrapCallableHandler } from "@openburnbar/functions-shared/logging.js";
import { FUNCTIONS_REGION } from "@openburnbar/functions-shared/runtimeOptions.js";
import { boundedTrimmedString } from "@openburnbar/functions-shared/shared/validators.js";

const PUSH_TOKEN_MAX_LENGTH = 4096;
const DEVICE_ID_MAX_LENGTH = 160;
const SESSION_ID_MAX_LENGTH = 160;
const PLATFORM_MAX_LENGTH = 80;
const PUSH_TOKEN_HEX_RE = /^[A-Fa-f0-9]{32,512}$/u;
const ALLOWED_PLATFORMS = new Set(["macOS", "macos", "iOS", "ios", "iPadOS", "android", "Android"]);

function optionalPushToken(raw: unknown, fieldName: string): string | undefined {
  return boundedTrimmedString(raw, fieldName, PUSH_TOKEN_MAX_LENGTH, false);
}

function optionalHexPushToken(raw: unknown, fieldName: string): string | undefined {
  const value = optionalPushToken(raw, fieldName);
  if (value && !PUSH_TOKEN_HEX_RE.test(value)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a hex APNs token.`);
  }
  return value;
}

function platformOrUndefined(raw: unknown): string | undefined {
  const platform = boundedTrimmedString(raw, "platform", PLATFORM_MAX_LENGTH, false);
  if (platform && !ALLOWED_PLATFORMS.has(platform)) {
    throw new HttpsError("invalid-argument", "Unsupported device platform.");
  }
  return platform;
}

export const registerDevicePushEndpoint = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler(
    "registerDevicePushEndpoint",
    async (
      request: CallableRequest<{
        deviceId?: unknown;
        platform?: unknown;
        fcmToken?: unknown;
        fcm_token?: unknown;
        apnsToken?: unknown;
        voipDeviceToken?: unknown;
        voip_token?: unknown;
        liveActivityPushToken?: unknown;
        liveActivitySessionId?: unknown;
        agentNotificationsEnabled?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before registering a device push endpoint.");
      enforceAuthAndAppCheck(request, uid);

      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", DEVICE_ID_MAX_LENGTH, true);
      const platform = platformOrUndefined(request.data.platform);
      const fcmToken = optionalPushToken(request.data.fcmToken ?? request.data.fcm_token, "fcmToken");
      const apnsToken = optionalHexPushToken(request.data.apnsToken, "apnsToken");
      const voipDeviceToken = optionalHexPushToken(
        request.data.voipDeviceToken ?? request.data.voip_token,
        "voipDeviceToken",
      );
      const liveActivityPushToken = optionalHexPushToken(
        request.data.liveActivityPushToken,
        "liveActivityPushToken",
      );
      const liveActivitySessionId = boundedTrimmedString(
        request.data.liveActivitySessionId,
        "liveActivitySessionId",
        SESSION_ID_MAX_LENGTH,
        false,
      );
      const agentNotificationsEnabled =
        typeof request.data.agentNotificationsEnabled === "boolean"
          ? request.data.agentNotificationsEnabled
          : undefined;

      if (
        !fcmToken &&
        !apnsToken &&
        !voipDeviceToken &&
        !liveActivityPushToken &&
        liveActivitySessionId === undefined &&
        agentNotificationsEnabled === undefined
      ) {
        throw new HttpsError("invalid-argument", "At least one push endpoint field is required.");
      }

      const escrowDeviceSnap = await db.doc(`users/${uid}/escrow_devices/${deviceId}`).get();
      if (!escrowDeviceSnap.exists) {
        throw new HttpsError("permission-denied", "Push endpoint registration requires a registered escrow device.");
      }
      const escrowTrustState = escrowDeviceSnap.get("trustState");
      if (escrowTrustState !== "trusted") {
        throw new HttpsError(
          "permission-denied",
          `Device trust state is ${escrowTrustState ?? "unknown"}; only trusted devices may register push endpoints.`,
        );
      }
      const escrowPlatform = escrowDeviceSnap.get("platform");
      if (typeof escrowPlatform !== "string") {
        throw new HttpsError("failed-precondition", "Escrow device is missing a platform.");
      }
      const resolvedPlatform = platform ?? escrowPlatform;
      if (resolvedPlatform !== escrowPlatform) {
        throw new HttpsError(
          "invalid-argument",
          `Platform ${resolvedPlatform} does not match escrow device platform ${escrowPlatform}.`,
        );
      }

      const update: Record<string, unknown> = {
        deviceId,
        platform: resolvedPlatform,
        updatedAt: FieldValue.serverTimestamp(),
        updated_at_millis: Date.now(),
      };
      if (fcmToken) {
        update.fcmToken = fcmToken;
        update.fcm_token = fcmToken;
      }
      if (apnsToken) update.apnsToken = apnsToken;
      if (voipDeviceToken) {
        update.voipDeviceToken = voipDeviceToken;
        update.voip_token = voipDeviceToken;
      }
      if (liveActivityPushToken) update.liveActivityPushToken = liveActivityPushToken;
      if (liveActivitySessionId) update.liveActivitySessionId = liveActivitySessionId;
      if (agentNotificationsEnabled !== undefined) update.agentNotificationsEnabled = agentNotificationsEnabled;

      await db.doc(`users/${uid}/devices/${deviceId}`).set(update, { merge: true });
      logInfo({
        event: "device_push_endpoint_registered",
        device_id: deviceId,
        has_fcm: Boolean(fcmToken),
        has_apns: Boolean(apnsToken),
        has_voip: Boolean(voipDeviceToken),
        has_live_activity: Boolean(liveActivityPushToken),
      });
      return {
        ok: true,
        deviceId,
        fcmRegistered: Boolean(fcmToken),
        apnsRegistered: Boolean(apnsToken),
        voipRegistered: Boolean(voipDeviceToken),
        liveActivityRegistered: Boolean(liveActivityPushToken),
      };
    },
  ),
);

export const __testing__ = {
  optionalPushToken,
  optionalHexPushToken,
  platformOrUndefined,
};
