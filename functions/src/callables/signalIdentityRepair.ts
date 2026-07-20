/**
 * Repairs a missing Signal identity document for legacy trusted devices.
 *
 * Current clients publish the identity while the escrow device is pending and
 * trust approval pins that identity. Older trusted device records can predate
 * that invariant. Firestore correctly refuses a client-direct identity write
 * once the device is trusted, so the repair must prove possession of the
 * already-pinned escrow private key instead of weakening the rules.
 */

import { createCipheriv, createECDH, createHash, hkdfSync, randomBytes, timingSafeEqual } from "node:crypto";

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { boundedInteger, requireBase64Like } from "./computerUseSecurityCodecs.js";
import { evaluateEscrowFingerprintBinding } from "./computerUseSecurityCrypto.js";
import { boundedTrimmedString } from "./shared.js";

export const SIGNAL_IDENTITY_REPAIR_CHALLENGE_VERSION = 1;
export const SIGNAL_IDENTITY_REPAIR_CHALLENGE_DOMAIN = "OpenBurnBar-SignalIdentityRepairChallenge-v1";
export const SIGNAL_IDENTITY_REPAIR_ALGORITHM = "escrow-possession-challenge-v1";

const ESCROW_WIRE_ALGORITHM = "ECIES-P256-AESGCM";
const SIGNAL_IDENTITY_ALGORITHM = "signal-hpke-identity-seal-v1";
const ESCROW_HKDF_INFO = "OpenBurnBar-Escrow-v1";
const CHALLENGE_TTL_MILLIS = 5 * 60 * 1000;
const P256_X963_BYTES = 65;
const SIGNAL_DJB_PUBLIC_KEY_BYTES = 33;
const SIGNAL_DJB_TYPE_BYTE = 0x05;
const CHALLENGE_BYTES = 32;
const NATIVE_ESCROW_PLATFORMS = new Set(["macOS", "iOS", "iPadOS", "Android"]);

const CALLABLE_OPTIONS = {
  region: FUNCTIONS_REGION,
  enforceAppCheck: getConfig().enforceAppCheck,
  maxInstances: 50,
} as const;

function requireUid(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in before repairing a Signal identity.");
  return uid;
}

function canonicalBase64(raw: unknown, name: string, byteLength: number): { encoded: string; decoded: Buffer } {
  const encoded = requireBase64Like(raw, name, 4, 256);
  const decoded = Buffer.from(encoded, "base64");
  if (decoded.length !== byteLength || decoded.toString("base64") !== encoded) {
    throw new HttpsError("invalid-argument", `${name} is invalid.`);
  }
  return { encoded, decoded };
}

function canonicalSegments(domain: string, segments: string[]): Buffer {
  let canonical = `${domain}\n`;
  for (const segment of segments) {
    canonical += `${Buffer.byteLength(segment, "utf8")}:${segment}\n`;
  }
  return Buffer.from(canonical, "utf8");
}

export function signalIdentityRepairChallengeAAD(uid: string, deviceId: string, challengeId: string): Buffer {
  return canonicalSegments(SIGNAL_IDENTITY_REPAIR_CHALLENGE_DOMAIN, [
    "uid",
    uid,
    "deviceId",
    deviceId,
    "challengeId",
    challengeId,
  ]);
}

/** Mirrors CloudVaultCrypto.sealEscrowPayload for the one-time challenge. */
export function sealSignalIdentityRepairChallenge(plaintext: Buffer, recipientPublicKey: Buffer, aad: Buffer): Buffer {
  if (recipientPublicKey.length !== P256_X963_BYTES || recipientPublicKey[0] !== 0x04) {
    throw new HttpsError("failed-precondition", "The trusted device escrow public key is invalid.");
  }
  try {
    const ephemeral = createECDH("prime256v1");
    ephemeral.generateKeys();
    const sharedSecret = ephemeral.computeSecret(recipientPublicKey);
    const key = Buffer.from(
      hkdfSync("sha256", sharedSecret, Buffer.alloc(0), Buffer.from(ESCROW_HKDF_INFO, "utf8"), 32),
    );
    const nonce = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", key, nonce);
    cipher.setAAD(aad);
    const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    const tag = cipher.getAuthTag();
    return Buffer.concat([ephemeral.getPublicKey(undefined, "uncompressed"), nonce, ciphertext, tag]);
  } catch {
    throw new HttpsError("failed-precondition", "The trusted device escrow public key is invalid.");
  }
}

function assertTrustedDevice(data: Record<string, unknown> | undefined): {
  platform: string;
  keyVersion: number;
  publicKeyFingerprint: string;
} {
  const platform = data?.platform;
  const keyVersion = data?.keyVersion;
  const publicKeyFingerprint = data?.publicKeyFingerprint;
  if (
    data?.trustState !== "trusted" ||
    typeof platform !== "string" ||
    !NATIVE_ESCROW_PLATFORMS.has(platform) ||
    typeof keyVersion !== "number" ||
    !Number.isInteger(keyVersion) ||
    keyVersion < 1 ||
    keyVersion > 10 ||
    typeof publicKeyFingerprint !== "string" ||
    publicKeyFingerprint.length === 0
  ) {
    throw new HttpsError("permission-denied", "Signal identity repair requires this trusted native device.");
  }
  return { platform, keyVersion, publicKeyFingerprint };
}

function assertEscrowPublicKey(
  data: Record<string, unknown> | undefined,
  deviceId: string,
  keyVersion: number,
  expectedFingerprint: string,
): Buffer {
  const publicKeyData = data?.publicKeyData;
  if (
    data?.deviceId !== deviceId ||
    data?.keyVersion !== keyVersion ||
    data?.algorithm !== ESCROW_WIRE_ALGORITHM ||
    data?.publicKeyFingerprint !== expectedFingerprint ||
    typeof publicKeyData !== "string" ||
    !evaluateEscrowFingerprintBinding(expectedFingerprint, publicKeyData).ok
  ) {
    throw new HttpsError("failed-precondition", "The trusted device escrow public key does not match its record.");
  }
  return canonicalBase64(publicKeyData, "stored escrow public key", P256_X963_BYTES).decoded;
}

export const issueTrustedSignalIdentityRepairChallenge = onCallProduction(
  "issueTrustedSignalIdentityRepairChallenge",
  CALLABLE_OPTIONS,
  async (request: CallableRequest<{ deviceId?: unknown }>) => {
    const uid = requireUid(request);
    enforceAuthAndAppCheck(request, uid);
    const deviceId = boundedTrimmedString(request.data?.deviceId, "deviceId", 160, true);
    const deviceRef = db.doc(`users/${uid}/escrow_devices/${deviceId}`);
    const deviceSnapshot = await deviceRef.get();
    const device = assertTrustedDevice(deviceSnapshot.data());
    const escrowRef = db.doc(`users/${uid}/escrow_public_keys/${deviceId}_${device.keyVersion}`);
    const escrowSnapshot = await escrowRef.get();
    if (!escrowSnapshot.exists) {
      throw new HttpsError("failed-precondition", "The trusted device escrow public key is missing.");
    }
    const publicKey = assertEscrowPublicKey(
      escrowSnapshot.data(),
      deviceId,
      device.keyVersion,
      device.publicKeyFingerprint,
    );

    const challengeId = randomBytes(24).toString("base64url");
    const plaintext = randomBytes(CHALLENGE_BYTES);
    const aad = signalIdentityRepairChallengeAAD(uid, deviceId, challengeId);
    const ciphertext = sealSignalIdentityRepairChallenge(plaintext, publicKey, aad);
    const expiresAtMillis = Date.now() + CHALLENGE_TTL_MILLIS;
    await db.doc(`users/${uid}/signal_identity_repair_challenges/${challengeId}`).create({
      challengeId,
      deviceId,
      keyVersion: device.keyVersion,
      escrowPublicKeyFingerprint: device.publicKeyFingerprint,
      challengeHash: createHash("sha256").update(plaintext).digest("base64"),
      createdAt: FieldValue.serverTimestamp(),
      expiresAt: Timestamp.fromMillis(expiresAtMillis),
      schemaVersion: SIGNAL_IDENTITY_REPAIR_CHALLENGE_VERSION,
    });

    logInfo({ event: "trusted_signal_identity_repair_challenge_issued", uid, device_id: deviceId });
    return {
      ok: true as const,
      challengeId,
      challengeCiphertextBase64: ciphertext.toString("base64"),
      expiresAtMillis,
      schemaVersion: SIGNAL_IDENTITY_REPAIR_CHALLENGE_VERSION,
    };
  },
);

interface ParsedSignalIdentityRepair {
  deviceId: string;
  challengeId: string;
  challengePlaintext: Buffer;
  keyVersion: number;
  identityKeyId: string;
  signalPublicKeyBase64: string;
  publicKeyFingerprint: string;
}

function parseSignalIdentityRepairInput(data: Record<string, unknown>): ParsedSignalIdentityRepair {
  const deviceId = boundedTrimmedString(data.deviceId, "deviceId", 160, true);
  const challengeId = boundedTrimmedString(data.challengeId, "challengeId", 160, true);
  if (!/^[A-Za-z0-9_-]+$/u.test(challengeId)) {
    throw new HttpsError("invalid-argument", "challengeId is invalid.");
  }
  const challengePlaintext = canonicalBase64(
    data.challengePlaintextBase64,
    "challengePlaintextBase64",
    CHALLENGE_BYTES,
  ).decoded;
  const keyVersion = boundedInteger(data.keyVersion, "keyVersion", 1, 10, true) ?? 1;
  const identityKeyId = boundedTrimmedString(data.identityKeyId, "identityKeyId", 200, true);
  if (identityKeyId !== `${deviceId}_${keyVersion}`) {
    throw new HttpsError("invalid-argument", "identityKeyId does not match the device key version.");
  }
  const signalPublicKey = canonicalBase64(data.publicKeyData, "publicKeyData", SIGNAL_DJB_PUBLIC_KEY_BYTES);
  if (signalPublicKey.decoded[0] !== SIGNAL_DJB_TYPE_BYTE) {
    throw new HttpsError("invalid-argument", "publicKeyData is not a Signal identity key.");
  }
  const publicKeyFingerprint = boundedTrimmedString(data.publicKeyFingerprint, "publicKeyFingerprint", 128, true);
  const recomputedFingerprint = createHash("sha256").update(signalPublicKey.decoded).digest("base64");
  if (publicKeyFingerprint !== recomputedFingerprint) {
    throw new HttpsError("invalid-argument", "publicKeyFingerprint does not match publicKeyData.");
  }
  return {
    deviceId,
    challengeId,
    challengePlaintext,
    keyVersion,
    identityKeyId,
    signalPublicKeyBase64: signalPublicKey.encoded,
    publicKeyFingerprint,
  };
}

function assertValidRepairChallenge(
  exists: boolean,
  challenge: Record<string, unknown> | undefined,
  input: ParsedSignalIdentityRepair,
): void {
  if (
    !exists ||
    challenge?.deviceId !== input.deviceId ||
    challenge?.keyVersion !== input.keyVersion ||
    challenge?.schemaVersion !== SIGNAL_IDENTITY_REPAIR_CHALLENGE_VERSION ||
    challenge?.consumedAt != null
  ) {
    throw new HttpsError("failed-precondition", "Signal identity repair challenge is invalid or already used.");
  }
  const expiresAt = challenge.expiresAt;
  if (!(expiresAt instanceof Timestamp) || expiresAt.toMillis() <= Date.now()) {
    throw new HttpsError("failed-precondition", "Signal identity repair challenge expired.");
  }
  const expectedHash = Buffer.from(String(challenge.challengeHash ?? ""), "base64");
  const observedHash = createHash("sha256").update(input.challengePlaintext).digest();
  if (expectedHash.length !== observedHash.length || !timingSafeEqual(expectedHash, observedHash)) {
    throw new HttpsError("permission-denied", "Signal identity repair challenge proof is invalid.");
  }
}

function assertDeviceUnchangedForRepair(
  device: ReturnType<typeof assertTrustedDevice>,
  challenge: Record<string, unknown> | undefined,
  input: ParsedSignalIdentityRepair,
  escrowExists: boolean,
): void {
  if (
    device.keyVersion !== input.keyVersion ||
    challenge?.escrowPublicKeyFingerprint !== device.publicKeyFingerprint ||
    !escrowExists
  ) {
    throw new HttpsError("failed-precondition", "The trusted device changed after the challenge was issued.");
  }
}

function assertIdentityPinAllowsRepair(
  pinnedIdentityKeyId: unknown,
  pinnedFingerprint: unknown,
  input: ParsedSignalIdentityRepair,
): void {
  if (
    (typeof pinnedIdentityKeyId === "string" && pinnedIdentityKeyId !== input.identityKeyId) ||
    (typeof pinnedFingerprint === "string" && pinnedFingerprint !== input.publicKeyFingerprint)
  ) {
    throw new HttpsError("permission-denied", "The trusted device is already pinned to a different identity.");
  }
}

function identityDocumentMatches(
  existing: Record<string, unknown> | undefined,
  platform: string,
  input: ParsedSignalIdentityRepair,
): boolean {
  return (
    existing?.deviceId === input.deviceId &&
    existing?.platform === platform &&
    existing?.identityKeyId === input.identityKeyId &&
    existing?.publicKeyData === input.signalPublicKeyBase64 &&
    existing?.publicKeyFingerprint === input.publicKeyFingerprint &&
    existing?.keyVersion === input.keyVersion &&
    existing?.algorithm === SIGNAL_IDENTITY_ALGORITHM
  );
}

export const repairTrustedSignalIdentity = onCallProduction(
  "repairTrustedSignalIdentity",
  CALLABLE_OPTIONS,
  async (
    request: CallableRequest<{
      deviceId?: unknown;
      challengeId?: unknown;
      challengePlaintextBase64?: unknown;
      identityKeyId?: unknown;
      publicKeyData?: unknown;
      publicKeyFingerprint?: unknown;
      keyVersion?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = requireUid(request);
    const nonce = boundedTrimmedString(request.data?.nonce, "nonce", 256, true);
    const { nonceConsumed } = await enforceHighRiskComputerUseCallableWithNonce(request, uid, nonce, {
      allowLowerTrustDesktop: true,
    });
    if (getConfig().enforceAppCheck && !nonceConsumed) {
      throw new HttpsError(
        "failed-precondition",
        "Signal identity repair requires App Check and a fresh high-risk nonce.",
      );
    }

    const input = parseSignalIdentityRepairInput(request.data ?? {});
    const challengeRef = db.doc(`users/${uid}/signal_identity_repair_challenges/${input.challengeId}`);
    const deviceRef = db.doc(`users/${uid}/escrow_devices/${input.deviceId}`);
    const escrowRef = db.doc(`users/${uid}/escrow_public_keys/${input.deviceId}_${input.keyVersion}`);
    const identityRef = db.doc(`users/${uid}/signal_identity_public_keys/${input.identityKeyId}`);

    const result = await db.runTransaction(async (transaction) => {
      const [challengeSnapshot, deviceSnapshot, escrowSnapshot, identitySnapshot] = await Promise.all([
        transaction.get(challengeRef),
        transaction.get(deviceRef),
        transaction.get(escrowRef),
        transaction.get(identityRef),
      ]);
      const challenge = challengeSnapshot.data();
      assertValidRepairChallenge(challengeSnapshot.exists, challenge, input);

      const device = assertTrustedDevice(deviceSnapshot.data());
      assertDeviceUnchangedForRepair(device, challenge, input, escrowSnapshot.exists);
      assertEscrowPublicKey(escrowSnapshot.data(), input.deviceId, input.keyVersion, device.publicKeyFingerprint);
      assertIdentityPinAllowsRepair(
        deviceSnapshot.get("targetSignalIdentityKeyId"),
        deviceSnapshot.get("targetSignalIdentityPublicKeyFingerprint"),
        input,
      );

      let repaired = false;
      if (identitySnapshot.exists) {
        if (!identityDocumentMatches(identitySnapshot.data(), device.platform, input)) {
          throw new HttpsError("already-exists", "A different Signal identity already exists for this device version.");
        }
      } else {
        const identityDocument: Record<string, unknown> = {
          deviceId: input.deviceId,
          platform: device.platform,
          identityKeyId: input.identityKeyId,
          publicKeyData: input.signalPublicKeyBase64,
          publicKeyFingerprint: input.publicKeyFingerprint,
          keyVersion: input.keyVersion,
          algorithm: SIGNAL_IDENTITY_ALGORITHM,
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        };
        if (input.keyVersion > 1) identityDocument.keyVersionLabel = `${input.keyVersion}`;
        transaction.create(identityRef, identityDocument);
        repaired = true;
      }

      transaction.set(
        deviceRef,
        {
          // The legacy trust decision did not authenticate this newly-published
          // Signal identity. Keep the escrow-possession proof, but require a
          // trusted device to sign a fresh chain before vault wrappers can flow.
          trustState: "pending",
          approvedAt: FieldValue.delete(),
          approvedByDeviceId: FieldValue.delete(),
          approvedBySignalIdentityKeyId: FieldValue.delete(),
          approvedBySignalIdentityPublicKeyFingerprint: FieldValue.delete(),
          trustChainVersion: FieldValue.delete(),
          trustChainAlgorithm: FieldValue.delete(),
          trustChainSignature: FieldValue.delete(),
          targetSignalIdentityKeyId: input.identityKeyId,
          targetSignalIdentityPublicKeyFingerprint: input.publicKeyFingerprint,
          signalIdentityRepairVersion: SIGNAL_IDENTITY_REPAIR_CHALLENGE_VERSION,
          signalIdentityRepairAlgorithm: SIGNAL_IDENTITY_REPAIR_ALGORITHM,
          signalIdentityReapprovalRequired: true,
          signalIdentityRepairedAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      transaction.update(challengeRef, {
        consumedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      return { repaired };
    });

    logInfo({
      event: "trusted_signal_identity_repaired",
      uid,
      device_id: input.deviceId,
      identity_key_id: input.identityKeyId,
      repaired: result.repaired,
    });
    return {
      ok: true as const,
      deviceId: input.deviceId,
      identityKeyId: input.identityKeyId,
      repaired: result.repaired,
      reapprovalRequired: true as const,
    };
  },
);
