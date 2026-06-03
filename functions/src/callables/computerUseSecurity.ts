/**
 * @fileoverview Computer Use / escrow high-risk callables (WS4 cloud defense-in-depth).
 *
 * Trust elevation and grant-adjacent mutations route through App-Check-enforced
 * callables with attestation-bound Auth custom claims instead of direct client
 * Firestore writes to `trustState: trusted`.
 */

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import {
  bindAppCheckAttestationForUid,
  enforceHighRiskComputerUseCallable,
  readAppIdFromCallableRequest,
} from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import { boundedTrimmedString } from "./shared.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const ESCROW_PLATFORMS = new Set(["macOS", "iOS", "iPadOS", "Android"]);
const ESCROW_WEB_PLATFORM = "Web";

function isNativeEscrowPlatform(raw: unknown): raw is string {
  return typeof raw === "string" && ESCROW_PLATFORMS.has(raw);
}

function parseEscrowPlatform(raw: unknown): string {
  const platform = boundedTrimmedString(raw, "platform", 80, true);
  if (!platform || !ESCROW_PLATFORMS.has(platform)) {
    throw new HttpsError("invalid-argument", "platform must be macOS, iOS, iPadOS, or Android.");
  }
  return platform;
}

export const bindAppCheckAttestation = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("bindAppCheckAttestation", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before binding App Check attestation.");
    enforceAuthAndAppCheck(request, uid);
    const appId = readAppIdFromCallableRequest(request);
    if (!appId) {
      throw new HttpsError("unauthenticated", "App Check attestation is required.");
    }
    const claim = await bindAppCheckAttestationForUid(uid, appId);
    logInfo({
      event: "callable_info",
      message: "app_check_attestation_bound",
      app_id: appId,
    });
    return {
      ok: true,
      appId: claim.appId,
      boundAtMillis: claim.boundAtMillis,
      maxAgeMillis: 30 * 24 * 60 * 60 * 1000,
    };
  }),
);

export const registerEscrowDevice = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "registerEscrowDevice",
    async (
      request: CallableRequest<{
        deviceId?: unknown;
        deviceName?: unknown;
        platform?: unknown;
        appVersion?: unknown;
        publicKeyFingerprint?: unknown;
        keyVersion?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before registering an escrow device.");
      enforceHighRiskComputerUseCallable(request, uid);

      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
      const deviceName = boundedTrimmedString(request.data.deviceName, "deviceName", 256, true) ?? "OpenBurnBar device";
      const platform = parseEscrowPlatform(request.data.platform);
      const appVersion = boundedTrimmedString(request.data.appVersion, "appVersion", 80, false);
      const publicKeyFingerprint = boundedTrimmedString(
        request.data.publicKeyFingerprint,
        "publicKeyFingerprint",
        256,
        false,
      );
      const keyVersion =
        typeof request.data.keyVersion === "number" && Number.isInteger(request.data.keyVersion)
          ? request.data.keyVersion
          : undefined;

      const ref = db.doc(`users/${uid}/escrow_devices/${deviceId}`);
      const existing = await ref.get();
      if (existing.exists && existing.get("trustState") === "trusted") {
        throw new HttpsError("failed-precondition", "Escrow device is already trusted.");
      }

      const payload: Record<string, unknown> = {
        deviceId,
        deviceName,
        platform,
        trustState: "pending",
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (appVersion) payload.appVersion = appVersion;
      if (publicKeyFingerprint) payload.publicKeyFingerprint = publicKeyFingerprint;
      if (keyVersion != null) payload.keyVersion = keyVersion;
      if (!existing.exists) {
        payload.createdAt = FieldValue.serverTimestamp();
      }

      await ref.set(payload, { merge: true });
      logInfo({
        event: "callable_info",
        message: "escrow_device_registered",
        device_id: deviceId,
        platform,
      });
      return { ok: true, deviceId, trustState: "pending" };
    },
  ),
);

export const approveEscrowDeviceTrust = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "approveEscrowDeviceTrust",
    async (request: CallableRequest<{ deviceId?: unknown; approverDeviceId?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before approving device trust.");
      enforceHighRiskComputerUseCallable(request, uid);

      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
      const approverDeviceId = boundedTrimmedString(request.data.approverDeviceId, "approverDeviceId", 160, false);
      const ref = db.doc(`users/${uid}/escrow_devices/${deviceId}`);
      const result = await db.runTransaction(async (transaction) => {
        const snapshot = await transaction.get(ref);
        if (!snapshot.exists) {
          throw new HttpsError("not-found", "Escrow device is not registered.");
        }
        const platform = snapshot.get("platform");
        const trustState = snapshot.get("trustState");
        if (trustState === "trusted") {
          return { alreadyTrusted: true, approvedByDeviceId: snapshot.get("approvedByDeviceId") as string | undefined };
        }
        if (trustState === "revoked") {
          throw new HttpsError("failed-precondition", "Revoked escrow devices must be re-registered before approval.");
        }
        if (platform !== ESCROW_WEB_PLATFORM && !isNativeEscrowPlatform(platform)) {
          throw new HttpsError("failed-precondition", "Escrow device platform is invalid.");
        }

        const trustedNativeQuery = db
          .collection(`users/${uid}/escrow_devices`)
          .where("trustState", "==", "trusted")
          .where("platform", "in", Array.from(ESCROW_PLATFORMS))
          .limit(2);
        const trustedNativeDevices = await transaction.get(trustedNativeQuery);

        const requireTrustedNativeApprover = async (): Promise<string> => {
          if (!approverDeviceId || approverDeviceId === deviceId) {
            throw new HttpsError(
              "failed-precondition",
              "A distinct trusted native device must approve this escrow device.",
            );
          }
          const approverRef = db.doc(`users/${uid}/escrow_devices/${approverDeviceId}`);
          const approver = await transaction.get(approverRef);
          const approverPlatform = approver.exists ? approver.get("platform") : undefined;
          if (
            !approver.exists ||
            approver.get("trustState") !== "trusted" ||
            !isNativeEscrowPlatform(approverPlatform)
          ) {
            throw new HttpsError("permission-denied", "Escrow approval requires a trusted native approver.");
          }
          return approverDeviceId;
        };

        let approvedByDeviceId: string;
        if (platform === ESCROW_WEB_PLATFORM) {
          approvedByDeviceId = await requireTrustedNativeApprover();
        } else if (trustedNativeDevices.empty) {
          approvedByDeviceId = approverDeviceId || deviceId;
        } else {
          approvedByDeviceId = await requireTrustedNativeApprover();
        }

        transaction.set(
          ref,
          {
            trustState: "trusted",
            approvedAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
            approvedByDeviceId,
          },
          { merge: true },
        );
        return { alreadyTrusted: false, approvedByDeviceId };
      });

      logInfo({
        event: "callable_info",
        message: "escrow_device_trust_approved",
        device_id: deviceId,
        approved_by_device_id: result.approvedByDeviceId,
      });
      return { ok: true, deviceId, trustState: "trusted", alreadyTrusted: result.alreadyTrusted };
    },
  ),
);

export const revokeEscrowDeviceTrust = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("revokeEscrowDeviceTrust", async (request: CallableRequest<{ deviceId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before revoking device trust.");
    enforceHighRiskComputerUseCallable(request, uid);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    const ref = db.doc(`users/${uid}/escrow_devices/${deviceId}`);
    const snapshot = await ref.get();
    if (!snapshot.exists) {
      throw new HttpsError("not-found", "Escrow device is not registered.");
    }

    await ref.set(
      {
        trustState: "revoked",
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    const grants = await db
      .collection(`users/${uid}/escrow_grants`)
      .where("targetDeviceId", "==", deviceId)
      .where("status", "==", "granted")
      .get();
    const now = Timestamp.now();
    const batch = db.batch();
    for (const grant of grants.docs) {
      batch.set(
        grant.ref,
        {
          status: "revoked",
          revokedAt: now,
        },
        { merge: true },
      );
    }
    if (!grants.empty) {
      await batch.commit();
    }

    logInfo({
      event: "callable_info",
      message: "escrow_device_trust_revoked",
      device_id: deviceId,
      revoked_grants: grants.size,
    });
    return { ok: true, deviceId, trustState: "revoked", revokedGrants: grants.size };
  }),
);
