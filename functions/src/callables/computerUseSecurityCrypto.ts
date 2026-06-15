/**
 * @fileoverview Computer Use / escrow crypto core — canonical signing-byte
 * builders, the LibSignal XEd25519 (XEdDSA over Curve25519) verifier, the
 * agent-grant request hashing + local-auth-proof logic, and the escrow
 * fingerprint-binding evaluator.
 *
 * Extracted verbatim from `computerUseSecurity.ts` (U6 split). Pure functions —
 * no Firestore / firebase-admin dependency.
 */

import { createHash, createPublicKey, timingSafeEqual, verify as verifySignature } from "node:crypto";

import { HttpsError } from "firebase-functions/v2/https";

import { recordOrUndefined } from "../guards.js";
import { boundedTrimmedString } from "./shared.js";
import {
  ED25519_SPKI_DER_PREFIX,
  LOCAL_AUTH_PROOF_CLOCK_SKEW_SECONDS,
  LOCAL_AUTH_PROOF_FRESHNESS_SECONDS,
  P256_X963_PUBLIC_KEY_BYTE_LENGTH,
  TRUSTED_DEVICE_ACTION_PROOF_DOMAIN,
  boundedFirestoreDocumentId,
  isPointOnP256Curve,
  normalizeBase64,
  requireBase64Like,
  verifyPhoneControlAuthoritySignature,
} from "./computerUseSecurityCodecs.js";

const COCOA_REFERENCE_UNIX_OFFSET_SECONDS = 978_307_200;

// Internal shapes relocated from the pre-split `computerUseSecurity.ts`. Kept
// non-exported (consumers derive via `ReturnType<>` of the parsers below) so the
// public type surface is unchanged by the split.
type AgentGrantLocalAuthProof = {
  proofId: string;
  deviceId: string;
  signedIntentHash: string;
  authenticatedAt: number;
  expiresAt: number;
  signatureEd25519: string;
};

type PhoneControlSigningKeyKind = Parameters<typeof verifyPhoneControlAuthoritySignature>[1];

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
export const ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED = true;

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
export function recomputeEscrowFingerprint(publicKeyDataBase64: unknown): string | null {
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

export function canonicalJSONQuote(value: string): string {
  return JSON.stringify(value);
}

export function canonicalJSONNumber(value: number): string {
  if (!Number.isFinite(value)) {
    throw new HttpsError("invalid-argument", "Signed grant request contains a non-finite number.");
  }
  if (Number.isInteger(value)) return String(value);
  return value.toFixed(12).replace(/(?:\.0+|(\.\d*?)0+)$/u, "$1");
}

export function canonicalAgentGrantRequestJSON(request: {
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

export function agentGrantRequestHashHex(request: Parameters<typeof canonicalAgentGrantRequestJSON>[0]): string {
  return createHash("sha256").update(canonicalAgentGrantRequestJSON(request)).digest("hex");
}

export function cocoaReferenceSecondsNow(): number {
  return Date.now() / 1000 - COCOA_REFERENCE_UNIX_OFFSET_SECONDS;
}

function cocoaReferenceSecondsToUnixMillis(referenceSeconds: number): bigint {
  return BigInt(Math.round((referenceSeconds + COCOA_REFERENCE_UNIX_OFFSET_SECONDS) * 1000));
}

export function agentGrantAuthoritySignablePayload(
  intentHashHex: string,
  counter: number,
  timestampReferenceSeconds: number,
): Buffer {
  const hashBytes = Buffer.from(intentHashHex, "utf8");
  const suffix = Buffer.alloc(16);
  suffix.writeBigUInt64BE(BigInt(counter), 0);
  suffix.writeBigInt64BE(cocoaReferenceSecondsToUnixMillis(timestampReferenceSeconds), 8);
  return Buffer.concat([hashBytes, suffix]);
}

export function agentGrantLocalAuthProofSignablePayload(
  proof: Pick<AgentGrantLocalAuthProof, "proofId" | "deviceId" | "signedIntentHash" | "authenticatedAt" | "expiresAt">,
): Buffer {
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

// ---------------------------------------------------------------------------
// LibSignal XEd25519 (XEdDSA over Curve25519) verification — server side.
//
// The CloudVault device-trust chain is signed with libsignal's
// `PrivateKey.generateSignature` (algorithm `"signal-identity-xeddsa-v1"`,
// CloudVaultDeviceTrustChain.swift:40,68) and the approver's public key is the
// 33-byte libsignal DJB serialization `0x05 || Montgomery-u(32)`. That is NOT a
// plain Ed25519-over-32-raw-bytes signature, so `verifyEd25519RawSignature`
// cannot validate it. We implement the XEdDSA verify per libsignal's own
// `curve25519::PrivateKey::verify_signature`
// (Vendor/libsignal/rust/core/src/curve/curve25519.rs:119-159):
//
//   1. Take the Montgomery-u public key, recover the Edwards point using the
//      sign bit carried in the HIGH bit of `signature[63]` (libsignal stores the
//      Edwards x sign bit there at curve25519.rs:115). "XEd25519 signatures are
//      valid Ed25519 signatures … provided the public keys are converted with
//      the birational map." (Vendor/.../examples/ed_to_xed.rs).
//   2. Clear the sign bit out of `s` (signature bytes 32..64) and reject if the
//      top three bits of `s[31]` are set (libsignal malleability guard,
//      curve25519.rs:136-139).
//   3. Standard Ed25519 verify of `R || s` against the recovered compressed
//      Edwards public key.
//
// This is proven byte-for-byte against vectors emitted by the real libsignal
// library (both sign-bit-0 and sign-bit-1 cases) in
// escrowDeviceTrustChainSignature.test.ts. Pure `node:crypto` — no new deps.
const CURVE25519_FIELD_PRIME = (1n << 255n) - 19n;
const ED25519_DJB_TYPE_BYTE = 0x05;
const SIGNAL_DJB_PUBLIC_KEY_BYTE_LENGTH = 33;

function curve25519FieldMod(value: bigint): bigint {
  const reduced = value % CURVE25519_FIELD_PRIME;
  return reduced < 0n ? reduced + CURVE25519_FIELD_PRIME : reduced;
}

function curve25519FieldPow(base: bigint, exponent: bigint): bigint {
  let result = 1n;
  let b = curve25519FieldMod(base);
  let e = exponent;
  while (e > 0n) {
    if (e & 1n) result = curve25519FieldMod(result * b);
    b = curve25519FieldMod(b * b);
    e >>= 1n;
  }
  return result;
}

function curve25519FieldInverse(value: bigint): bigint {
  return curve25519FieldPow(value, CURVE25519_FIELD_PRIME - 2n);
}

function littleEndianBytesToBigInt(buffer: Buffer): bigint {
  let result = 0n;
  for (let i = buffer.length - 1; i >= 0; i -= 1) {
    result = (result << 8n) | BigInt(buffer[i]);
  }
  return result;
}

function bigIntToLittleEndian32(value: bigint): Buffer {
  const out = Buffer.alloc(32);
  let x = curve25519FieldMod(value);
  for (let i = 0; i < 32; i += 1) {
    out[i] = Number(x & 0xffn);
    x >>= 8n;
  }
  return out;
}

/**
 * Convert a Montgomery-u Curve25519 public key (32 little-endian bytes) to the
 * compressed Edwards-Y form (32 bytes, Ed25519 wire form) with the supplied x
 * sign bit set in bit 255. Birational map `y = (u - 1) / (u + 1) mod p`. Returns
 * `null` when `u + 1 ≡ 0` (no Edwards image). Mirrors
 * `MontgomeryPoint::to_edwards` from curve25519-dalek as used by libsignal.
 */
export function montgomeryUToCompressedEdwards(montgomeryU: Buffer, edwardsXSignBit: number): Buffer | null {
  const u = curve25519FieldMod(littleEndianBytesToBigInt(montgomeryU));
  const denominator = curve25519FieldMod(u + 1n);
  if (denominator === 0n) return null;
  const y = curve25519FieldMod((u - 1n) * curve25519FieldInverse(denominator));
  const compressed = bigIntToLittleEndian32(y);
  if (edwardsXSignBit) {
    compressed[31] |= 0x80;
  } else {
    compressed[31] &= 0x7f;
  }
  return compressed;
}

/**
 * Verify a libsignal XEd25519 signature over `payload` against the approver's
 * 33-byte serialized DJB public key (`0x05 || Montgomery-u(32)`). Fails CLOSED
 * (returns false) on any length / encoding / curve / verify error.
 */
export function verifyXEdDSACurve25519Signature(
  serializedPublicKey33: Buffer,
  payload: Buffer,
  signature64: Buffer,
): boolean {
  if (
    serializedPublicKey33.length !== SIGNAL_DJB_PUBLIC_KEY_BYTE_LENGTH ||
    serializedPublicKey33[0] !== ED25519_DJB_TYPE_BYTE
  ) {
    return false;
  }
  if (signature64.length !== 64) return false;
  const montgomeryU = serializedPublicKey33.subarray(1);
  const edwardsXSignBit = (signature64[63] & 0x80) >> 7;

  // s = signature[32..64]; clear the borrowed sign bit (high bit of s[31]) and
  // reject non-canonical scalars (libsignal malleability guard).
  const scalarS = Buffer.from(signature64.subarray(32));
  scalarS[31] &= 0x7f;
  if ((scalarS[31] & 0xe0) !== 0) return false;

  const compressedEdwards = montgomeryUToCompressedEdwards(montgomeryU, edwardsXSignBit);
  if (!compressedEdwards) return false;

  // Standard Ed25519 signature is R || s (sign bit already cleared from s).
  const standardEd25519Signature = Buffer.concat([signature64.subarray(0, 32), scalarS]);
  let publicKey;
  try {
    publicKey = createPublicKey({
      key: Buffer.concat([ED25519_SPKI_DER_PREFIX, compressedEdwards]),
      format: "der",
      type: "spki",
    });
  } catch {
    return false;
  }
  try {
    return verifySignature(null, payload, publicKey, standardEd25519Signature);
  } catch {
    return false;
  }
}

/**
 * Reconstruct the EXACT canonical signing bytes the client produced in
 * `CloudVaultDeviceTrustChain.canonicalPayload`
 * (OpenBurnBarSignalCore/CloudVaultDeviceTrustChain.swift:43-61): a domain line
 * followed by nine length-prefixed `{utf8ByteCount}:{segment}\n` pairs (keys AND
 * values both prefixed by their UTF-8 byte count, NOT character count). Five of
 * the nine fields are sourced from authoritative server context; the four
 * Signal-identity id/fingerprint fields come from the validated proof.
 */
export const CLOUD_VAULT_DEVICE_TRUST_CHAIN_DOMAIN = "OpenBurnBar-CloudVault-DeviceTrust-v1";

export function buildCloudVaultDeviceTrustChainCanonicalBytes(fields: {
  uid: string;
  targetDeviceId: string;
  targetEscrowPublicKeyFingerprint: string;
  targetKeyVersion: number;
  targetSignalIdentityKeyId: string;
  targetSignalIdentityPublicKeyFingerprint: string;
  approverDeviceId: string;
  approverSignalIdentityKeyId: string;
  approverSignalIdentityPublicKeyFingerprint: string;
}): Buffer {
  const segments = [
    "uid",
    fields.uid,
    "targetDeviceId",
    fields.targetDeviceId,
    "targetEscrowPublicKeyFingerprint",
    fields.targetEscrowPublicKeyFingerprint,
    "targetKeyVersion",
    `${fields.targetKeyVersion}`,
    "targetSignalIdentityKeyId",
    fields.targetSignalIdentityKeyId,
    "targetSignalIdentityPublicKeyFingerprint",
    fields.targetSignalIdentityPublicKeyFingerprint,
    "approverDeviceId",
    fields.approverDeviceId,
    "approverSignalIdentityKeyId",
    fields.approverSignalIdentityKeyId,
    "approverSignalIdentityPublicKeyFingerprint",
    fields.approverSignalIdentityPublicKeyFingerprint,
  ];
  let canonical = `${CLOUD_VAULT_DEVICE_TRUST_CHAIN_DOMAIN}\n`;
  for (const segment of segments) {
    canonical += `${Buffer.byteLength(segment, "utf8")}:${segment}\n`;
  }
  return Buffer.from(canonical, "utf8");
}

/**
 * Verify the device-trust-chain signature against the approver's PUBLISHED
 * Signal identity key. Reconstructs the canonical bytes server-side, decodes the
 * 33-byte DJB key from `publicKeyData`, and runs XEdDSA verify. Fail CLOSED.
 */
export function verifyCloudVaultDeviceTrustChainSignature(args: {
  approverPublicKeyDataBase64: unknown;
  signatureBase64: string;
  canonicalFields: Parameters<typeof buildCloudVaultDeviceTrustChainCanonicalBytes>[0];
}): boolean {
  if (typeof args.approverPublicKeyDataBase64 !== "string") return false;
  const trimmedKey = args.approverPublicKeyDataBase64.trim();
  if (!trimmedKey) return false;
  const publicKey = Buffer.from(trimmedKey, "base64");
  // Reject lenient base64 / wrong length / wrong type byte; fail closed.
  if (
    publicKey.length !== SIGNAL_DJB_PUBLIC_KEY_BYTE_LENGTH ||
    publicKey[0] !== ED25519_DJB_TYPE_BYTE ||
    publicKey.toString("base64") !== normalizeBase64(trimmedKey)
  ) {
    return false;
  }
  const signature = Buffer.from(args.signatureBase64, "base64");
  if (signature.length !== 64 || signature.toString("base64") !== normalizeBase64(args.signatureBase64)) {
    return false;
  }
  const payload = buildCloudVaultDeviceTrustChainCanonicalBytes(args.canonicalFields);
  return verifyXEdDSACurve25519Signature(publicKey, payload, signature);
}

export function buildTrustedDeviceActionCanonicalBytes(fields: {
  uid: string;
  deviceId: string;
  actionKind: string;
  subjectId: string;
  approve: boolean;
  nonce: string;
  issuedAtMillis: number;
  deviceSignalIdentityKeyId: string;
  deviceSignalIdentityPublicKeyFingerprint: string;
}): Buffer {
  const segments = [
    "uid",
    fields.uid,
    "deviceId",
    fields.deviceId,
    "actionKind",
    fields.actionKind,
    "subjectId",
    fields.subjectId,
    "approve",
    fields.approve ? "true" : "false",
    "nonce",
    fields.nonce,
    "issuedAtMillis",
    `${fields.issuedAtMillis}`,
    "deviceSignalIdentityKeyId",
    fields.deviceSignalIdentityKeyId,
    "deviceSignalIdentityPublicKeyFingerprint",
    fields.deviceSignalIdentityPublicKeyFingerprint,
  ];
  let canonical = `${TRUSTED_DEVICE_ACTION_PROOF_DOMAIN}\n`;
  for (const segment of segments) {
    canonical += `${Buffer.byteLength(segment, "utf8")}:${segment}\n`;
  }
  return Buffer.from(canonical, "utf8");
}

export function verifyTrustedDeviceActionSignature(args: {
  publicKeyDataBase64: unknown;
  signatureBase64: string;
  canonicalFields: Parameters<typeof buildTrustedDeviceActionCanonicalBytes>[0];
}): boolean {
  if (typeof args.publicKeyDataBase64 !== "string") return false;
  const trimmedKey = args.publicKeyDataBase64.trim();
  if (!trimmedKey) return false;
  const publicKey = Buffer.from(trimmedKey, "base64");
  if (
    publicKey.length !== SIGNAL_DJB_PUBLIC_KEY_BYTE_LENGTH ||
    publicKey[0] !== ED25519_DJB_TYPE_BYTE ||
    publicKey.toString("base64") !== normalizeBase64(trimmedKey)
  ) {
    return false;
  }
  const signature = Buffer.from(args.signatureBase64, "base64");
  if (signature.length !== 64 || signature.toString("base64") !== normalizeBase64(args.signatureBase64)) {
    return false;
  }
  const payload = buildTrustedDeviceActionCanonicalBytes(args.canonicalFields);
  return verifyXEdDSACurve25519Signature(publicKey, payload, signature);
}

export function grantPresetCapabilities(preset: string): string[] {
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

export function grantPresetTrustMode(preset: string): string {
  return preset === "yolo" ? "trusted" : "manual";
}

export function queuedAgentGrantRequiresLocalAuthProof(capabilities: string[], trustMode: string): boolean {
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

export function queuedAgentGrantRequiresMacApproval(capabilities: string[], trustMode: string): boolean {
  return queuedAgentGrantRequiresLocalAuthProof(capabilities, trustMode);
}

export function queuedAgentGrantDeliveryRequiresMacApproval(
  capabilities: string[],
  trustMode: string,
  // F-RR04-004: deliveryMode must NOT affect the Mac approval gate. Risky capabilities
  // require Mac approval regardless of whether delivery is live, queued, or live_then_queued.
  // The _deliveryMode parameter is retained for signature compatibility but is intentionally
  // ignored — removing the original `if (deliveryMode === "live") return false` bypass.
  _deliveryMode: string,
): boolean {
  return queuedAgentGrantRequiresMacApproval(capabilities, trustMode);
}

export function parseAgentGrantLocalAuthProof(raw: unknown): AgentGrantLocalAuthProof | undefined {
  if (raw == null) return undefined;
  const record = recordOrUndefined(raw);
  if (!record) {
    throw new HttpsError("invalid-argument", "localAuthProof is invalid.");
  }
  const proofId = boundedFirestoreDocumentId(record.proofId, "localAuthProof.proofId", 160);
  const deviceId = boundedFirestoreDocumentId(record.deviceId, "localAuthProof.deviceId", 160);
  const signedIntentHash = boundedTrimmedString(
    record.signedIntentHash,
    "localAuthProof.signedIntentHash",
    64,
    true,
  ).toLowerCase();
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

export function verifyAgentGrantLocalAuthProof(
  proof: AgentGrantLocalAuthProof,
  options: {
    sourceDeviceId: string;
    observedIntentHashHex: string;
    nowReferenceSeconds: number;
    authorityPublicKey: Buffer;
    /// F2: the proof is signed with the same controller key as the authority
    /// envelope — verify with the matching algorithm (absent ⇒ legacy ed25519).
    authorityKeyKind?: PhoneControlSigningKeyKind;
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
  return verifyPhoneControlAuthoritySignature(
    options.authorityPublicKey,
    options.authorityKeyKind ?? "ed25519",
    payload,
    proof.signatureEd25519,
  )
    ? "ok"
    : "bad_signature";
}

export function normalizedStringList(raw: unknown, name: string, maxItems: number, allowed: Set<string>): string[] {
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

export function sameStringList(left: string[], right: string[]): boolean {
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
export function evaluateEscrowFingerprintBinding(
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
