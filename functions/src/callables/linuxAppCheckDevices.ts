/**
 * @fileoverview Trusted-device-approved enrollment lifecycle for Linux App
 * Check device keys. These records are deliberately separate from CloudVault
 * escrow trust: approval grants only lower-trust Linux App Check minting and
 * iroh host publication.
 */

import { randomBytes } from "node:crypto";

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import {
  appCheckTrustClassForAppId,
  enforceHighRiskComputerUseCallableWithNonce,
  readAppIdFromCallableRequest,
} from "../appCheckAttestation.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { getConfig } from "../config.js";
import { stripUndefinedObject } from "../guards.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { PHONE_CONTROL_ESCROW_PLATFORMS } from "./computerUseSecurityCodecs.js";
import { requireTrustedDeviceActionProof, requireTrustedEscrowDevice } from "./computerUseSecurityFirestore.js";
import {
  LINUX_APP_CHECK_CHALLENGE_TTL_MS,
  deriveLinuxAppCheckDeviceId,
  linuxAppCheckChallengePayload,
  linuxAppCheckSafetyFingerprint,
  parseLinuxAppCheckEnrollmentProof,
  parseLinuxAppCheckPublicKey,
  verifyLinuxAppCheckEd25519Signature,
} from "./linuxAppCheckDeviceCrypto.js";
import { checkPublicHttpEndpointRateLimit } from "./publicRateLimit.js";
import { boundedTrimmedString } from "./shared.js";

export const LINUX_APP_CHECK_DEVICE_COLLECTION = "linux_app_check_devices" as const;
export const LINUX_APP_CHECK_CHALLENGE_COLLECTION = "linux_app_check_challenges" as const;
const LINUX_APP_CHECK_SCHEMA_VERSION = 1;
const MAX_LISTED_LINUX_DEVICES = 100;
const APPROVE_ACTION_KIND = "linux_app_check_device_approve";
const REVOKE_ACTION_KIND = "linux_app_check_device_revoke";

type LinuxDeviceTrustState = "pending" | "approved" | "revoked";

function deviceRef(uid: string, deviceId: string) {
  return db.doc(`users/${uid}/${LINUX_APP_CHECK_DEVICE_COLLECTION}/${deviceId}`);
}

function challengeRef(uid: string, challengeId: string) {
  return db.doc(`users/${uid}/${LINUX_APP_CHECK_CHALLENGE_COLLECTION}/${challengeId}`);
}

function requireExactLinuxAppId(raw: unknown): string {
  const appId = boundedTrimmedString(raw, "appId", 160, true);
  if (appId !== getConfig().linuxAppCheckAppID) {
    throw new HttpsError("permission-denied", "Linux App Check request used an unexpected app id.");
  }
  return appId;
}

function requireNativeAppCheckCaller(request: CallableRequest): void {
  const trustClass = appCheckTrustClassForAppId(readAppIdFromCallableRequest(request));
  if (trustClass !== "apple_attested" && trustClass !== "android_play_integrity") {
    throw new HttpsError("permission-denied", "A native attested device must manage Linux App Check devices.");
  }
}

async function enforceTrustedNativeManager(args: {
  request: CallableRequest;
  uid: string;
  approverDeviceId: string;
}): Promise<void> {
  enforceAuthAndAppCheck(args.request, args.uid);
  requireNativeAppCheckCaller(args.request);
  await requireTrustedEscrowDevice(args.uid, args.approverDeviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
}

export async function requireApprovedLinuxAppCheckIrohHost(
  request: CallableRequest,
  uid: string,
  deviceId: string,
): Promise<{ deviceId: string; platform: "Linux" }> {
  const liveAppId = readAppIdFromCallableRequest(request);
  const expectedAppId = getConfig().linuxAppCheckAppID;
  if (liveAppId !== expectedAppId) {
    throw new HttpsError("permission-denied", "Linux host approval requires the configured Linux App Check app.");
  }
  const snapshot = await deviceRef(uid, deviceId).get();
  if (
    !snapshot.exists ||
    snapshot.get("trustState") !== "approved" ||
    snapshot.get("appId") !== expectedAppId ||
    snapshot.get("deviceId") !== deviceId
  ) {
    throw new HttpsError("permission-denied", "This Linux host is not approved for App Check and iroh publication.");
  }
  return { deviceId, platform: "Linux" };
}

export async function consumeLinuxAppCheckChallenge(args: {
  appId: string;
  challengeId: string;
  deviceId: string;
  signatureBase64: unknown;
  uid: string;
  nowMillis?: number;
}): Promise<void> {
  const nowMillis = args.nowMillis ?? Date.now();
  if (args.appId !== getConfig().linuxAppCheckAppID) {
    throw new HttpsError("permission-denied", "Linux App Check challenge used an unexpected app id.");
  }
  const device = deviceRef(args.uid, args.deviceId);
  const challenge = challengeRef(args.uid, args.challengeId);
  await db.runTransaction(async (transaction) => {
    const deviceSnapshot = await transaction.get(device);
    const challengeSnapshot = await transaction.get(challenge);
    if (
      !deviceSnapshot.exists ||
      deviceSnapshot.get("trustState") !== "approved" ||
      deviceSnapshot.get("appId") !== args.appId ||
      deviceSnapshot.get("deviceId") !== args.deviceId
    ) {
      throw new HttpsError("permission-denied", "Linux App Check device is not approved.");
    }
    if (!challengeSnapshot.exists) {
      throw new HttpsError("not-found", "Linux App Check challenge was not found.");
    }
    if (challengeSnapshot.get("status") !== "pending") {
      throw new HttpsError("unauthenticated", "Linux App Check challenge was already consumed.");
    }
    const issuedAtMillis = challengeSnapshot.get("issuedAtMillis");
    const expiresAtMillis = challengeSnapshot.get("expiresAtMillis");
    const challengeNonce = challengeSnapshot.get("challengeNonce");
    if (
      challengeSnapshot.get("challengeId") !== args.challengeId ||
      challengeSnapshot.get("deviceId") !== args.deviceId ||
      challengeSnapshot.get("appId") !== args.appId ||
      typeof issuedAtMillis !== "number" ||
      typeof expiresAtMillis !== "number" ||
      typeof challengeNonce !== "string"
    ) {
      throw new HttpsError("failed-precondition", "Linux App Check challenge binding is invalid.");
    }
    if (nowMillis > expiresAtMillis || nowMillis < issuedAtMillis - 60_000) {
      throw new HttpsError("unauthenticated", "Linux App Check challenge expired.");
    }
    const canonicalPayload = linuxAppCheckChallengePayload({
      appId: args.appId,
      challengeId: args.challengeId,
      challengeNonce,
      deviceId: args.deviceId,
      expiresAtMillis,
      issuedAtMillis,
      uid: args.uid,
    });
    if (challengeSnapshot.get("canonicalPayloadBase64") !== canonicalPayload.toString("base64")) {
      throw new HttpsError("failed-precondition", "Linux App Check challenge payload is invalid.");
    }
    const publicKey = parseLinuxAppCheckPublicKey(deviceSnapshot.get("publicKeyBase64")).bytes;
    if (deriveLinuxAppCheckDeviceId(publicKey) !== args.deviceId) {
      throw new HttpsError("failed-precondition", "Linux App Check device identity is corrupt.");
    }
    if (
      !verifyLinuxAppCheckEd25519Signature({
        payload: canonicalPayload,
        publicKey,
        signatureBase64: args.signatureBase64,
      })
    ) {
      throw new HttpsError("unauthenticated", "Linux App Check challenge signature did not verify.");
    }
    transaction.update(challenge, {
      status: "consumed",
      consumedAtMillis: nowMillis,
      consumedAt: FieldValue.serverTimestamp(),
    });
  });
}

export const registerLinuxAppCheckDevice = onCallProduction(
  "registerLinuxAppCheckDevice",
  { region: FUNCTIONS_REGION, enforceAppCheck: false, maxInstances: 20 },
  async (
    request: CallableRequest<{
      appId?: unknown;
      deviceId?: unknown;
      deviceName?: unknown;
      issuedAtMillis?: unknown;
      publicKeyBase64?: unknown;
      signatureBase64?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before enrolling a Linux App Check device.");
    await checkPublicHttpEndpointRateLimit("registerLinuxAppCheckDevice", uid);
    const nowMillis = Date.now();
    const proof = parseLinuxAppCheckEnrollmentProof(request.data, getConfig().linuxAppCheckAppID, uid, nowMillis);
    const deviceName =
      boundedTrimmedString(request.data.deviceName, "deviceName", 256, false) ?? "OpenBurnBar on Linux";
    const ref = deviceRef(uid, proof.deviceId);
    const result = await db.runTransaction(async (transaction) => {
      const existing = await transaction.get(ref);
      if (existing.exists) {
        if (
          existing.get("publicKeyBase64") !== proof.publicKeyBase64 ||
          existing.get("appId") !== proof.appId ||
          existing.get("deviceId") !== proof.deviceId
        ) {
          throw new HttpsError("permission-denied", "Linux App Check device identity is already bound to another key.");
        }
        const existingState = existing.get("trustState");
        if (existingState === "revoked") {
          throw new HttpsError("failed-precondition", "Revoked Linux App Check keys cannot be re-enrolled.");
        }
        if (existingState !== "pending" && existingState !== "approved") {
          throw new HttpsError("failed-precondition", "Linux App Check device has an invalid trust state.");
        }
        transaction.set(
          ref,
          { deviceName, lastEnrollmentProofAtMillis: proof.issuedAtMillis, updatedAt: FieldValue.serverTimestamp() },
          { merge: true },
        );
        return existingState as LinuxDeviceTrustState;
      }
      transaction.create(ref, {
        appId: proof.appId,
        deviceId: proof.deviceId,
        deviceName,
        platform: "Linux",
        publicKeyBase64: proof.publicKeyBase64,
        safetyFingerprint: linuxAppCheckSafetyFingerprint(proof.publicKey),
        trustState: "pending",
        lastEnrollmentProofAtMillis: proof.issuedAtMillis,
        createdAtMillis: nowMillis,
        updatedAtMillis: nowMillis,
        schemaVersion: LINUX_APP_CHECK_SCHEMA_VERSION,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      return "pending" as const;
    });
    logInfo({
      event: "callable_info",
      message: "linux_app_check_device_registered",
      device_id: proof.deviceId,
      trust_state: result,
    });
    return { ok: true, deviceId: proof.deviceId, trustState: result };
  },
);

export const issueLinuxAppCheckChallenge = onCallProduction(
  "issueLinuxAppCheckChallenge",
  { region: FUNCTIONS_REGION, enforceAppCheck: false, maxInstances: 20 },
  async (request: CallableRequest<{ appId?: unknown; deviceId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before requesting a Linux App Check challenge.");
    await checkPublicHttpEndpointRateLimit("issueLinuxAppCheckChallenge", uid);
    const appId = requireExactLinuxAppId(request.data.appId);
    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    const challengeId = randomBytes(16).toString("hex");
    const challengeNonce = randomBytes(32).toString("base64url");
    const issuedAtMillis = Date.now();
    const expiresAtMillis = issuedAtMillis + LINUX_APP_CHECK_CHALLENGE_TTL_MS;
    const canonicalPayload = linuxAppCheckChallengePayload({
      appId,
      challengeId,
      challengeNonce,
      deviceId,
      expiresAtMillis,
      issuedAtMillis,
      uid,
    });
    await db.runTransaction(async (transaction) => {
      const device = await transaction.get(deviceRef(uid, deviceId));
      if (
        !device.exists ||
        device.get("trustState") !== "approved" ||
        device.get("appId") !== appId ||
        device.get("deviceId") !== deviceId
      ) {
        throw new HttpsError("permission-denied", "Linux App Check device is not approved.");
      }
      transaction.create(challengeRef(uid, challengeId), {
        appId,
        challengeId,
        challengeNonce,
        deviceId,
        canonicalPayloadBase64: canonicalPayload.toString("base64"),
        issuedAtMillis,
        expiresAtMillis,
        status: "pending",
        schemaVersion: LINUX_APP_CHECK_SCHEMA_VERSION,
        expireAt: Timestamp.fromMillis(expiresAtMillis),
        createdAt: FieldValue.serverTimestamp(),
      });
    });
    return {
      ok: true,
      challengeId,
      canonicalPayloadBase64: canonicalPayload.toString("base64"),
      signatureAlgorithm: "ed25519",
      issuedAtMillis,
      expiresAtMillis,
    };
  },
);

export const listLinuxAppCheckDevices = onCallProduction(
  "listLinuxAppCheckDevices",
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 50 },
  async (request: CallableRequest<{ approverDeviceId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before listing Linux App Check devices.");
    const approverDeviceId = boundedTrimmedString(request.data.approverDeviceId, "approverDeviceId", 160, true);
    await enforceTrustedNativeManager({ request, uid, approverDeviceId });
    const snapshots = await db
      .collection(`users/${uid}/${LINUX_APP_CHECK_DEVICE_COLLECTION}`)
      .limit(MAX_LISTED_LINUX_DEVICES)
      .get();
    const devices = snapshots.docs.map((snapshot) =>
      stripUndefinedObject({
        deviceId: snapshot.get("deviceId"),
        deviceName: snapshot.get("deviceName"),
        platform: "Linux",
        publicKeyBase64: snapshot.get("publicKeyBase64"),
        safetyFingerprint: snapshot.get("safetyFingerprint"),
        trustState: snapshot.get("trustState"),
        createdAtMillis: snapshot.get("createdAtMillis"),
        approvedAtMillis: snapshot.get("approvedAtMillis") ?? undefined,
        revokedAtMillis: snapshot.get("revokedAtMillis") ?? undefined,
        approvedByDeviceId: snapshot.get("approvedByDeviceId") ?? undefined,
        revokedByDeviceId: snapshot.get("revokedByDeviceId") ?? undefined,
      }),
    );
    return { ok: true, devices };
  },
);

async function mutateLinuxDeviceTrust(args: {
  approve: boolean;
  deviceId: string;
  managerDeviceId: string;
  uid: string;
}): Promise<{ alreadyInState: boolean; trustState: LinuxDeviceTrustState }> {
  const ref = deviceRef(args.uid, args.deviceId);
  return db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists) throw new HttpsError("not-found", "Linux App Check device is not registered.");
    const state = snapshot.get("trustState");
    const expectedDeviceId = deriveLinuxAppCheckDeviceId(
      parseLinuxAppCheckPublicKey(snapshot.get("publicKeyBase64")).bytes,
    );
    if (snapshot.get("deviceId") !== args.deviceId || expectedDeviceId !== args.deviceId) {
      throw new HttpsError("failed-precondition", "Linux App Check device identity is corrupt.");
    }
    const nowMillis = Date.now();
    if (args.approve) {
      if (state === "approved") return { alreadyInState: true, trustState: "approved" as const };
      if (state === "revoked") {
        throw new HttpsError("failed-precondition", "Revoked Linux App Check keys cannot be re-approved.");
      }
      if (state !== "pending") throw new HttpsError("failed-precondition", "Linux App Check device is not pending.");
      transaction.update(ref, {
        trustState: "approved",
        approvedAtMillis: nowMillis,
        approvedByDeviceId: args.managerDeviceId,
        updatedAtMillis: nowMillis,
        updatedAt: FieldValue.serverTimestamp(),
      });
      return { alreadyInState: false, trustState: "approved" as const };
    }
    if (state === "revoked") return { alreadyInState: true, trustState: "revoked" as const };
    if (state !== "pending" && state !== "approved") {
      throw new HttpsError("failed-precondition", "Linux App Check device has an invalid trust state.");
    }
    transaction.update(ref, {
      trustState: "revoked",
      revokedAtMillis: nowMillis,
      revokedByDeviceId: args.managerDeviceId,
      updatedAtMillis: nowMillis,
      updatedAt: FieldValue.serverTimestamp(),
    });
    return { alreadyInState: false, trustState: "revoked" as const };
  });
}

function linuxDeviceTrustMutationCallable(approve: boolean) {
  const callableName = approve ? "approveLinuxAppCheckDevice" : "revokeLinuxAppCheckDevice";
  return onCallProduction(
    callableName,
    { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 50 },
    async (
      request: CallableRequest<{
        actionProof?: unknown;
        approverDeviceId?: unknown;
        deviceId?: unknown;
        nonce?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid)
        throw new HttpsError(
          "unauthenticated",
          `Sign in before ${approve ? "approving" : "revoking"} a Linux App Check device.`,
        );
      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
      const approverDeviceId = boundedTrimmedString(request.data.approverDeviceId, "approverDeviceId", 160, true);
      const nonce = boundedTrimmedString(request.data.nonce, "nonce", 256, true);
      await enforceHighRiskComputerUseCallableWithNonce(request, uid, nonce);
      requireNativeAppCheckCaller(request);
      await requireTrustedEscrowDevice(uid, approverDeviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
      await requireTrustedDeviceActionProof({
        uid,
        deviceId: approverDeviceId,
        actionKind: approve ? APPROVE_ACTION_KIND : REVOKE_ACTION_KIND,
        subjectId: deviceId,
        approve,
        nonce,
        proofRaw: request.data.actionProof,
        allowedPlatforms: PHONE_CONTROL_ESCROW_PLATFORMS,
      });
      const result = await mutateLinuxDeviceTrust({ approve, deviceId, managerDeviceId: approverDeviceId, uid });
      logInfo({
        event: "callable_info",
        message: approve ? "linux_app_check_device_approved" : "linux_app_check_device_revoked",
        device_id: deviceId,
        manager_device_id: approverDeviceId,
        already_in_state: result.alreadyInState,
      });
      return { ok: true, deviceId, trustState: result.trustState, alreadyInState: result.alreadyInState };
    },
  );
}

export const approveLinuxAppCheckDevice = linuxDeviceTrustMutationCallable(true);
export const revokeLinuxAppCheckDevice = linuxDeviceTrustMutationCallable(false);

export const __testing__ = {
  APPROVE_ACTION_KIND,
  REVOKE_ACTION_KIND,
  mutateLinuxDeviceTrust,
  requireNativeAppCheckCaller,
};
