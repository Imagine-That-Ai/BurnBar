/**
 * @fileoverview Computer Use / escrow high-risk callables (WS4 cloud defense-in-depth).
 *
 * Trust elevation and grant-adjacent mutations route through App-Check-enforced
 * callables with attestation-bound Auth custom claims instead of direct client
 * Firestore writes to `trustState: trusted`.
 */

import { createHash, createPublicKey, randomBytes, timingSafeEqual, verify as verifySignature } from "node:crypto";

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import {
  bindAppCheckAttestationForUid,
  enforceHighRiskComputerUseCallable,
  enforceHighRiskComputerUseCallableWithNonce,
  issueHighRiskNonceForUid,
  readAppIdFromCallableRequest,
} from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { recordOrUndefined } from "../guards.js";
import { logInfo, logWarn, onCallProduction, wrapCallableHandler } from "../logging.js";
import { boundedTrimmedString } from "./shared.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { revokeSignalSessionsForDevice } from "../signalDirectoryRuntime.js";

const ESCROW_PLATFORMS = new Set(["macOS", "iOS", "iPadOS", "Android"]);
const ESCROW_WEB_PLATFORM = "Web";
const MAC_ESCROW_PLATFORMS = new Set(["macOS"]);
const PHONE_CONTROL_ESCROW_PLATFORMS = new Set(["iOS", "iPadOS", "Android"]);
const LOCAL_AUTH_PROOF_FRESHNESS_SECONDS = 5 * 60;
const LOCAL_AUTH_PROOF_CLOCK_SKEW_SECONDS = 30;

type AgentGrantLocalAuthProof = {
  proofId: string;
  deviceId: string;
  signedIntentHash: string;
  authenticatedAt: number;
  expiresAt: number;
  signatureEd25519: string;
};

type CloudVaultDeviceTrustChainProof = {
  version: number;
  algorithm: string;
  targetSignalIdentityKeyId: string;
  targetSignalIdentityPublicKeyFingerprint: string;
  approverSignalIdentityKeyId: string;
  approverSignalIdentityPublicKeyFingerprint: string;
  signature: string;
};

const CLOUD_VAULT_DEVICE_TRUST_CHAIN_VERSION = 1;
const CLOUD_VAULT_DEVICE_TRUST_CHAIN_ALGORITHM = "signal-identity-xeddsa-v1";

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

function boundedInteger(raw: unknown, name: string, min: number, max: number, required = true): number | undefined {
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

function boundedStringArray(raw: unknown, name: string, maxItems: number, maxItemLength: number): string[] {
  if (raw == null) return [];
  if (!Array.isArray(raw) || raw.length > maxItems) {
    throw new HttpsError("invalid-argument", `${name} is invalid.`);
  }
  return raw.map((item, index) => boundedTrimmedString(item, `${name}[${index}]`, maxItemLength, true));
}

function requireBase64Like(raw: unknown, name: string, minLength: number, maxLength: number): string {
  const value = boundedTrimmedString(raw, name, maxLength, true);
  if (value.length < minLength || !/^[A-Za-z0-9+/=]+$/u.test(value)) {
    throw new HttpsError("invalid-argument", `${name} must be base64.`);
  }
  return value;
}

function parseCloudVaultDeviceTrustChainProof(raw: unknown): CloudVaultDeviceTrustChainProof {
  const record = recordOrUndefined(raw);
  if (!record) {
    throw new HttpsError("invalid-argument", "trustChain is required.");
  }
  const version =
    boundedInteger(record.version, "trustChain.version", CLOUD_VAULT_DEVICE_TRUST_CHAIN_VERSION, CLOUD_VAULT_DEVICE_TRUST_CHAIN_VERSION, true) ??
    CLOUD_VAULT_DEVICE_TRUST_CHAIN_VERSION;
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

function boundedFirestoreDocumentId(raw: unknown, name: string, maxLength: number): string {
  const value = boundedTrimmedString(raw, name, maxLength, true);
  if (!/^[A-Za-z0-9._:-]+$/u.test(value)) {
    throw new HttpsError("invalid-argument", `${name} must be a path-safe identifier.`);
  }
  return value;
}

async function requireTrustedEscrowDevice(
  uid: string,
  deviceId: string,
  allowedPlatforms: Set<string>,
): Promise<{ deviceId: string; platform: string }> {
  const device = await db.doc(`users/${uid}/escrow_devices/${deviceId}`).get();
  const platform = device.exists ? device.get("platform") : undefined;
  if (!device.exists || device.get("trustState") !== "trusted" || typeof platform !== "string" || !allowedPlatforms.has(platform)) {
    throw new HttpsError("permission-denied", "This mutation requires a trusted device for the requested trust root.");
  }
  return { deviceId, platform };
}

// ---------------------------------------------------------------------------
// Stream 6 enablement — server-side device-key fingerprint enforcement.
//
// The approve path historically branched only on deviceId / approverDeviceId /
// platform / trustState. A trusted approver could therefore promote a device
// whose stored `publicKeyFingerprint` does NOT correspond to the public-key
// bytes the device will actually use to seal escrow envelopes — exactly the
// substitution the client-side key-bound safety code (`EscrowDeviceSafetyCode`)
// now guards against. This adds the matching SERVER-SIDE check.
//
// **Inert by default.** The enforcement is gated on the Stream 6 capability
// flag below, which mirrors the native `EscrowDeviceTrustSafetyCheckFlag`
// (default OFF). While OFF the validation runs in shadow only (it never blocks
// an approval that previously succeeded), so existing production behavior is
// unchanged. Flipping the flag ON — plus live device verification — is the
// remaining, deliberately separate activation step. The code path + validation
// exist and are tested today.
//
// 65-byte uncompressed x9.63 P-256 public key: 0x04 || X(32) || Y(32) — the same
// shape `registerBrowserEscrowDevice` and the native keypair advertise.
const P256_X963_PUBLIC_KEY_BYTE_LENGTH = 65;
const P256_COORDINATE_BYTE_LENGTH = 32;
const ED25519_PUBLIC_KEY_BYTE_LENGTH = 32;
const RELAY_AUTH_ENCRYPTION = "hpke-auth-p256-hkdfsha256-aes256gcm";
const RELAY_AUTH_KEY_VERSION = 3;
const MAX_TRUST_ROOT_PUBLICATION_SKEW_MILLIS = 10 * 60 * 1000;
const COCOA_REFERENCE_UNIX_OFFSET_SECONDS = 978_307_200;
const AGENT_GRANT_AUTHORITY_FRESHNESS_SECONDS = 60;
const ED25519_SPKI_DER_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

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
function isPointOnP256Curve(raw: Buffer): boolean {
  try {
    const x = raw.subarray(1, 1 + P256_COORDINATE_BYTE_LENGTH).toString("base64url");
    const y = raw.subarray(1 + P256_COORDINATE_BYTE_LENGTH, 1 + 2 * P256_COORDINATE_BYTE_LENGTH).toString("base64url");
    createPublicKey({ key: { kty: "EC", crv: "P-256", x, y }, format: "jwk" });
    return true;
  } catch {
    return false;
  }
}

/**
 * Stream 6 capability gate (server mirror of `EscrowDeviceTrustSafetyCheckFlag`).
 *
 * **ON (F2):** `approveEscrowDeviceTrust` now fails closed when a device's stored
 * `publicKeyFingerprint` does not match the SHA-256 of its actually-published
 * `escrow_public_keys` bytes — binding escrow-device trust to the real key so a
 * relay/Firestore tamper cannot advertise a swapped key (or a fingerprint
 * unrelated to the key) and have it approved. A device with no key on file yet is
 * a no-op (`missing_public_key` → ok), so this cannot brick a device that simply
 * has not published its key; only an actual mismatch / a key-without-fingerprint
 * is refused. The native `EscrowDeviceTrustSafetyCheckFlag` should be activated in
 * lockstep so the client surfaces the safety-number comparison UX.
 */
const ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED = true;

/** The outcome of checking a stored fingerprint against the real key bytes. */
type EscrowFingerprintCheck =
  | { ok: true; reason: "match" }
  | { ok: true; reason: "missing_public_key" } // no key on file yet — nothing to bind to.
  | { ok: false; reason: "fingerprint_mismatch" }
  | { ok: false; reason: "invalid_public_key" }
  | { ok: false; reason: "missing_fingerprint" };

/**
 * Re-derive the canonical escrow fingerprint — `base64(SHA-256(publicKeyData))`
 * — from the device's actual x9.63 P-256 public-key bytes, or `null` when the
 * bytes are absent / not base64 / not a 65-byte key. This is the exact server
 * mirror of `EscrowDeviceSafetyCode.recomputeFingerprint` and of
 * `registerBrowserEscrowDevice`'s `createHash("sha256").update(publicKeyData)`.
 */
function recomputeEscrowFingerprint(publicKeyDataBase64: unknown): string | null {
  if (typeof publicKeyDataBase64 !== "string") return null;
  const trimmed = publicKeyDataBase64.trim();
  if (!trimmed) return null;
  // `Buffer.from(..., "base64")` is lenient; re-encode and compare to reject
  // non-base64 / padding-mangled input rather than silently hashing garbage.
  const raw = Buffer.from(trimmed, "base64");
  if (raw.length !== P256_X963_PUBLIC_KEY_BYTE_LENGTH || raw[0] !== 0x04) return null;
  if (raw.toString("base64") !== normalizeBase64(trimmed)) return null;
  // Native CryptoKit rejects off-curve points on import; mirror that here so a
  // well-formed-but-off-curve key can never be fingerprinted (fail closed).
  if (!isPointOnP256Curve(raw)) return null;
  return createHash("sha256").update(raw).digest("base64");
}

/** Normalize base64 (strip whitespace) so the round-trip comparison is exact. */
function normalizeBase64(value: string): string {
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

function requireP256X963PublicKey(raw: unknown, name: string): { encoded: string; decoded: Buffer } {
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

function requireFreshPublicationMillis(raw: unknown, name: string): number {
  const value = boundedInteger(raw ?? Date.now(), name, 1, Number.MAX_SAFE_INTEGER, true) ?? Date.now();
  if (Math.abs(Date.now() - value) > MAX_TRUST_ROOT_PUBLICATION_SKEW_MILLIS) {
    throw new HttpsError("failed-precondition", `${name} is stale.`);
  }
  return value;
}

function requireDerivedPhoneControlPeerNodeId(peerNodeId: string, publicKey: Buffer): void {
  const iosPeerNodeId = `ios-phone-${publicKey.subarray(0, 12).toString("hex")}`;
  const androidPeerNodeId = `android-phone-${createHash("sha256").update(publicKey).digest("hex").slice(0, 24)}`;
  if (peerNodeId !== iosPeerNodeId && peerNodeId !== androidPeerNodeId) {
    throw new HttpsError("invalid-argument", "peerNodeId does not match the published authority key.");
  }
}

function canonicalJSONQuote(value: string): string {
  return JSON.stringify(value);
}

function canonicalJSONNumber(value: number): string {
  if (!Number.isFinite(value)) {
    throw new HttpsError("invalid-argument", "Signed grant request contains a non-finite number.");
  }
  if (Number.isInteger(value)) return String(value);
  return value.toFixed(12).replace(/(?:\.0+|(\.\d*?)0+)$/u, "$1");
}

function canonicalAgentGrantRequestJSON(request: {
  requestId: string;
  runtime: string;
  threadId: string;
  preset: string;
  capabilities: string[];
  trustMode: string;
  deliveryMode: string;
  requestedAt: number;
  expiresAt: number;
  grantDurationSeconds: number;
  sourceDeviceId: string;
  clientIntentId: string;
  localAuthenticationSatisfied: boolean;
}): string {
  const fields = new Map<string, string>([
    ["capabilities", `[${[...request.capabilities].sort().map(canonicalJSONQuote).join(",")}]`],
    ["clientIntentId", canonicalJSONQuote(request.clientIntentId)],
    ["deliveryMode", canonicalJSONQuote(request.deliveryMode)],
    ["expiresAt", canonicalJSONNumber(request.expiresAt)],
    ["grantDurationSeconds", canonicalJSONNumber(request.grantDurationSeconds)],
    ["localAuthenticationSatisfied", request.localAuthenticationSatisfied ? "true" : "false"],
    ["preset", canonicalJSONQuote(request.preset)],
    ["requestedAt", canonicalJSONNumber(request.requestedAt)],
    ["requestId", canonicalJSONQuote(request.requestId)],
    ["runtime", canonicalJSONQuote(request.runtime)],
    ["sourceDeviceId", canonicalJSONQuote(request.sourceDeviceId)],
    ["threadId", canonicalJSONQuote(request.threadId)],
    ["trustMode", canonicalJSONQuote(request.trustMode)],
  ]);
  return `{${[...fields.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `${canonicalJSONQuote(key)}:${value}`)
    .join(",")}}`;
}

function agentGrantRequestHashHex(request: Parameters<typeof canonicalAgentGrantRequestJSON>[0]): string {
  return createHash("sha256").update(canonicalAgentGrantRequestJSON(request)).digest("hex");
}

function cocoaReferenceSecondsNow(): number {
  return Date.now() / 1000 - COCOA_REFERENCE_UNIX_OFFSET_SECONDS;
}

function cocoaReferenceSecondsToUnixMillis(referenceSeconds: number): bigint {
  return BigInt(Math.round((referenceSeconds + COCOA_REFERENCE_UNIX_OFFSET_SECONDS) * 1000));
}

function agentGrantAuthoritySignablePayload(intentHashHex: string, counter: number, timestampReferenceSeconds: number): Buffer {
  const hashBytes = Buffer.from(intentHashHex, "utf8");
  const suffix = Buffer.alloc(16);
  suffix.writeBigUInt64BE(BigInt(counter), 0);
  suffix.writeBigInt64BE(cocoaReferenceSecondsToUnixMillis(timestampReferenceSeconds), 8);
  return Buffer.concat([hashBytes, suffix]);
}

function agentGrantLocalAuthProofSignablePayload(proof: Pick<
  AgentGrantLocalAuthProof,
  "proofId" | "deviceId" | "signedIntentHash" | "authenticatedAt" | "expiresAt"
>): Buffer {
  const domain = "OpenBurnBar.AgentGrantLocalAuthProof.v1";
  const canonical = [
    domain,
    proof.proofId,
    proof.deviceId,
    proof.signedIntentHash.toLowerCase(),
    canonicalJSONNumber(proof.authenticatedAt),
    canonicalJSONNumber(proof.expiresAt),
  ].join("\n");
  return Buffer.from(canonical, "utf8");
}

function verifyEd25519RawSignature(publicKeyRaw: Buffer, payload: Buffer, signatureBase64: string): boolean {
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

function grantPresetCapabilities(preset: string): string[] {
  switch (preset) {
    case "off":
      return [];
    case "low":
      return ["workspace_read"];
    case "workspace":
      return ["shell", "workspace_read", "workspace_write"];
    case "desktop":
      return [
        "accessibility_inspect",
        "desktop_browser",
        "desktop_file_export",
        "desktop_screenshot",
        "workspace_read",
        "workspace_write",
      ];
    case "all":
      return [
        "accessibility_inspect",
        "desktop_browser",
        "desktop_file_export",
        "desktop_screenshot",
        "desktop_system_input",
        "shell",
        "workspace_read",
        "workspace_write",
      ];
    case "yolo":
      return [
        "accessibility_inspect",
        "desktop_browser",
        "desktop_file_export",
        "desktop_screenshot",
        "desktop_system_input",
        "shell",
        "shell_unrestricted",
        "workspace_read",
        "workspace_write",
      ];
    default:
      throw new HttpsError("invalid-argument", "Unsupported grant preset.");
  }
}

function grantPresetTrustMode(preset: string): string {
  return preset === "yolo" ? "trusted" : "manual";
}

function queuedAgentGrantRequiresLocalAuthProof(capabilities: string[], trustMode: string): boolean {
  if (trustMode === "trusted") return true;
  return capabilities.some((capability) => {
    return (
      capability === "shell" ||
      capability === "workspace_write" ||
      capability === "desktop_system_input" ||
      capability === "shell_unrestricted" ||
      capability.startsWith("desktop_")
    );
  });
}

function queuedAgentGrantRequiresMacApproval(capabilities: string[], trustMode: string): boolean {
  return queuedAgentGrantRequiresLocalAuthProof(capabilities, trustMode);
}

function queuedAgentGrantDeliveryRequiresMacApproval(
  capabilities: string[],
  trustMode: string,
  deliveryMode: string,
): boolean {
  if (deliveryMode === "live") return false;
  return queuedAgentGrantRequiresMacApproval(capabilities, trustMode);
}

function parseAgentGrantLocalAuthProof(raw: unknown): AgentGrantLocalAuthProof | undefined {
  if (raw == null) return undefined;
  const record = recordOrUndefined(raw);
  if (!record) {
    throw new HttpsError("invalid-argument", "localAuthProof is invalid.");
  }
  const proofId = boundedFirestoreDocumentId(record.proofId, "localAuthProof.proofId", 160);
  const deviceId = boundedFirestoreDocumentId(record.deviceId, "localAuthProof.deviceId", 160);
  const signedIntentHash = boundedTrimmedString(record.signedIntentHash, "localAuthProof.signedIntentHash", 64, true).toLowerCase();
  const authenticatedAt =
    typeof record.authenticatedAt === "number" ? record.authenticatedAt : Number(record.authenticatedAt);
  const expiresAt = typeof record.expiresAt === "number" ? record.expiresAt : Number(record.expiresAt);
  const signatureEd25519 = requireBase64Like(record.signatureEd25519, "localAuthProof.signatureEd25519", 32, 256);
  if (!/^[a-f0-9]{64}$/u.test(signedIntentHash) || !Number.isFinite(authenticatedAt) || !Number.isFinite(expiresAt)) {
    throw new HttpsError("invalid-argument", "localAuthProof is invalid.");
  }
  return {
    proofId,
    deviceId,
    signedIntentHash,
    authenticatedAt,
    expiresAt,
    signatureEd25519,
  };
}

function verifyAgentGrantLocalAuthProof(
  proof: AgentGrantLocalAuthProof,
  options: {
    sourceDeviceId: string;
    observedIntentHashHex: string;
    nowReferenceSeconds: number;
    authorityPublicKey: Buffer;
  },
): "ok" | "wrong_device" | "wrong_intent" | "expired" | "future" | "too_long" | "bad_signature" {
  if (proof.deviceId !== options.sourceDeviceId) return "wrong_device";
  if (proof.signedIntentHash !== options.observedIntentHashHex.toLowerCase()) return "wrong_intent";
  if (proof.authenticatedAt > options.nowReferenceSeconds + LOCAL_AUTH_PROOF_CLOCK_SKEW_SECONDS) return "future";
  if (proof.expiresAt <= options.nowReferenceSeconds) return "expired";
  if (
    proof.expiresAt <= proof.authenticatedAt ||
    proof.expiresAt - proof.authenticatedAt > LOCAL_AUTH_PROOF_FRESHNESS_SECONDS ||
    options.nowReferenceSeconds - proof.authenticatedAt > LOCAL_AUTH_PROOF_FRESHNESS_SECONDS
  ) {
    return "too_long";
  }
  const payload = agentGrantLocalAuthProofSignablePayload(proof);
  return verifyEd25519RawSignature(options.authorityPublicKey, payload, proof.signatureEd25519) ? "ok" : "bad_signature";
}

async function appendComputerUseAuditEvent(
  uid: string,
  event: Record<string, unknown>,
): Promise<void> {
  await db.collection(`users/${uid}/computer_use_audit_events`).add({
    ...event,
    observedAt: FieldValue.serverTimestamp(),
    schemaVersion: 1,
    eventId: `${Date.now()}_${randomBytes(6).toString("hex")}`,
  });
}

function normalizedStringList(raw: unknown, name: string, maxItems: number, allowed: Set<string>): string[] {
  if (!Array.isArray(raw) || raw.length > maxItems) {
    throw new HttpsError("invalid-argument", `${name} is invalid.`);
  }
  const values = raw.map((item, index) => boundedTrimmedString(item, `${name}[${index}]`, 80, true));
  const unique = Array.from(new Set(values)).sort();
  for (const value of unique) {
    if (!allowed.has(value)) throw new HttpsError("invalid-argument", `${name} contains an unsupported value.`);
  }
  return unique;
}

function sameStringList(left: string[], right: string[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

/**
 * Decide whether an escrow device's stored `publicKeyFingerprint` is provably
 * bound to its real public-key bytes. Pure + side-effect-free so it is unit
 * tested without Firestore.
 *
 * - No public key on file → `missing_public_key` (ok; nothing to enforce yet —
 *   the device hasn't published key bytes the server can bind to).
 * - Public key present but no/blank stored fingerprint → `missing_fingerprint`
 *   (fail closed: a key with no fingerprint cannot be matched).
 * - Public key present but malformed → `invalid_public_key` (fail closed).
 * - Fingerprints compared with `timingSafeEqual` over the raw digest bytes —
 *   strict equality, no early-out, fail closed on any decode error.
 */
function evaluateEscrowFingerprintBinding(
  storedFingerprint: unknown,
  publicKeyDataBase64: unknown,
): EscrowFingerprintCheck {
  const hasKeyField = typeof publicKeyDataBase64 === "string" && publicKeyDataBase64.trim().length > 0;
  if (!hasKeyField) {
    return { ok: true, reason: "missing_public_key" };
  }
  const recomputed = recomputeEscrowFingerprint(publicKeyDataBase64);
  if (!recomputed) {
    return { ok: false, reason: "invalid_public_key" };
  }
  if (typeof storedFingerprint !== "string" || storedFingerprint.trim().length === 0) {
    return { ok: false, reason: "missing_fingerprint" };
  }
  const storedBytes = Buffer.from(storedFingerprint.trim(), "base64");
  const recomputedBytes = Buffer.from(recomputed, "base64");
  if (storedBytes.length === 0 || storedBytes.length !== recomputedBytes.length) {
    return { ok: false, reason: "fingerprint_mismatch" };
  }
  return timingSafeEqual(storedBytes, recomputedBytes)
    ? { ok: true, reason: "match" }
    : { ok: false, reason: "fingerprint_mismatch" };
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

export const issueHighRiskActionNonce = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("issueHighRiskActionNonce", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before requesting a high-risk action nonce.");
    enforceHighRiskComputerUseCallable(request, uid);
    const { nonce, expiresAtMillis } = await issueHighRiskNonceForUid(uid);
    return { ok: true, nonce, expiresAtMillis };
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
        nonce?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before registering an escrow device.");
      await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

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
    async (
      request: CallableRequest<{
        deviceId?: unknown;
        approverDeviceId?: unknown;
        nonce?: unknown;
        trustChain?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before approving device trust.");
      await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
      const approverDeviceId = boundedTrimmedString(request.data.approverDeviceId, "approverDeviceId", 160, false);
      const trustChain = parseCloudVaultDeviceTrustChainProof(request.data.trustChain);
      const ref = db.doc(`users/${uid}/escrow_devices/${deviceId}`);
      const result = await db.runTransaction(async (transaction) => {
        const snapshot = await transaction.get(ref);
        if (!snapshot.exists) {
          throw new HttpsError("not-found", "Escrow device is not registered.");
        }
        const platform = snapshot.get("platform");
        const trustState = snapshot.get("trustState");
        if (trustState === "trusted") {
          const approvedByDeviceId = snapshot.get("approvedByDeviceId");
          return { alreadyTrusted: true, approvedByDeviceId: typeof approvedByDeviceId === "string" ? approvedByDeviceId : undefined };
        }
        if (trustState === "revoked") {
          throw new HttpsError("failed-precondition", "Revoked escrow devices must be re-registered before approval.");
        }
        if (platform !== ESCROW_WEB_PLATFORM && !isNativeEscrowPlatform(platform)) {
          throw new HttpsError("failed-precondition", "Escrow device platform is invalid.");
        }

        // Stream 6: bind approval to the device's REAL public key. Recompute the
        // fingerprint from the stored x9.63 key bytes and require it to match the
        // device doc's `publicKeyFingerprint`. Reads the current-version key doc
        // inside the transaction so a concurrent key swap can't slip past.
        const storedFingerprint = snapshot.get("publicKeyFingerprint");
        const rawKeyVersion = snapshot.get("keyVersion");
        const keyVersion = typeof rawKeyVersion === "number" && Number.isInteger(rawKeyVersion) ? rawKeyVersion : 1;
        const publicKeyRef = db.doc(`users/${uid}/escrow_public_keys/${deviceId}_${keyVersion}`);
        const publicKeySnap = await transaction.get(publicKeyRef);
        const publicKeyData = publicKeySnap.exists ? publicKeySnap.get("publicKeyData") : undefined;
        const fingerprintCheck = evaluateEscrowFingerprintBinding(storedFingerprint, publicKeyData);
        if (!fingerprintCheck.ok) {
          // Inert until activation: when the capability is OFF, never block an
          // approval that would otherwise succeed — only record the would-be
          // rejection so activation can be validated against real traffic. When
          // ON, fail closed (default-deny) on any unbound / malformed key.
          logInfo({
            event: "callable_info",
            message: "escrow_device_fingerprint_binding_failed",
            device_id: deviceId,
            reason: fingerprintCheck.reason,
            enforced: ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED,
          });
          if (ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED) {
            throw new HttpsError(
              "failed-precondition",
              "Escrow device public-key fingerprint does not match its key. Re-register the device.",
            );
          }
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

        const targetEscrowFingerprint = typeof storedFingerprint === "string" ? storedFingerprint : undefined;
        if (!targetEscrowFingerprint) {
          throw new HttpsError("failed-precondition", "Escrow device is missing a key fingerprint.");
        }
        const targetSignalIdentityKeyId = `${deviceId}_${keyVersion}`;
        if (
          trustChain.targetSignalIdentityKeyId !== targetSignalIdentityKeyId ||
          trustChain.targetSignalIdentityPublicKeyFingerprint.length === 0
        ) {
          throw new HttpsError("permission-denied", "Trust-chain target identity does not match the escrow device.");
        }
        const targetIdentityRef = db.doc(`users/${uid}/signal_identity_public_keys/${targetSignalIdentityKeyId}`);
        const targetIdentitySnap = await transaction.get(targetIdentityRef);
        if (
          !targetIdentitySnap.exists ||
          targetIdentitySnap.get("deviceId") !== deviceId ||
          targetIdentitySnap.get("identityKeyId") !== targetSignalIdentityKeyId ||
          targetIdentitySnap.get("keyVersion") !== keyVersion ||
          targetIdentitySnap.get("publicKeyFingerprint") !== trustChain.targetSignalIdentityPublicKeyFingerprint
        ) {
          throw new HttpsError("failed-precondition", "Trust-chain target Signal identity is not published.");
        }

        const isBootstrapSelfApproval = trustedNativeDevices.empty && approvedByDeviceId === deviceId;
        const approverRef = db.doc(`users/${uid}/escrow_devices/${approvedByDeviceId}`);
        const approverSnap = approvedByDeviceId === deviceId ? snapshot : await transaction.get(approverRef);
        const approverPlatform = approverSnap.exists ? approverSnap.get("platform") : undefined;
        const approverState = approverSnap.exists ? approverSnap.get("trustState") : undefined;
        if (
          !approverSnap.exists ||
          !isNativeEscrowPlatform(approverPlatform) ||
          (!isBootstrapSelfApproval && approverState !== "trusted")
        ) {
          throw new HttpsError("permission-denied", "Trust-chain approver must be a trusted native device.");
        }
        const rawApproverKeyVersion = approverSnap.get("keyVersion");
        const approverKeyVersion =
          typeof rawApproverKeyVersion === "number" && Number.isInteger(rawApproverKeyVersion) ? rawApproverKeyVersion : 1;
        const approverSignalIdentityKeyId = `${approvedByDeviceId}_${approverKeyVersion}`;
        if (trustChain.approverSignalIdentityKeyId !== approverSignalIdentityKeyId) {
          throw new HttpsError("permission-denied", "Trust-chain approver identity does not match the approver device.");
        }
        const approverIdentityRef = db.doc(`users/${uid}/signal_identity_public_keys/${approverSignalIdentityKeyId}`);
        const approverIdentitySnap =
          approverSignalIdentityKeyId === targetSignalIdentityKeyId ? targetIdentitySnap : await transaction.get(approverIdentityRef);
        if (
          !approverIdentitySnap.exists ||
          approverIdentitySnap.get("deviceId") !== approvedByDeviceId ||
          approverIdentitySnap.get("identityKeyId") !== approverSignalIdentityKeyId ||
          approverIdentitySnap.get("keyVersion") !== approverKeyVersion ||
          approverIdentitySnap.get("publicKeyFingerprint") !== trustChain.approverSignalIdentityPublicKeyFingerprint
        ) {
          throw new HttpsError("failed-precondition", "Trust-chain approver Signal identity is not published.");
        }

        transaction.set(
          ref,
          {
            trustState: "trusted",
            approvedAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
            approvedByDeviceId,
            trustChainVersion: trustChain.version,
            trustChainAlgorithm: trustChain.algorithm,
            trustChainSignature: trustChain.signature,
            targetSignalIdentityKeyId: trustChain.targetSignalIdentityKeyId,
            targetSignalIdentityPublicKeyFingerprint: trustChain.targetSignalIdentityPublicKeyFingerprint,
            approvedBySignalIdentityKeyId: trustChain.approverSignalIdentityKeyId,
            approvedBySignalIdentityPublicKeyFingerprint: trustChain.approverSignalIdentityPublicKeyFingerprint,
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
  wrapCallableHandler(
    "revokeEscrowDeviceTrust",
    async (request: CallableRequest<{ deviceId?: unknown; nonce?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before revoking device trust.");
      await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

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

      // L41: also retire the device's Signal session-directory entries (sessions
      // it owns + sessions where it is the peer). Best-effort — a failure here
      // must NOT block the trust revocation itself, which already succeeded.
      let revokedSignalSessions = 0;
      let signalSessionRevokeFailed = false;
      try {
        revokedSignalSessions = await revokeSignalSessionsForDevice(uid, deviceId);
      } catch (err) {
        // The trust flip already committed and stands. Signal session cleanup is
        // a separate best-effort step; surface its failure to the caller
        // (signalSessionRevokeFailed) instead of masking it behind ok:true, and
        // log at WARN so it reaches alerting (revokedSignalSessions stays 0 =
        // "failed/unknown", not "no sessions existed").
        signalSessionRevokeFailed = true;
        logWarn({
          event: "escrow_device_signal_session_revoke_failed",
          device_id: deviceId,
          error: String(err),
        });
      }

      logInfo({
        event: "callable_info",
        message: "escrow_device_trust_revoked",
        device_id: deviceId,
        revoked_grants: grants.size,
        revoked_signal_sessions: revokedSignalSessions,
        signal_session_revoke_failed: signalSessionRevokeFailed,
      });
      return {
        ok: true,
        deviceId,
        trustState: "revoked",
        revokedGrants: grants.size,
        revokedSignalSessions,
        signalSessionRevokeFailed,
      };
    },
  ),
);

export const publishIrohPairingPublicKey = onCallProduction(
  "publishIrohPairingPublicKey",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      deviceId?: unknown;
      roleId?: unknown;
      publicKeyBase64?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before publishing an iroh pairing key.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    const roleId = boundedTrimmedString(request.data.roleId ?? "host", "roleId", 32, true);
    if (roleId !== "host") {
      throw new HttpsError("invalid-argument", "Only the host iroh pairing key role is client-publishable.");
    }
    await requireTrustedEscrowDevice(uid, deviceId, MAC_ESCROW_PLATFORMS);
    const publicKeyBase64 = requireBase64Like(request.data.publicKeyBase64, "publicKeyBase64", 32, 128);

    await db.doc(`users/${uid}/iroh_pairing_keys/${roleId}`).set(
      {
        id: roleId,
        publicKeyBase64,
        publishedAtMillis: Date.now(),
        publishedByDeviceId: deviceId,
        protocolVersion: 1,
        schemaVersion: 2,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    logInfo({
      event: "callable_info",
      message: "iroh_pairing_public_key_published",
      role_id: roleId,
      device_id: deviceId,
    });
    return { ok: true, roleId };
  },
);

export const publishIrohPairingRecord = onCallProduction(
  "publishIrohPairingRecord",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      deviceId?: unknown;
      connectionId?: unknown;
      nodeId?: unknown;
      relayURL?: unknown;
      directAddresses?: unknown;
      publishedAtMillis?: unknown;
      protocolVersion?: unknown;
      signature?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before publishing an iroh pairing record.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    await requireTrustedEscrowDevice(uid, deviceId, MAC_ESCROW_PLATFORMS);
    const connectionId = boundedTrimmedString(request.data.connectionId, "connectionId", 160, true);
    const nodeId = boundedTrimmedString(request.data.nodeId, "nodeId", 128, true);
    const relayURLRaw = request.data.relayURL == null ? undefined : boundedTrimmedString(request.data.relayURL, "relayURL", 512, false);
    const relayURL = relayURLRaw && relayURLRaw.length > 0 ? relayURLRaw : undefined;
    const directAddresses = boundedStringArray(request.data.directAddresses, "directAddresses", 16, 512);
    const publishedAtMillis = boundedInteger(request.data.publishedAtMillis, "publishedAtMillis", 1, Number.MAX_SAFE_INTEGER, true) ?? Date.now();
    const protocolVersion = boundedInteger(request.data.protocolVersion, "protocolVersion", 1, 100, true) ?? 1;
    const signature = requireBase64Like(request.data.signature, "signature", 32, 256);

    const ref = db.doc(`users/${uid}/iroh_pairing/${connectionId}`);
    await db.runTransaction(async (transaction) => {
      const existing = await transaction.get(ref);
      const createdAt = existing.exists && existing.get("createdAt") != null ? existing.get("createdAt") : FieldValue.serverTimestamp();
      const payload: Record<string, unknown> = {
        id: connectionId,
        nodeId,
        directAddresses,
        publishedAtMillis,
        protocolVersion,
        signature,
        publishedByDeviceId: deviceId,
        createdAt,
        updatedAt: FieldValue.serverTimestamp(),
        schemaVersion: 2,
      };
      if (relayURL) payload.relayURL = relayURL;
      transaction.set(
        ref,
        payload,
        { merge: true },
      );
    });
	    logInfo({
      event: "callable_info",
      message: "iroh_pairing_record_published",
      connection_id: connectionId,
      device_id: deviceId,
    });
    return { ok: true, connectionId };
  },
);

export const revokeIrohPairingRecord = onCallProduction(
  "revokeIrohPairingRecord",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request: CallableRequest<{ deviceId?: unknown; connectionId?: unknown; nonce?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before revoking an iroh pairing record.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    const connectionId = boundedTrimmedString(request.data.connectionId, "connectionId", 160, true);
    await requireTrustedEscrowDevice(uid, deviceId, MAC_ESCROW_PLATFORMS);
    await db.doc(`users/${uid}/iroh_pairing/${connectionId}`).delete();

    logInfo({
      event: "callable_info",
      message: "iroh_pairing_record_revoked",
      connection_id: connectionId,
      device_id: deviceId,
    });
    return { ok: true, connectionId };
  },
);

export const publishPhoneControlAuthority = onCallProduction(
  "publishPhoneControlAuthority",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      deviceId?: unknown;
      connectionId?: unknown;
      peerNodeId?: unknown;
      publicKeyBase64?: unknown;
      publishedAtMillis?: unknown;
      protocolVersion?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before publishing phone-control authority.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    await requireTrustedEscrowDevice(uid, deviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
    const connectionId = boundedTrimmedString(request.data.connectionId, "connectionId", 160, true);
    const peerNodeId = boundedTrimmedString(request.data.peerNodeId, "peerNodeId", 160, true);
    const publicKeyBase64 = requireBase64Like(request.data.publicKeyBase64, "publicKeyBase64", 32, 128);
    const publicKeyBytes = requireExactBase64Bytes(publicKeyBase64, "publicKeyBase64", ED25519_PUBLIC_KEY_BYTE_LENGTH);
    requireDerivedPhoneControlPeerNodeId(peerNodeId, publicKeyBytes);
    const publishedAtMillis = requireFreshPublicationMillis(request.data.publishedAtMillis, "publishedAtMillis");
    const protocolVersion = boundedInteger(request.data.protocolVersion ?? 1, "protocolVersion", 1, 100, true) ?? 1;

    const pairing = await db.doc(`users/${uid}/iroh_pairing/${connectionId}`).get();
    if (!pairing.exists) {
      throw new HttpsError("failed-precondition", "Phone-control authority must reference an existing iroh pairing.");
    }

    await db.doc(`users/${uid}/iroh_pairing/${connectionId}/controllers/${peerNodeId}`).set(
      {
        id: peerNodeId,
        connectionId,
        peerNodeId,
        deviceId,
        publicKeyBase64,
        publishedAtMillis,
        protocolVersion,
        publishedByDeviceId: deviceId,
        schemaVersion: 2,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    logInfo({
      event: "callable_info",
      message: "phone_control_authority_published",
      connection_id: connectionId,
      peer_node_id: peerNodeId,
      device_id: deviceId,
    });
    return { ok: true, connectionId, peerNodeId };
  },
);

export const publishRelaySenderKey = onCallProduction(
  "publishRelaySenderKey",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      deviceId?: unknown;
      peerNodeId?: unknown;
      keyId?: unknown;
      publicKeyBase64?: unknown;
      relayKeyVersion?: unknown;
      publishedAtMillis?: unknown;
      signalIdentityKeyId?: unknown;
      signalIdentityKeyVersion?: unknown;
      signalIdentityPublicKeyFingerprint?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before publishing a relay sender key.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    await requireTrustedEscrowDevice(uid, deviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
    const peerNodeId = boundedTrimmedString(request.data.peerNodeId, "peerNodeId", 160, true);
    const keyId = boundedTrimmedString(request.data.keyId, "keyId", 128, true);
    if (!/^relay-v3-[a-f0-9]{24}$/u.test(keyId)) {
      throw new HttpsError("invalid-argument", "keyId must be a v3 relay sender key id.");
    }
    const relayKeyVersion =
      boundedInteger(request.data.relayKeyVersion, "relayKeyVersion", RELAY_AUTH_KEY_VERSION, RELAY_AUTH_KEY_VERSION, true) ??
      RELAY_AUTH_KEY_VERSION;
    const relaySenderKey = requireP256X963PublicKey(request.data.publicKeyBase64, "publicKeyBase64");
    const derivedKeyId = `relay-v3-${createHash("sha256").update(relaySenderKey.decoded).digest("hex").slice(0, 24)}`;
    if (keyId !== derivedKeyId) {
      throw new HttpsError("invalid-argument", "keyId does not match the relay sender key.");
    }
    const publishedAtMillis = requireFreshPublicationMillis(request.data.publishedAtMillis, "publishedAtMillis");
    const signalIdentityKeyId = boundedTrimmedString(request.data.signalIdentityKeyId, "signalIdentityKeyId", 200, true);
    const signalIdentityKeyVersion =
      boundedInteger(request.data.signalIdentityKeyVersion, "signalIdentityKeyVersion", 1, 100, true) ?? 1;
    const expectedSignalIdentityKeyId = `${deviceId}_${signalIdentityKeyVersion}`;
    if (signalIdentityKeyId !== expectedSignalIdentityKeyId) {
      throw new HttpsError("permission-denied", "Relay sender key must bind to this device's current Signal identity.");
    }
    const signalIdentityPublicKeyFingerprint = boundedTrimmedString(
      request.data.signalIdentityPublicKeyFingerprint,
      "signalIdentityPublicKeyFingerprint",
      128,
      true,
    );

    const [identity, device] = await Promise.all([
      db.doc(`users/${uid}/signal_identity_public_keys/${signalIdentityKeyId}`).get(),
      db.doc(`users/${uid}/escrow_devices/${deviceId}`).get(),
    ]);
    if (
      !identity.exists ||
      identity.get("deviceId") !== deviceId ||
      identity.get("identityKeyId") !== signalIdentityKeyId ||
      identity.get("publicKeyFingerprint") !== signalIdentityPublicKeyFingerprint ||
      identity.get("keyVersion") !== signalIdentityKeyVersion
    ) {
      throw new HttpsError("permission-denied", "Relay sender key requires a published Signal identity for this trusted device.");
    }
    if (device.exists && device.get("peerNodeId") && device.get("peerNodeId") !== peerNodeId) {
      throw new HttpsError("permission-denied", "Relay sender peer node does not match the trusted device binding.");
    }

    await db.doc(`users/${uid}/relay_sender_keys/${deviceId}`).set(
      {
        deviceId,
        peerNodeId,
        keyId,
        publicKeyBase64: relaySenderKey.encoded,
        relayEncryption: RELAY_AUTH_ENCRYPTION,
        relayKeyVersion,
        status: "active",
        publishedAtMillis,
        publishedByDeviceId: deviceId,
        signalIdentityKeyId,
        signalIdentityKeyVersion,
        signalIdentityPublicKeyFingerprint,
        signalIdentityVerification: "verified",
        schemaVersion: 1,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    logInfo({
      event: "callable_info",
      message: "relay_sender_key_published",
      device_id: deviceId,
      peer_node_id: peerNodeId,
      key_id: keyId,
    });
    return { ok: true, deviceId, peerNodeId, keyId };
  },
);

export const publishAgentGrantAuthority = onCallProduction(
  "publishAgentGrantAuthority",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      deviceId?: unknown;
      peerNodeId?: unknown;
      publicKeyBase64?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before publishing an agent grant authority.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    await requireTrustedEscrowDevice(uid, deviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
    const peerNodeId = boundedTrimmedString(request.data.peerNodeId, "peerNodeId", 160, true);
    const publicKeyBytes = requireExactBase64Bytes(request.data.publicKeyBase64, "publicKeyBase64", ED25519_PUBLIC_KEY_BYTE_LENGTH);
    requireDerivedPhoneControlPeerNodeId(peerNodeId, publicKeyBytes);

    await db.doc(`users/${uid}/agent_grant_authorities/${deviceId}`).set(
      {
        sourceDeviceId: deviceId,
        peerNodeId,
        publicKeyBase64: publicKeyBytes.toString("base64"),
        publishedAtMillis: Date.now(),
        schemaVersion: 2,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    logInfo({
      event: "callable_info",
      message: "agent_grant_authority_published",
      device_id: deviceId,
      peer_node_id: peerNodeId,
    });
    return { ok: true, deviceId, peerNodeId };
  },
);

export const queueAgentCapabilityGrantRequest = onCallProduction(
  "queueAgentCapabilityGrantRequest",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      requestId?: unknown;
      runtime?: unknown;
      threadId?: unknown;
      preset?: unknown;
      capabilities?: unknown;
      trustMode?: unknown;
      deliveryMode?: unknown;
      requestedAt?: unknown;
      expiresAt?: unknown;
      grantDurationSeconds?: unknown;
      sourceDeviceId?: unknown;
      clientIntentId?: unknown;
      localAuthenticationSatisfied?: unknown;
      localAuthProof?: unknown;
      authority?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before queuing an agent grant request.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

    const allowedRuntimes = new Set([
      "hermes",
      "pi",
      "codex",
      "claude",
      "openclaw",
      "antigravity",
      "droid",
      "forge",
      "grok",
      "cursorAgent",
      "cursoragent",
      "cursor_agent",
    ]);
    const allowedCapabilities = new Set([
      "desktop_browser",
      "desktop_screenshot",
      "accessibility_inspect",
      "desktop_system_input",
      "workspace_read",
      "workspace_write",
      "shell",
      "desktop_file_export",
      "shell_unrestricted",
    ]);
    const requestId = boundedTrimmedString(request.data.requestId, "requestId", 160, true);
    const runtime = boundedTrimmedString(request.data.runtime, "runtime", 80, true);
    if (!allowedRuntimes.has(runtime)) throw new HttpsError("invalid-argument", "Unsupported runtime.");
    const threadId = boundedTrimmedString(request.data.threadId, "threadId", 240, true);
    const preset = boundedTrimmedString(request.data.preset, "preset", 32, true);
    const capabilities = normalizedStringList(request.data.capabilities, "capabilities", 16, allowedCapabilities);
    const expectedCapabilities = grantPresetCapabilities(preset);
    const trustMode = boundedTrimmedString(request.data.trustMode, "trustMode", 32, true);
    if (!sameStringList(capabilities, expectedCapabilities) || trustMode !== grantPresetTrustMode(preset)) {
      throw new HttpsError("permission-denied", "grant_preset_mismatch");
    }
    const localAuthProofRequired = queuedAgentGrantRequiresLocalAuthProof(capabilities, trustMode);
    const localAuthProof = parseAgentGrantLocalAuthProof(request.data.localAuthProof);
    const deliveryMode = boundedTrimmedString(request.data.deliveryMode, "deliveryMode", 32, true);
    if (!["live", "queued", "live_then_queued"].includes(deliveryMode)) {
      throw new HttpsError("invalid-argument", "Unsupported delivery mode.");
    }
    if (queuedAgentGrantDeliveryRequiresMacApproval(capabilities, trustMode, deliveryMode)) {
      throw new HttpsError("failed-precondition", "mac_approval_required");
    }
    const requestedAt = typeof request.data.requestedAt === "number" ? request.data.requestedAt : Number(request.data.requestedAt);
    const expiresAt = typeof request.data.expiresAt === "number" ? request.data.expiresAt : Number(request.data.expiresAt);
    const grantDurationSeconds =
      typeof request.data.grantDurationSeconds === "number"
        ? request.data.grantDurationSeconds
        : Number(request.data.grantDurationSeconds);
    if (
      !Number.isFinite(requestedAt) ||
      !Number.isFinite(expiresAt) ||
      expiresAt <= requestedAt ||
      !Number.isFinite(grantDurationSeconds) ||
      grantDurationSeconds <= 0 ||
      grantDurationSeconds > 86400
    ) {
      throw new HttpsError("invalid-argument", "Grant request timing is invalid.");
    }
    const nowReferenceSeconds = cocoaReferenceSecondsNow();
    if (nowReferenceSeconds - requestedAt > 5 * 60 || expiresAt < nowReferenceSeconds) {
      throw new HttpsError("failed-precondition", "Grant request is stale.");
    }
    const sourceDeviceId = boundedTrimmedString(request.data.sourceDeviceId, "sourceDeviceId", 160, true);
    await requireTrustedEscrowDevice(uid, sourceDeviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
    const clientIntentId = boundedTrimmedString(request.data.clientIntentId, "clientIntentId", 160, true);
    if (typeof request.data.localAuthenticationSatisfied !== "boolean") {
      throw new HttpsError("invalid-argument", "localAuthenticationSatisfied must be boolean.");
    }
    const localAuthenticationSatisfied = request.data.localAuthenticationSatisfied;
    if ((localAuthProofRequired || localAuthProof) && localAuthenticationSatisfied !== true) {
      await appendComputerUseAuditEvent(uid, {
        eventType: "agent_grant.local_auth_proof.reject",
        reason: "local_authentication_required",
        requestId,
        sourceDeviceId,
        preset,
      }).catch((error) => logWarn({ event: "audit_write_failed", message: "local_auth_proof_reject", error }));
      throw new HttpsError("permission-denied", "Risky grants require fresh device authentication.");
    }
    if (localAuthProofRequired && !localAuthProof) {
      await appendComputerUseAuditEvent(uid, {
        eventType: "agent_grant.local_auth_proof.reject",
        reason: "missing_proof",
        requestId,
        sourceDeviceId,
        preset,
      }).catch((error) => logWarn({ event: "audit_write_failed", message: "local_auth_proof_missing", error }));
      throw new HttpsError("permission-denied", "Risky grants require a local-auth proof.");
    }

    const authority = recordOrUndefined(request.data.authority);
    if (!authority) {
      throw new HttpsError("invalid-argument", "authority is required.");
    }
    const authorityPeerNodeId = boundedTrimmedString(authority.peerNodeId, "authority.peerNodeId", 160, true);
    const authorityCounter = boundedInteger(authority.counter, "authority.counter", 0, Number.MAX_SAFE_INTEGER, true);
    const authorityTimestamp = typeof authority.timestamp === "number" ? authority.timestamp : Number(authority.timestamp);
    const intentHashBlake3 = boundedTrimmedString(authority.intentHashBlake3, "authority.intentHashBlake3", 64, true);
    const signatureEd25519 = requireBase64Like(authority.signatureEd25519, "authority.signatureEd25519", 32, 256);
    if (authorityCounter == null || !Number.isFinite(authorityTimestamp) || !/^[a-fA-F0-9]{64}$/u.test(intentHashBlake3)) {
      throw new HttpsError("invalid-argument", "authority is invalid.");
    }
    if (Math.abs(nowReferenceSeconds - authorityTimestamp) > AGENT_GRANT_AUTHORITY_FRESHNESS_SECONDS) {
      throw new HttpsError("failed-precondition", "Grant request authority is stale.");
    }

    const grantRequest = {
      requestId,
      runtime,
      threadId,
      preset,
      capabilities,
      trustMode,
      deliveryMode,
      requestedAt,
      expiresAt,
      grantDurationSeconds,
      sourceDeviceId,
      clientIntentId,
      localAuthenticationSatisfied,
    };
    const observedIntentHashHex = agentGrantRequestHashHex(grantRequest);
    if (observedIntentHashHex.toLowerCase() !== intentHashBlake3.toLowerCase()) {
      throw new HttpsError("permission-denied", "Agent grant authority hash does not match the request.");
    }

    const authorityRef = db.doc(`users/${uid}/agent_grant_authorities/${sourceDeviceId}`);
    const requestRef = db.doc(`users/${uid}/agent_capability_grant_requests/${requestId}`);
    const authoritySnapshot = await authorityRef.get();
    if (
      !authoritySnapshot.exists ||
      authoritySnapshot.get("peerNodeId") !== authorityPeerNodeId ||
      typeof authoritySnapshot.get("publicKeyBase64") !== "string"
    ) {
      throw new HttpsError("permission-denied", "Agent grant authority is not trusted for this device.");
    }
    const authorityPublicKey = requireExactBase64Bytes(
      authoritySnapshot.get("publicKeyBase64"),
      "agentGrantAuthority.publicKeyBase64",
      ED25519_PUBLIC_KEY_BYTE_LENGTH,
    );
	    const signablePayload = agentGrantAuthoritySignablePayload(intentHashBlake3.toLowerCase(), authorityCounter, authorityTimestamp);
	    if (!verifyEd25519RawSignature(authorityPublicKey, signablePayload, signatureEd25519)) {
	      throw new HttpsError("permission-denied", "Agent grant authority signature is invalid.");
	    }
	    if (localAuthProof) {
	      const proofStatus = verifyAgentGrantLocalAuthProof(localAuthProof, {
	        sourceDeviceId,
	        observedIntentHashHex,
	        nowReferenceSeconds,
	        authorityPublicKey,
	      });
	      if (proofStatus !== "ok") {
	        await appendComputerUseAuditEvent(uid, {
	          eventType: "agent_grant.local_auth_proof.reject",
	          reason: proofStatus,
	          proofId: localAuthProof.proofId,
	          requestId,
	          sourceDeviceId,
	          preset,
	        }).catch((error) => logWarn({ event: "audit_write_failed", message: "local_auth_proof_reject", error }));
	        throw new HttpsError("permission-denied", `local_auth_proof_${proofStatus}`);
	      }
	    }

	    const payload = {
	      ...grantRequest,
	      ...(localAuthProof
	        ? {
	            localAuthProof: {
	              proofId: localAuthProof.proofId,
	              deviceId: localAuthProof.deviceId,
	              signedIntentHash: localAuthProof.signedIntentHash,
	              authenticatedAt: localAuthProof.authenticatedAt,
	              expiresAt: localAuthProof.expiresAt,
	              signatureEd25519: localAuthProof.signatureEd25519,
	            },
	            localAuthProofVerifiedAt: FieldValue.serverTimestamp(),
	          }
	        : {}),
	      authority: {
        peerNodeId: authorityPeerNodeId,
        counter: authorityCounter,
        timestamp: authorityTimestamp,
        intentHashBlake3,
        signatureEd25519,
      },
      status: "queued",
      canonicalRequestHashSha256: observedIntentHashHex,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
	    };
	    await db.runTransaction(async (transaction) => {
	      const proofRef = localAuthProof ? db.doc(`users/${uid}/local_auth_proofs/${localAuthProof.proofId}`) : undefined;
	      const [freshAuthority, existingRequest, proofSnapshot] = await Promise.all([
	        transaction.get(authorityRef),
	        transaction.get(requestRef),
	        proofRef ? transaction.get(proofRef) : Promise.resolve(undefined),
	      ]);
	      if (existingRequest.exists) {
	        throw new HttpsError("already-exists", "Agent grant request is already queued.");
	      }
      if (
        !freshAuthority.exists ||
        freshAuthority.get("peerNodeId") !== authorityPeerNodeId ||
        freshAuthority.get("publicKeyBase64") !== authorityPublicKey.toString("base64")
      ) {
        throw new HttpsError("permission-denied", "Agent grant authority changed before the request could be queued.");
      }
      const lastQueuedCounter = freshAuthority.get("lastQueuedCounter");
	      if (typeof lastQueuedCounter === "number" && authorityCounter <= lastQueuedCounter) {
	        throw new HttpsError("permission-denied", "Agent grant authority counter replay.");
	      }
		      if (proofSnapshot?.exists) {
		        throw new HttpsError("permission-denied", "local_auth_proof_replay");
		      }
	      transaction.create(requestRef, payload);
	      if (proofRef && localAuthProof) {
	        transaction.create(proofRef, {
	          proofId: localAuthProof.proofId,
	          requestId,
	          sourceDeviceId,
	          signedIntentHash: localAuthProof.signedIntentHash,
	          authenticatedAt: localAuthProof.authenticatedAt,
	          expiresAt: localAuthProof.expiresAt,
	          consumedAt: FieldValue.serverTimestamp(),
	          status: "consumed",
	          schemaVersion: 1,
	        });
	      }
	      transaction.set(
        authorityRef,
        {
          lastQueuedCounter: authorityCounter,
          lastQueuedAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    });

	    if (localAuthProof) {
	      await appendComputerUseAuditEvent(uid, {
	        eventType: "agent_grant.local_auth_proof.consume",
	        proofId: localAuthProof.proofId,
	        requestId,
	        sourceDeviceId,
	        signedIntentHash: localAuthProof.signedIntentHash,
	        preset,
	      }).catch((error) => logWarn({ event: "audit_write_failed", message: "local_auth_proof_consume", error }));
	    }

	    logInfo({
	      event: "callable_info",
	      message: "agent_capability_grant_request_queued",
      request_id: requestId,
      source_device_id: sourceDeviceId,
      preset,
    });
    return { ok: true, requestId, status: "queued" };
  },
);

const NATIVE_ESCROW_PLATFORMS = new Set(["macOS", "iOS", "iPadOS", "Android"]);

/**
 * Bind a CLI-agent mission approval to the responding device.
 *
 * The decision is written server-side (admin SDK bypasses Firestore rules) only
 * after confirming the responder is a TRUSTED NATIVE escrow device. This closes
 * the gap where any owner-authenticated client could flip `approvalStatus` to
 * `approved` by a bare Firestore write. Fail-closed.
 */
export const respondMissionApproval = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "respondMissionApproval",
    async (request: CallableRequest<{ requestId?: unknown; approve?: unknown; deviceId?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before responding to a mission approval.");
      enforceHighRiskComputerUseCallable(request, uid);

      const requestId = boundedTrimmedString(request.data.requestId, "requestId", 512, true);
      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
      if (typeof request.data.approve !== "boolean") {
        throw new HttpsError("invalid-argument", "approve must be a boolean.");
      }
      const approve = request.data.approve;

      const missionRef = db.doc(`users/${uid}/cli_agent_mission_requests/${requestId}`);
      const deviceRef = db.doc(`users/${uid}/escrow_devices/${deviceId}`);

      const result = await db.runTransaction(async (transaction) => {
        const [mission, device] = await Promise.all([transaction.get(missionRef), transaction.get(deviceRef)]);
        if (!mission.exists) {
          throw new HttpsError("not-found", "Mission request was not found.");
        }
        if (mission.get("status") !== "waiting_for_approval") {
          throw new HttpsError("failed-precondition", "Mission is not waiting for approval.");
        }
        const currentApproval = mission.get("approvalStatus");
        if (currentApproval && currentApproval !== "pending") {
          throw new HttpsError("failed-precondition", "Mission approval has already been resolved.");
        }
        if (
          !device.exists ||
          device.get("trustState") !== "trusted" ||
          !NATIVE_ESCROW_PLATFORMS.has(device.get("platform"))
        ) {
          throw new HttpsError(
            "permission-denied",
            "Mission approvals require a trusted native device. Trust this device first.",
          );
        }

        transaction.set(
          missionRef,
          {
            approvalStatus: approve ? "approved" : "rejected",
            approvalRespondedAt: FieldValue.serverTimestamp(),
            approvedByDeviceId: deviceId,
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
        return { approvalStatus: approve ? "approved" : "rejected" };
      });

      logInfo({
        event: "callable_info",
        message: "mission_approval_recorded",
        request_id: requestId,
        approved_by_device_id: deviceId,
        approval_status: result.approvalStatus,
      });
      return { ok: true, requestId, approvalStatus: result.approvalStatus, approvedByDeviceId: deviceId };
    },
  ),
);

/**
 * Test-only surface for the pure Stream 6 fingerprint-binding helpers (no
 * Firestore). The capability flag is exposed read-only so tests can assert it
 * ships OFF (inert) without flipping production behavior.
 */
export const __testing__ = {
  ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED,
  P256_X963_PUBLIC_KEY_BYTE_LENGTH,
  recomputeEscrowFingerprint,
  evaluateEscrowFingerprintBinding,
  canonicalAgentGrantRequestJSON,
  agentGrantRequestHashHex,
  agentGrantAuthoritySignablePayload,
  agentGrantLocalAuthProofSignablePayload,
  parseAgentGrantLocalAuthProof,
  verifyAgentGrantLocalAuthProof,
  queuedAgentGrantRequiresLocalAuthProof,
  queuedAgentGrantRequiresMacApproval,
  queuedAgentGrantDeliveryRequiresMacApproval,
  verifyEd25519RawSignature,
};
