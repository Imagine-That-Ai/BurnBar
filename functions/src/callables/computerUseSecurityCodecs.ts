/**
 * @fileoverview Computer Use / escrow codecs — pure input validators, proof
 * parsers, and the P-256 / Ed25519 phone-control key + signature primitives.
 *
 * Extracted verbatim from `computerUseSecurity.ts` (U6 split) so every resulting
 * module stays under the per-file line budget. No Firestore / firebase-admin
 * dependency lives here — these are pure functions over wire inputs.
 */

import { createHash, createPublicKey, verify as verifySignature } from "node:crypto";

import { HttpsError } from "firebase-functions/v2/https";

import { recordOrUndefined } from "../guards.js";
import { boundedTrimmedString } from "./shared.js";

export const ESCROW_PLATFORMS = new Set(["macOS", "iOS", "iPadOS", "Android", "Linux"]);
export const ESCROW_WEB_PLATFORM = "Web";
export const MAC_ESCROW_PLATFORMS = new Set(["macOS"]);
export const IROH_HOST_ESCROW_PLATFORMS = new Set(["macOS", "Linux"]);
export const PHONE_CONTROL_ESCROW_PLATFORMS = new Set(["iOS", "iPadOS", "Android"]);
export const LOCAL_AUTH_PROOF_FRESHNESS_SECONDS = 5 * 60;
export const LOCAL_AUTH_PROOF_CLOCK_SKEW_SECONDS = 30;

export function normalizedControllerDeviceAllowlist(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const ids: string[] = [];
  for (const value of raw) {
    if (typeof value !== "string") continue;
    const id = value.trim();
    if (!id || id.length > 160 || ids.includes(id)) continue;
    ids.push(id);
  }
  return ids;
}

type CloudVaultDeviceTrustChainProof = {
  version: number;
  algorithm: string;
  targetSignalIdentityKeyId: string;
  targetSignalIdentityPublicKeyFingerprint: string;
  approverSignalIdentityKeyId: string;
  approverSignalIdentityPublicKeyFingerprint: string;
  signature: string;
};

type TrustedDeviceActionProof = {
  version: number;
  algorithm: string;
  deviceSignalIdentityKeyId: string;
  deviceSignalIdentityPublicKeyFingerprint: string;
  issuedAtMillis: number;
  signature: string;
};

const CLOUD_VAULT_DEVICE_TRUST_CHAIN_VERSION = 1;
const CLOUD_VAULT_DEVICE_TRUST_CHAIN_ALGORITHM = "signal-identity-xeddsa-v1";
const TRUSTED_DEVICE_ACTION_PROOF_VERSION = 1;
export const TRUSTED_DEVICE_ACTION_PROOF_DOMAIN = "OpenBurnBar-TrustedDeviceAction-v1";
export const TRUSTED_DEVICE_ACTION_PROOF_MAX_AGE_MS = 5 * 60 * 1000;
export const TRUSTED_DEVICE_ACTION_PROOF_CLOCK_SKEW_MS = 30 * 1000;

export function isNativeEscrowPlatform(raw: unknown): raw is string {
  return typeof raw === "string" && ESCROW_PLATFORMS.has(raw);
}

export function parseEscrowPlatform(raw: unknown): string {
  const platform = boundedTrimmedString(raw, "platform", 80, true);
  if (!platform || !ESCROW_PLATFORMS.has(platform)) {
    throw new HttpsError("invalid-argument", "platform must be macOS, iOS, iPadOS, Android, or Linux.");
  }
  return platform;
}

export function boundedInteger(
  raw: unknown,
  name: string,
  min: number,
  max: number,
  required = true,
): number | undefined {
  if (raw == null) {
    if (required) throw new HttpsError("invalid-argument", `${name} is required.`);
    return undefined;
  }
  const value = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new HttpsError("invalid-argument", `${name} is invalid.`);
  }
  return value;
}

export function boundedStringArray(raw: unknown, name: string, maxItems: number, maxItemLength: number): string[] {
  if (raw == null) return [];
  if (!Array.isArray(raw) || raw.length > maxItems) {
    throw new HttpsError("invalid-argument", `${name} is invalid.`);
  }
  return raw.map((item, index) => boundedTrimmedString(item, `${name}[${index}]`, maxItemLength, true));
}

export function requireBase64Like(raw: unknown, name: string, minLength: number, maxLength: number): string {
  const value = boundedTrimmedString(raw, name, maxLength, true);
  if (value.length < minLength || !/^[A-Za-z0-9+/=]+$/u.test(value)) {
    throw new HttpsError("invalid-argument", `${name} must be base64.`);
  }
  return value;
}

export function parseCloudVaultDeviceTrustChainProof(raw: unknown): CloudVaultDeviceTrustChainProof {
  const record = recordOrUndefined(raw);
  if (!record) {
    throw new HttpsError("invalid-argument", "trustChain is required.");
  }
  const version =
    boundedInteger(
      record.version,
      "trustChain.version",
      CLOUD_VAULT_DEVICE_TRUST_CHAIN_VERSION,
      CLOUD_VAULT_DEVICE_TRUST_CHAIN_VERSION,
      true,
    ) ?? CLOUD_VAULT_DEVICE_TRUST_CHAIN_VERSION;
  const algorithm = boundedTrimmedString(record.algorithm, "trustChain.algorithm", 80, true);
  if (algorithm !== CLOUD_VAULT_DEVICE_TRUST_CHAIN_ALGORITHM) {
    throw new HttpsError("invalid-argument", "trustChain.algorithm is unsupported.");
  }
  return {
    version,
    algorithm,
    targetSignalIdentityKeyId: boundedTrimmedString(
      record.targetSignalIdentityKeyId,
      "trustChain.targetSignalIdentityKeyId",
      200,
      true,
    ),
    targetSignalIdentityPublicKeyFingerprint: boundedTrimmedString(
      record.targetSignalIdentityPublicKeyFingerprint,
      "trustChain.targetSignalIdentityPublicKeyFingerprint",
      128,
      true,
    ),
    approverSignalIdentityKeyId: boundedTrimmedString(
      record.approverSignalIdentityKeyId,
      "trustChain.approverSignalIdentityKeyId",
      200,
      true,
    ),
    approverSignalIdentityPublicKeyFingerprint: boundedTrimmedString(
      record.approverSignalIdentityPublicKeyFingerprint,
      "trustChain.approverSignalIdentityPublicKeyFingerprint",
      128,
      true,
    ),
    signature: requireBase64Like(record.signature, "trustChain.signature", 64, 256),
  };
}

export function parseTrustedDeviceActionProof(raw: unknown): TrustedDeviceActionProof {
  const record = recordOrUndefined(raw);
  if (!record) {
    throw new HttpsError("invalid-argument", "actionProof is required.");
  }
  const version =
    boundedInteger(
      record.version,
      "actionProof.version",
      TRUSTED_DEVICE_ACTION_PROOF_VERSION,
      TRUSTED_DEVICE_ACTION_PROOF_VERSION,
      true,
    ) ?? TRUSTED_DEVICE_ACTION_PROOF_VERSION;
  const algorithm = boundedTrimmedString(record.algorithm, "actionProof.algorithm", 80, true);
  if (algorithm !== CLOUD_VAULT_DEVICE_TRUST_CHAIN_ALGORITHM) {
    throw new HttpsError("invalid-argument", "actionProof.algorithm is unsupported.");
  }
  return {
    version,
    algorithm,
    deviceSignalIdentityKeyId: boundedTrimmedString(
      record.deviceSignalIdentityKeyId,
      "actionProof.deviceSignalIdentityKeyId",
      200,
      true,
    ),
    deviceSignalIdentityPublicKeyFingerprint: boundedTrimmedString(
      record.deviceSignalIdentityPublicKeyFingerprint,
      "actionProof.deviceSignalIdentityPublicKeyFingerprint",
      128,
      true,
    ),
    issuedAtMillis:
      boundedInteger(record.issuedAtMillis, "actionProof.issuedAtMillis", 0, Number.MAX_SAFE_INTEGER, true) ?? 0,
    signature: requireBase64Like(record.signature, "actionProof.signature", 64, 256),
  };
}

export function boundedFirestoreDocumentId(raw: unknown, name: string, maxLength: number): string {
  const value = boundedTrimmedString(raw, name, maxLength, true);
  if (!/^[A-Za-z0-9._:-]+$/u.test(value)) {
    throw new HttpsError("invalid-argument", `${name} must be a path-safe identifier.`);
  }
  return value;
}

// 65-byte uncompressed x9.63 P-256 public key: 0x04 || X(32) || Y(32).
export const P256_X963_PUBLIC_KEY_BYTE_LENGTH = 65;
const P256_COORDINATE_BYTE_LENGTH = 32;
const ED25519_PUBLIC_KEY_BYTE_LENGTH = 32;
export const RELAY_AUTH_ENCRYPTION = "hpke-auth-p256-hkdfsha256-aes256gcm";
export const RELAY_AUTH_KEY_VERSION = 3;
const MAX_TRUST_ROOT_PUBLICATION_SKEW_MILLIS = 10 * 60 * 1000;
export const AGENT_GRANT_AUTHORITY_FRESHNESS_SECONDS = 60;
export const ED25519_SPKI_DER_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

/**
 * Validate that the 65-byte x9.63 public-key bytes encode a point that actually
 * lies on the NIST P-256 curve. Native CryptoKit rejects off-curve points when
 * it imports a `P256.KeyAgreement.PublicKey`; the server + web recompute paths
 * must match that posture or a malformed/off-curve key whose SHA-256 happens to
 * equal a stored fingerprint could be admitted. `node:crypto.createPublicKey`
 * with a JWK runs the same on-curve check and throws on an invalid point, so we
 * fail closed (return false) on any error.
 *
 * `raw` MUST already be the 65-byte `0x04 || X(32) || Y(32)` buffer (length +
 * prefix checked by the caller).
 */
export function isPointOnP256Curve(raw: Buffer): boolean {
  try {
    const x = raw.subarray(1, 1 + P256_COORDINATE_BYTE_LENGTH).toString("base64url");
    const y = raw.subarray(1 + P256_COORDINATE_BYTE_LENGTH, 1 + 2 * P256_COORDINATE_BYTE_LENGTH).toString("base64url");
    createPublicKey({ key: { kty: "EC", crv: "P-256", x, y }, format: "jwk" });
    return true;
  } catch {
    return false;
  }
}

/** Normalize base64 (strip whitespace) so the round-trip comparison is exact. */
export function normalizeBase64(value: string): string {
  return value.replace(/\s+/gu, "");
}

function requireExactBase64Bytes(raw: unknown, name: string, byteLength: number): Buffer {
  const encoded = requireBase64Like(raw, name, Math.ceil(byteLength * 1.3), Math.ceil(byteLength * 1.5) + 8);
  const decoded = Buffer.from(encoded, "base64");
  if (decoded.length !== byteLength || decoded.toString("base64") !== normalizeBase64(encoded)) {
    throw new HttpsError("invalid-argument", `${name} has invalid key bytes.`);
  }
  return decoded;
}

export function requireP256X963PublicKey(raw: unknown, name: string): { encoded: string; decoded: Buffer } {
  const encoded = requireBase64Like(raw, name, 80, 128);
  const decoded = Buffer.from(encoded, "base64");
  if (
    decoded.length !== P256_X963_PUBLIC_KEY_BYTE_LENGTH ||
    decoded[0] !== 0x04 ||
    decoded.toString("base64") !== normalizeBase64(encoded) ||
    !isPointOnP256Curve(decoded)
  ) {
    throw new HttpsError("invalid-argument", `${name} must be a valid x9.63 P-256 public key.`);
  }
  return { encoded, decoded };
}

export function requireFreshPublicationMillis(raw: unknown, name: string): number {
  const value = boundedInteger(raw ?? Date.now(), name, 1, Number.MAX_SAFE_INTEGER, true) ?? Date.now();
  if (Math.abs(Date.now() - value) > MAX_TRUST_ROOT_PUBLICATION_SKEW_MILLIS) {
    throw new HttpsError("failed-precondition", `${name} is stale.`);
  }
  return value;
}

// F2 — hardware-bind the phone-control signing key. `ed25519` is the legacy
// software CryptoKit key; `se-p256` is a non-exportable NIST P-256 key held in
// the iOS Secure Enclave / Android StrongBox Keystore. An absent wire value is
// treated as the legacy default so pre-F2 clients keep working unchanged.
type PhoneControlSigningKeyKind = "ed25519" | "se-p256";

export function parsePhoneControlSigningKeyKind(raw: unknown): PhoneControlSigningKeyKind {
  if (raw === undefined || raw === null || raw === "" || raw === "ed25519") return "ed25519";
  if (raw === "se-p256") return "se-p256";
  throw new HttpsError("invalid-argument", "Unsupported phone-control signing keyKind.");
}

/// Validate the published controller public key for the given key kind and
/// return its bytes plus the canonical base64 to persist. Ed25519 keys are
/// 32-byte raw; SE-P256 keys are x9.63 (65-byte, 0x04-prefixed, on-curve).
export function requirePhoneControlAuthorityPublicKey(
  raw: unknown,
  keyKind: PhoneControlSigningKeyKind,
): { bytes: Buffer; base64: string } {
  if (keyKind === "se-p256") {
    const { encoded, decoded } = requireP256X963PublicKey(raw, "publicKeyBase64");
    return { bytes: decoded, base64: encoded };
  }
  const base64 = requireBase64Like(raw, "publicKeyBase64", 32, 128);
  const bytes = requireExactBase64Bytes(base64, "publicKeyBase64", ED25519_PUBLIC_KEY_BYTE_LENGTH);
  return { bytes, base64: bytes.toString("base64") };
}

export function requireDerivedPhoneControlPeerNodeId(
  peerNodeId: string,
  publicKey: Buffer,
  keyKind: PhoneControlSigningKeyKind = "ed25519",
): void {
  // Must stay byte-identical to PhoneControlPeerNodeIdDerivation (Swift) and
  // the Kotlin mirror; the peerNodeId pins the key, keys replay counters, and
  // gates revocation, so a divergence between client and server is a fail-open.
  const candidates: string[] = [];
  if (keyKind === "se-p256") {
    const digest = createHash("sha256").update(publicKey).digest("hex").slice(0, 24);
    candidates.push(`ios-se-${digest}`, `android-se-${digest}`);
  } else {
    candidates.push(`ios-phone-${publicKey.subarray(0, 12).toString("hex")}`);
    candidates.push(`android-phone-${createHash("sha256").update(publicKey).digest("hex").slice(0, 24)}`);
  }
  if (!candidates.includes(peerNodeId)) {
    throw new HttpsError("invalid-argument", "peerNodeId does not match the published authority key.");
  }
}

export function verifyEd25519RawSignature(publicKeyRaw: Buffer, payload: Buffer, signatureBase64: string): boolean {
  const signature = Buffer.from(signatureBase64, "base64");
  if (signature.length !== 64 || signature.toString("base64") !== normalizeBase64(signatureBase64)) {
    return false;
  }
  const publicKey = createPublicKey({
    key: Buffer.concat([ED25519_SPKI_DER_PREFIX, publicKeyRaw]),
    format: "der",
    type: "spki",
  });
  return verifySignature(null, payload, publicKey, signature);
}

/// F2 — key-kind-aware authority signature verify, byte-mirroring the Swift
/// `PhoneControlVerifyingKey`: legacy Ed25519 over raw 32-byte keys, or
/// ECDSA-P256-over-SHA256 with the fixed-size raw `r‖s` wire form
/// (`ieee-p1363`) under a 65-byte X9.63 public key. The `signatureEd25519`
/// field is the carrier regardless of algorithm.
export function verifyPhoneControlAuthoritySignature(
  publicKey: Buffer,
  keyKind: PhoneControlSigningKeyKind,
  payload: Buffer,
  signatureBase64: string,
): boolean {
  if (keyKind !== "se-p256") {
    return verifyEd25519RawSignature(publicKey, payload, signatureBase64);
  }
  const signature = Buffer.from(signatureBase64, "base64");
  if (signature.length !== 64 || signature.toString("base64") !== normalizeBase64(signatureBase64)) {
    return false;
  }
  if (publicKey.length !== P256_X963_PUBLIC_KEY_BYTE_LENGTH || publicKey[0] !== 0x04) {
    return false;
  }
  try {
    const key = createPublicKey({
      key: {
        kty: "EC",
        crv: "P-256",
        x: publicKey.subarray(1, 1 + P256_COORDINATE_BYTE_LENGTH).toString("base64url"),
        y: publicKey.subarray(1 + P256_COORDINATE_BYTE_LENGTH).toString("base64url"),
      },
      format: "jwk",
    });
    return verifySignature("sha256", payload, { key, dsaEncoding: "ieee-p1363" }, signature);
  } catch {
    return false;
  }
}
