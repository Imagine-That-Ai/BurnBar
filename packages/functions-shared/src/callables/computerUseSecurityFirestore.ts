/**
 * @fileoverview Computer Use / escrow Firestore-bound helpers — trusted-device
 * lookups, trusted-device action-proof verification, and the audit-event writer.
 *
 * Extracted verbatim from `computerUseSecurity.ts` (U6 split). These depend on
 * the admin Firestore handle, unlike the pure codec/crypto modules.
 */

import { randomBytes } from "node:crypto";

import { FieldValue } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import {
  TRUSTED_DEVICE_ACTION_PROOF_CLOCK_SKEW_MS,
  TRUSTED_DEVICE_ACTION_PROOF_MAX_AGE_MS,
  parseTrustedDeviceActionProof,
} from "./computerUseSecurityCodecs.js";
import { verifyTrustedDeviceActionSignature } from "./computerUseSecurityCrypto.js";

export async function requireTrustedEscrowDevice(
  uid: string,
  deviceId: string,
  allowedPlatforms: Set<string>,
): Promise<{ deviceId: string; platform: string }> {
  const device = await db.doc(`users/${uid}/escrow_devices/${deviceId}`).get();
  const platform = device.exists ? device.get("platform") : undefined;
  if (
    !device.exists ||
    device.get("trustState") !== "trusted" ||
    typeof platform !== "string" ||
    !allowedPlatforms.has(platform)
  ) {
    throw new HttpsError("permission-denied", "This mutation requires a trusted device for the requested trust root.");
  }
  return { deviceId, platform };
}

export async function requireTrustedDeviceActionProof(args: {
  uid: string;
  deviceId: string;
  actionKind: string;
  subjectId: string;
  approve: boolean;
  nonce: string;
  proofRaw: unknown;
  allowedPlatforms: ReadonlySet<string>;
  nowMillis?: number;
}): Promise<{ deviceId: string; platform: string; signalIdentityKeyId: string }> {
  const proof = parseTrustedDeviceActionProof(args.proofRaw);
  const nowMillis = args.nowMillis ?? Date.now();
  if (
    proof.issuedAtMillis < nowMillis - TRUSTED_DEVICE_ACTION_PROOF_MAX_AGE_MS ||
    proof.issuedAtMillis > nowMillis + TRUSTED_DEVICE_ACTION_PROOF_CLOCK_SKEW_MS
  ) {
    throw new HttpsError("failed-precondition", "actionProof is expired or from the future.");
  }

  const device = await db.doc(`users/${args.uid}/escrow_devices/${args.deviceId}`).get();
  const platform = device.exists ? device.get("platform") : undefined;
  if (
    !device.exists ||
    device.get("trustState") !== "trusted" ||
    typeof platform !== "string" ||
    !args.allowedPlatforms.has(platform)
  ) {
    throw new HttpsError("permission-denied", "This mutation requires a trusted device for the requested trust root.");
  }
  if (
    device.get("targetSignalIdentityKeyId") !== proof.deviceSignalIdentityKeyId ||
    device.get("targetSignalIdentityPublicKeyFingerprint") !== proof.deviceSignalIdentityPublicKeyFingerprint
  ) {
    throw new HttpsError("permission-denied", "actionProof is not bound to the trusted device identity.");
  }

  const identitySnap = await db
    .doc(`users/${args.uid}/signal_identity_public_keys/${proof.deviceSignalIdentityKeyId}`)
    .get();
  if (
    !identitySnap.exists ||
    identitySnap.get("deviceId") !== args.deviceId ||
    identitySnap.get("identityKeyId") !== proof.deviceSignalIdentityKeyId ||
    identitySnap.get("publicKeyFingerprint") !== proof.deviceSignalIdentityPublicKeyFingerprint
  ) {
    throw new HttpsError("permission-denied", "actionProof identity is not published for the trusted device.");
  }
  const identityKeyVersion = identitySnap.get("keyVersion");
  const deviceKeyVersion = device.get("keyVersion");
  if (
    typeof identityKeyVersion === "number" &&
    typeof deviceKeyVersion === "number" &&
    identityKeyVersion !== deviceKeyVersion
  ) {
    throw new HttpsError("permission-denied", "actionProof identity key version does not match the trusted device.");
  }

  const verified = verifyTrustedDeviceActionSignature({
    publicKeyDataBase64: identitySnap.get("publicKeyData"),
    signatureBase64: proof.signature,
    canonicalFields: {
      uid: args.uid,
      deviceId: args.deviceId,
      actionKind: args.actionKind,
      subjectId: args.subjectId,
      approve: args.approve,
      nonce: args.nonce,
      issuedAtMillis: proof.issuedAtMillis,
      deviceSignalIdentityKeyId: proof.deviceSignalIdentityKeyId,
      deviceSignalIdentityPublicKeyFingerprint: proof.deviceSignalIdentityPublicKeyFingerprint,
    },
  });
  if (!verified) {
    throw new HttpsError("permission-denied", "actionProof signature is invalid.");
  }

  return { deviceId: args.deviceId, platform, signalIdentityKeyId: proof.deviceSignalIdentityKeyId };
}

export async function appendComputerUseAuditEvent(uid: string, event: Record<string, unknown>): Promise<void> {
  await db.collection(`users/${uid}/computer_use_audit_events`).add({
    ...event,
    observedAt: FieldValue.serverTimestamp(),
    schemaVersion: 1,
    eventId: `${Date.now()}_${randomBytes(6).toString("hex")}`,
  });
}
