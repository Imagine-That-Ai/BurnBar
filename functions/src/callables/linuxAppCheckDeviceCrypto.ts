/**
 * @fileoverview Canonical wire format and Ed25519 proof verification for the
 * Linux App Check device-key attestation lane. This module is intentionally
 * pure: it owns no Firebase state and can be mirrored byte-for-byte by clients.
 */

import { createHash, createPublicKey, verify as verifySignature } from "node:crypto";

import { HttpsError } from "firebase-functions/v2/https";

import { boundedInteger, requireBase64Like } from "./computerUseSecurityCodecs.js";
import { boundedTrimmedString } from "./shared.js";

export const LINUX_APP_CHECK_ATTESTATION_KIND = "device-key-v1" as const;
export const LINUX_APP_CHECK_ENROLLMENT_DOMAIN = "openburnbar.linux.appcheck.enroll.v1" as const;
export const LINUX_APP_CHECK_CHALLENGE_DOMAIN = "openburnbar.linux.appcheck.challenge.v1" as const;
export const LINUX_APP_CHECK_ENROLLMENT_MAX_AGE_MS = 5 * 60 * 1000;
export const LINUX_APP_CHECK_CLOCK_SKEW_MS = 60 * 1000;
export const LINUX_APP_CHECK_CHALLENGE_TTL_MS = 2 * 60 * 1000;

const ED25519_PUBLIC_KEY_BYTE_LENGTH = 32;
const ED25519_SIGNATURE_BYTE_LENGTH = 64;
const ED25519_SPKI_DER_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const LINUX_DEVICE_ID_PREFIX = "linux_";

export interface LinuxAppCheckEnrollmentProof {
  appId: string;
  deviceId: string;
  publicKeyBase64: string;
  issuedAtMillis: number;
  signatureBase64: string;
}

export interface LinuxAppCheckChallengePayload {
  appId: string;
  challengeId: string;
  challengeNonce: string;
  deviceId: string;
  expiresAtMillis: number;
  issuedAtMillis: number;
  uid: string;
}

function canonicalLengthPrefixedPayload(domain: string, fields: ReadonlyArray<readonly [string, string]>): Buffer {
  const lines = [domain];
  for (const [name, value] of fields) {
    lines.push(`${name}:${Buffer.byteLength(value, "utf8")}:${value}`);
  }
  return Buffer.from(`${lines.join("\n")}\n`, "utf8");
}

export function parseLinuxAppCheckPublicKey(raw: unknown): { bytes: Buffer; base64: string } {
  const base64 = requireBase64Like(raw, "publicKeyBase64", 32, 128);
  const bytes = Buffer.from(base64, "base64");
  if (bytes.length !== ED25519_PUBLIC_KEY_BYTE_LENGTH || bytes.toString("base64") !== base64) {
    throw new HttpsError("invalid-argument", "publicKeyBase64 must be a canonical 32-byte Ed25519 public key.");
  }
  try {
    createPublicKey({
      key: Buffer.concat([ED25519_SPKI_DER_PREFIX, bytes]),
      format: "der",
      type: "spki",
    });
  } catch {
    throw new HttpsError("invalid-argument", "publicKeyBase64 must be a valid Ed25519 public key.");
  }
  return { bytes, base64 };
}

export function deriveLinuxAppCheckDeviceId(publicKey: Buffer): string {
  if (publicKey.length !== ED25519_PUBLIC_KEY_BYTE_LENGTH) {
    throw new HttpsError("invalid-argument", "Linux App Check device keys must be 32-byte Ed25519 public keys.");
  }
  return `${LINUX_DEVICE_ID_PREFIX}${createHash("sha256").update(publicKey).digest("hex")}`;
}

export function linuxAppCheckSafetyFingerprint(publicKey: Buffer): string {
  return createHash("sha256")
    .update(publicKey)
    .digest("hex")
    .toUpperCase()
    .match(/.{1,4}/gu)!
    .join(" ");
}

export function linuxAppCheckEnrollmentPayload(input: {
  appId: string;
  deviceId: string;
  publicKeyBase64: string;
  issuedAtMillis: number;
  uid: string;
}): Buffer {
  return Buffer.from(
    [
      LINUX_APP_CHECK_ENROLLMENT_DOMAIN,
      input.uid,
      input.deviceId,
      input.appId,
      input.publicKeyBase64,
      String(input.issuedAtMillis),
    ].join("\n"),
    "utf8",
  );
}

export function linuxAppCheckChallengePayload(input: LinuxAppCheckChallengePayload): Buffer {
  return canonicalLengthPrefixedPayload(LINUX_APP_CHECK_CHALLENGE_DOMAIN, [
    ["appId", input.appId],
    ["challengeId", input.challengeId],
    ["challengeNonce", input.challengeNonce],
    ["deviceId", input.deviceId],
    ["expiresAtMillis", String(input.expiresAtMillis)],
    ["issuedAtMillis", String(input.issuedAtMillis)],
    ["uid", input.uid],
  ]);
}

export function verifyLinuxAppCheckEd25519Signature(args: {
  payload: Buffer;
  publicKey: Buffer;
  signatureBase64: unknown;
}): boolean {
  let signatureBase64: string;
  try {
    signatureBase64 = requireBase64Like(args.signatureBase64, "signatureBase64", 64, 256);
  } catch {
    return false;
  }
  const signature = Buffer.from(signatureBase64, "base64");
  if (signature.length !== ED25519_SIGNATURE_BYTE_LENGTH || signature.toString("base64") !== signatureBase64) {
    return false;
  }
  try {
    const key = createPublicKey({
      key: Buffer.concat([ED25519_SPKI_DER_PREFIX, args.publicKey]),
      format: "der",
      type: "spki",
    });
    return verifySignature(null, args.payload, key, signature);
  } catch {
    return false;
  }
}

export function parseLinuxAppCheckEnrollmentProof(
  raw: {
    appId?: unknown;
    deviceId?: unknown;
    publicKeyBase64?: unknown;
    issuedAtMillis?: unknown;
    signatureBase64?: unknown;
  },
  expectedAppId: string,
  uid: string,
  nowMillis: number,
): LinuxAppCheckEnrollmentProof & { publicKey: Buffer; canonicalPayload: Buffer } {
  const appId = boundedTrimmedString(raw.appId, "appId", 160, true);
  if (appId !== expectedAppId) {
    throw new HttpsError("permission-denied", "Linux enrollment is bound to an unexpected App Check app id.");
  }
  const { bytes: publicKey, base64: publicKeyBase64 } = parseLinuxAppCheckPublicKey(raw.publicKeyBase64);
  const derivedDeviceId = deriveLinuxAppCheckDeviceId(publicKey);
  const deviceId = boundedTrimmedString(raw.deviceId ?? derivedDeviceId, "deviceId", 160, true);
  if (deviceId !== derivedDeviceId) {
    throw new HttpsError("invalid-argument", "deviceId does not match the Linux App Check public key.");
  }
  const issuedAtMillis = boundedInteger(raw.issuedAtMillis, "issuedAtMillis", 1, Number.MAX_SAFE_INTEGER, true) ?? 0;
  const age = nowMillis - issuedAtMillis;
  if (age > LINUX_APP_CHECK_ENROLLMENT_MAX_AGE_MS || age < -LINUX_APP_CHECK_CLOCK_SKEW_MS) {
    throw new HttpsError("failed-precondition", "Linux enrollment proof is stale.");
  }
  const canonicalPayload = linuxAppCheckEnrollmentPayload({
    appId,
    deviceId,
    publicKeyBase64,
    issuedAtMillis,
    uid,
  });
  const signatureBase64 = boundedTrimmedString(raw.signatureBase64, "signatureBase64", 256, true);
  if (!verifyLinuxAppCheckEd25519Signature({ payload: canonicalPayload, publicKey, signatureBase64 })) {
    throw new HttpsError("unauthenticated", "Linux enrollment proof-of-possession signature did not verify.");
  }
  return { appId, deviceId, publicKeyBase64, issuedAtMillis, signatureBase64, publicKey, canonicalPayload };
}
