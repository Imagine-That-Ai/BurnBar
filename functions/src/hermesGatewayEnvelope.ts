/**
 * @fileoverview BurnBar Cloud Hermes Gateway sealed-envelope contracts and pure
 * shape validators (relay v1/v2/v3, ratchet v1, official-libsignal v4). The
 * server is a BLIND store-and-forward: every validator checks the envelope SHAPE
 * only and never decrypts. Split out of hermesGateway.ts (max-lines); the
 * original module re-exports every symbol here so existing imports resolve
 * byte-identically.
 */

import { HttpsError } from "firebase-functions/v2/https";
import {
  SIGNAL_AT_REST_ENCRYPTION,
  SIGNAL_ENVELOPE_FORMAT_VERSION,
  SIGNAL_RELAY_KEY_VERSION,
  SIGNAL_TRANSPORT_ENCRYPTION,
  sanitizeSignalEnvelope,
  type SignalEnvelope,
  type SignalEnvelopeMode,
} from "@openburnbar/signal-envelope-contracts";
import { recordOrUndefined } from "./guards.js";
import type {
  GatewayRatchetEnvelopeDoc,
  GatewayRatchetHeaderDoc,
  GatewayRelayEnvelopeDoc,
} from "./types/generated/hermes-gateway.js";

// ---------------------------------------------------------------------------
// Gateway relay E2EE envelope (schema 2+). The phone seals event bodies to the
// agent's relay public key and the agent seals reply bodies to the phone's relay
// public key using the byte-exact HermesRelayCrypto contract
// ("p256-hkdf-sha256-aesgcm", keyVersion 1). The server is a blind
// store-and-forward: it validates the envelope SHAPE only and never decrypts.
// ---------------------------------------------------------------------------

// Wire-format constants mirrored verbatim from HermesRelayCrypto. v2 uses the
// authenticated 2-DH wrap; v3 uses RFC 9180 HPKE Auth mode for the content-key
// wrap while keeping payload/attachment AES-GCM unchanged. The server validates
// shape only and never decrypts either version.
export const HERMES_GATEWAY_RELAY_ENCRYPTION = "p256-hkdf-sha256-aesgcm";
export const HERMES_GATEWAY_RELAY_ENCRYPTION_V3 = "hpke-auth-p256-hkdfsha256-aes256gcm";
// X9.63 uncompressed P-256 public key: 65 bytes (0x04 ‖ X(32) ‖ Y(32)), base64.
const HERMES_GATEWAY_RELAY_PUBLIC_KEY_BYTES = 65;
// payloadCiphertext base64 cap (matches the relay-request precedent in
// firestore.rules). A sealed event/message/manifest payload is small; the cap is
// generous so a full 32 KB event body plus GCM overhead fits comfortably.
const HERMES_GATEWAY_MAX_RELAY_PAYLOAD_B64 = 900_000;
// wrappedKey base64 cap. The wrapped symmetric key is a fixed ~125 bytes
// (ephPubX963(65) ‖ nonce(12) ‖ ct(32) ‖ tag(16)); 4096 leaves ample headroom.
const HERMES_GATEWAY_MAX_RELAY_WRAPPED_KEY_B64 = 4_096;
// HPKE v3 `enc` is a 65-byte P-256 public key; this leaves base64 padding room
// while still rejecting unbounded relay-controlled strings.
const HERMES_GATEWAY_MAX_RELAY_ENC_B64 = 256;
// The DEFAULT relay key version a freshly published key / envelope advertises
// when none is supplied. v2 adds an optional senderPublicKey wire HINT (the
// sealing peer's ephemeral/identity X9.63 key); clients bind the PINNED key, not
// this hint, so the server still treats the envelope as opaque ciphertext.
export const HERMES_GATEWAY_RELAY_PUBLIC_KEY_VERSION = 1;
export const HERMES_GATEWAY_RELAY_KEY_VERSION = 2;
export const HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION = 3;
export const HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS = new Set([2, 3]);
// Every relay key version whose wire shape the BLIND relay accepts on both the
// write (requireGatewayRelayEnvelope / parseRelayPublicKey) and the read
// (sanitizeGatewayRelayEnvelope) side. v1 is the original
// "p256-hkdf-sha256-aesgcm" contract; v2 adds sender-authenticated 2-DH; v3 is
// RFC 9180 HPKE Auth. A version outside this set is a forged/future value and is
// rejected at every gate so it can never slip past a permissive range check.
export const HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS = new Set([1, 2, 3]);
export const HERMES_GATEWAY_RATCHET_PROTOCOL_VERSION = 1;
export const HERMES_GATEWAY_RATCHET_ALGORITHM = "OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM";
const HERMES_GATEWAY_MAX_RATCHET_CIPHERTEXT_B64 = HERMES_GATEWAY_MAX_RELAY_PAYLOAD_B64;
const HERMES_GATEWAY_MAX_RATCHET_ID = 160;
const HERMES_GATEWAY_MAX_RATCHET_COUNTER = 1_000_000_000;
export const HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION = SIGNAL_ENVELOPE_FORMAT_VERSION;
export const HERMES_GATEWAY_SIGNAL_RELAY_KEY_VERSION = SIGNAL_RELAY_KEY_VERSION;
// The official-libsignal transport envelope rides relay key VERSION 4 — the next
// rung above the bespoke HPKE-Auth v3 relay envelope. It is a SEPARATE wire family
// (a `signalEnvelope` doc validated by the @openburnbar/signal-envelope-contracts
// sanitizer), NOT a new shape of the v1/v2/v3 `relayEnvelope` ladder. The name is
// surfaced for clients/tests/runbooks; the byte-exact value is pinned by the
// contract's SIGNAL_RELAY_KEY_VERSION so the two can never drift.
export const HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL = SIGNAL_RELAY_KEY_VERSION;
export const HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION = SIGNAL_TRANSPORT_ENCRYPTION;
export const HERMES_GATEWAY_SIGNAL_AT_REST_ENCRYPTION = SIGNAL_AT_REST_ENCRYPTION;
// Signal-envelope version ladder, kept parallel to the relay-envelope ladder
// (HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS / *_PRODUCTION_*). SUPPORTED is the
// set of signal relayKeyVersions whose wire shape the BLIND relay tolerates on the
// READ side (sanitizeGatewaySignalEnvelope / requireGatewaySignalEnvelope) so a
// stored or staged v4 doc is recognized as sealed and passed through opaque.
// PRODUCTION is the set a NEW write may negotiate/emit — deliberately EMPTY while
// the libsignal cross-language runtime readiness gate is open, so v4 is read-
// tolerant but never producible (flag OFF). Activation flips v4 into PRODUCTION.
// (Remediation R12) It is INTENTIONAL and EXPECTED for SUPPORTED to be non-empty
// ({4}) while PRODUCTION is empty — that is the stable read-tolerant staging state,
// NOT a misconfiguration or drift. Do not "fix" the asymmetry by emptying SUPPORTED.
export const HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS = new Set([HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL]);
export const HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS = new Set<number>();
export const HERMES_GATEWAY_SIGNAL_REQUIRED_ENV = "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED";
// remediation(B3): the always-available, synchronous HARD kill switch for
// signal-envelope-v4. When set truthy ("1"/"true") this force-disables v4 in
// productionGatewaySignalEnvelopeVersions() — it overrides EVERYTHING, including
// gatewaySignalRequiredMode and the Remote Config enable flag. This is the
// <60s reversibility lever (Invariant #10): a single env export + redeploy
// guarantees no new client can negotiate or emit v4, with no RC fetch in the
// path. The drill at scripts/ops/signal-rollback-drill.sh Step 3 rehearses it.
export const HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV = "SIGNAL_ENVELOPE_V4_DISABLED";

type GatewaySignalEnvelopeMode = SignalEnvelopeMode;
type GatewaySignalEnvelopeDoc = SignalEnvelope;

export function gatewaySignalRequiredMode(env: NodeJS.ProcessEnv = process.env): boolean {
  return env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV] === "true";
}

// remediation(B3): synchronous read of the SIGNAL_ENVELOPE_V4_DISABLED hard kill.
// Truthy ("1"/"true", case-insensitive) means v4 is force-disabled everywhere.
// Read the same way as gatewaySignalRequiredMode (process.env, no async), so the
// kill is available even when Remote Config cannot be reached.
export function gatewaySignalEnvelopeV4Disabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const raw = env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV];
  if (typeof raw !== "string") return false;
  const normalized = raw.trim().toLowerCase();
  return normalized === "1" || normalized === "true";
}

export function productionGatewaySignalEnvelopeVersions(): Set<number> {
  // remediation(B3): the ENV hard kill wins over everything. If
  // SIGNAL_ENVELOPE_V4_DISABLED is truthy we return a set that EXCLUDES the v4
  // Signal version even in Signal-required mode — fail-closed so no write/cap
  // path can negotiate or emit v4 while the kill is engaged. This never loosens
  // the READ-side tolerance (HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS),
  // which stays {4} so already-stored v4 docs remain readable on rollback.
  if (gatewaySignalEnvelopeV4Disabled()) {
    return new Set<number>();
  }
  return gatewaySignalRequiredMode()
    ? new Set([HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL])
    : new Set(HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS);
}

export function productionGatewayRelayKeyVersions(): Set<number> {
  return gatewaySignalRequiredMode() ? new Set() : new Set(HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS);
}

/**
 * Validate a published relay public key: a base64 X9.63 uncompressed P-256 key
 * (exactly 65 bytes, first byte 0x04). Returns the canonical (trimmed) base64 on
 * success, or undefined for any malformed/absent value — callers decide whether a
 * missing key is fatal (post-cutoff pairing) or tolerable (legacy pairing).
 */
export function isGatewayRelayPublicKeyB64(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > 256 || !/^[A-Za-z0-9+/=]+$/u.test(value)) return undefined;
  let decoded: Buffer;
  try {
    decoded = Buffer.from(value, "base64");
  } catch {
    return undefined;
  }
  // Reject base64 that round-trips to a different string (non-canonical padding)
  // or to the wrong key length / point format.
  if (decoded.length !== HERMES_GATEWAY_RELAY_PUBLIC_KEY_BYTES || decoded[0] !== 0x04) return undefined;
  return value;
}

function gatewayBase64Within(raw: unknown, maxLength: number): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > maxLength || !/^[A-Za-z0-9+/=]+$/u.test(value)) return undefined;
  try {
    Buffer.from(value, "base64");
  } catch {
    return undefined;
  }
  return value;
}

function gatewayRatchetID(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > HERMES_GATEWAY_MAX_RATCHET_ID || /[\r\n/]/u.test(value)) return undefined;
  return value;
}

function gatewayRatchetCounter(raw: unknown): number | undefined {
  const value = typeof raw === "number" ? Math.floor(raw) : Number(raw);
  if (!Number.isSafeInteger(value) || value < 0 || value > HERMES_GATEWAY_MAX_RATCHET_COUNTER) return undefined;
  return value;
}

function sanitizeGatewayRatchetHeader(raw: unknown): GatewayRatchetHeaderDoc | undefined {
  const record = recordOrUndefined(raw);
  if (!record) return undefined;
  const version = gatewayRatchetCounter(record.version);
  const algorithm = typeof record.algorithm === "string" ? record.algorithm.trim() : "";
  const sessionID = gatewayRatchetID(record.sessionID);
  const senderDeviceID = gatewayRatchetID(record.senderDeviceID);
  const receiverDeviceID = gatewayRatchetID(record.receiverDeviceID);
  const ratchetPublicKeyBase64 = isGatewayRelayPublicKeyB64(record.ratchetPublicKeyBase64);
  const previousChainLength = gatewayRatchetCounter(record.previousChainLength);
  const messageNumber = gatewayRatchetCounter(record.messageNumber);
  const epoch = gatewayRatchetCounter(record.epoch);
  if (
    version !== HERMES_GATEWAY_RATCHET_PROTOCOL_VERSION ||
    algorithm !== HERMES_GATEWAY_RATCHET_ALGORITHM ||
    !sessionID ||
    !senderDeviceID ||
    !receiverDeviceID ||
    !ratchetPublicKeyBase64 ||
    previousChainLength === undefined ||
    messageNumber === undefined ||
    epoch === undefined
  ) {
    return undefined;
  }
  return {
    version,
    algorithm,
    sessionID,
    senderDeviceID,
    receiverDeviceID,
    ratchetPublicKeyBase64,
    previousChainLength,
    messageNumber,
    epoch,
  };
}

export function sanitizeGatewayRatchetEnvelope(raw: unknown): GatewayRatchetEnvelopeDoc | undefined {
  const record = recordOrUndefined(raw);
  if (!record) return undefined;
  const header = sanitizeGatewayRatchetHeader(record.header);
  const ciphertextBase64 = gatewayBase64Within(record.ciphertextBase64, HERMES_GATEWAY_MAX_RATCHET_CIPHERTEXT_B64);
  if (!header || !ciphertextBase64) return undefined;
  return { header, ciphertextBase64 };
}

export function requireGatewayRatchetEnvelope(raw: unknown, fieldName: string): GatewayRatchetEnvelopeDoc {
  const envelope = sanitizeGatewayRatchetEnvelope(raw);
  if (!envelope) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName} must be a Hermes ratchet v${HERMES_GATEWAY_RATCHET_PROTOCOL_VERSION} envelope.`,
    );
  }
  return envelope;
}

export function requireProductionGatewayRatchetEnvelope(raw: unknown, fieldName: string): GatewayRatchetEnvelopeDoc {
  if (gatewaySignalRequiredMode()) {
    throw new HttpsError(
      "failed-precondition",
      `${fieldName} is rejected in Signal-required gateway mode; write a Signal envelope instead.`,
    );
  }
  return requireGatewayRatchetEnvelope(raw, fieldName);
}

/**
 * Non-throwing SHAPE check for an official-libsignal `signalEnvelope` (relay key
 * version 4). Delegates to the in-tree contract's {@link sanitizeSignalEnvelope}
 * (base64 + cap + capability validation, fully OPAQUE — the server never holds a
 * Signal session key and can never decrypt). Mirrors {@link sanitizeGatewayRelay-
 * Envelope}: a doc is read-tolerated ONLY when its relayKeyVersion is in
 * {@link HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS}, so a forged/future
 * signal version fails closed to "unreadable" (returns undefined) rather than
 * slipping through on a permissive range check.
 */
export function sanitizeGatewaySignalEnvelope(
  raw: unknown,
  expectedMode?: GatewaySignalEnvelopeMode,
): GatewaySignalEnvelopeDoc | undefined {
  const envelope = sanitizeSignalEnvelope(raw, expectedMode);
  if (!envelope) return undefined;
  // A transport signal envelope pins relayKeyVersion via the contract; an at-rest
  // envelope omits it. Read-tolerate ONLY versions in the SUPPORTED set; an at-rest
  // (undefined) envelope is governed by its own mode/scheme checks in the contract.
  if (
    envelope.relayKeyVersion !== undefined &&
    !HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS.has(envelope.relayKeyVersion)
  ) {
    return undefined;
  }
  return envelope;
}

export function requireGatewaySignalEnvelope(
  raw: unknown,
  fieldName: string,
  expectedMode?: GatewaySignalEnvelopeMode,
): GatewaySignalEnvelopeDoc {
  const envelope = sanitizeGatewaySignalEnvelope(raw, expectedMode);
  if (!envelope) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName} must be a Signal envelope v${HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION}.`,
    );
  }
  return envelope;
}

/**
 * WRITE-path guard for a `signalEnvelope`. Validates the SHAPE first (so a
 * malformed envelope is rejected as invalid-argument like every other write), then
 * fail-closes: a relayKeyVersion that is read-SUPPORTED but NOT in
 * {@link HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS} is rejected for new
 * writes. That set is EMPTY while the libsignal runtime readiness gate is open, so
 * NO client can negotiate or emit a v4 signal envelope (flag OFF). Mirrors
 * {@link requireProductionGatewayRelayEnvelope}; activation is a one-line set edit.
 */
export function requireProductionGatewaySignalEnvelope(raw: unknown, fieldName: string): GatewaySignalEnvelopeDoc {
  const envelope = requireGatewaySignalEnvelope(raw, fieldName, "transport");
  const version = envelope.relayKeyVersion ?? HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL;
  const productionVersions = productionGatewaySignalEnvelopeVersions();
  if (!productionVersions.has(version)) {
    throw new HttpsError(
      "failed-precondition",
      `${fieldName} is valid, but Signal envelope writes are disabled until the libsignal runtime readiness gate is complete.`,
    );
  }
  return envelope;
}

const RELAY_BASE64_PATTERN = /^[A-Za-z0-9+/=]+$/u;

function parsedRelayKeyVersion(raw: unknown): number {
  return typeof raw === "number" ? Math.floor(raw) : Number(raw);
}

function expectedRelayEncryptionForVersion(relayKeyVersion: number): string {
  return relayKeyVersion === HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION
    ? HERMES_GATEWAY_RELAY_ENCRYPTION_V3
    : HERMES_GATEWAY_RELAY_ENCRYPTION;
}

function trimmedRelayString(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

function isBoundedRelayBase64(value: string, maxLength: number): boolean {
  return Boolean(value) && value.length <= maxLength && RELAY_BASE64_PATTERN.test(value);
}

/**
 * Throwing field validators for {@link requireGatewayRelayEnvelope}. Each is a
 * cohesive guard so the top-level validator stays under the complexity ceiling;
 * the accept/reject set and every HttpsError code/message are byte-identical to
 * the former inline checks.
 */
function requireRelayKeyVersion(relayKeyVersion: number, fieldName: string): void {
  if (!HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS.has(relayKeyVersion)) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName}.relayKeyVersion must be one of ${[...HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS].join(", ")}.`,
    );
  }
}

function requireRelayEncryption(relayEncryption: string, relayKeyVersion: number, fieldName: string): void {
  const expected = expectedRelayEncryptionForVersion(relayKeyVersion);
  if (relayEncryption !== expected) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName}.relayEncryption must be ${expected} for relayKeyVersion ${relayKeyVersion}.`,
    );
  }
}

function requireRelayEnc(record: Record<string, unknown>, relayKeyVersion: number, fieldName: string): string {
  const enc = trimmedRelayString(record.enc);
  if (relayKeyVersion === HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION) {
    if (!isBoundedRelayBase64(enc, HERMES_GATEWAY_MAX_RELAY_ENC_B64)) {
      throw new HttpsError(
        "invalid-argument",
        `${fieldName}.enc must be base64 within the size cap for relayKeyVersion ${relayKeyVersion}.`,
      );
    }
  } else if (record.enc != null) {
    throw new HttpsError("invalid-argument", `${fieldName}.enc is only valid for relayKeyVersion 3.`);
  }
  return enc;
}

function requireRelaySenderPublicKey(
  record: Record<string, unknown>,
  relayKeyVersion: number,
  fieldName: string,
): string | undefined {
  // senderPublicKey is the v2 wire HINT (a base64 X9.63 P-256 key). REQUIRE it for
  // a v2 envelope and reject a malformed value; tolerate its absence for v1.
  const senderPublicKey = isGatewayRelayPublicKeyB64(record.senderPublicKey);
  if (relayKeyVersion >= 2) {
    if (!senderPublicKey) {
      throw new HttpsError(
        "invalid-argument",
        `${fieldName}.senderPublicKey must be a base64 X9.63 P-256 public key (65 bytes, 0x04-prefixed) for relayKeyVersion ${relayKeyVersion}.`,
      );
    }
  } else if (record.senderPublicKey != null && !senderPublicKey) {
    // A v1 envelope carrying a present-but-malformed hint is still a malformed
    // write; reject it rather than silently dropping a forged value.
    throw new HttpsError(
      "invalid-argument",
      `${fieldName}.senderPublicKey must be a base64 X9.63 P-256 public key (65 bytes, 0x04-prefixed).`,
    );
  }
  return senderPublicKey;
}

/**
 * Validate a per-document relay envelope (schema 2+). Mirrors requireSealedText:
 * checks the algorithm constant, the key version range, and the base64 shape +
 * size caps of payloadCiphertext / wrappedKey. The server never decrypts; this is
 * a pure SHAPE gate. Throws HttpsError("invalid-argument") on any violation — the
 * gateway HTTP wrapper maps HttpsError to a 400, so both the callable and HTTP
 * surfaces reject malformed envelopes identically.
 */
export function requireGatewayRelayEnvelope(raw: unknown, fieldName: string): GatewayRelayEnvelopeDoc {
  const record = recordOrUndefined(raw);
  if (!record) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a relay envelope.`);
  }
  // Accept only a version whose wire shape exists (v1, v2, or v3); reject every other
  // value so a forged/future version can never be accepted as sealed.
  const relayKeyVersion = parsedRelayKeyVersion(record.relayKeyVersion);
  requireRelayKeyVersion(relayKeyVersion, fieldName);
  const relayEncryption = trimmedRelayString(record.relayEncryption);
  requireRelayEncryption(relayEncryption, relayKeyVersion, fieldName);
  const payloadCiphertext = trimmedRelayString(record.payloadCiphertext);
  if (!isBoundedRelayBase64(payloadCiphertext, HERMES_GATEWAY_MAX_RELAY_PAYLOAD_B64)) {
    throw new HttpsError("invalid-argument", `${fieldName}.payloadCiphertext must be base64 within the size cap.`);
  }
  const wrappedKey = trimmedRelayString(record.wrappedKey);
  if (!isBoundedRelayBase64(wrappedKey, HERMES_GATEWAY_MAX_RELAY_WRAPPED_KEY_B64)) {
    throw new HttpsError("invalid-argument", `${fieldName}.wrappedKey must be base64 within the size cap.`);
  }
  const enc = requireRelayEnc(record, relayKeyVersion, fieldName);
  const senderPublicKey = requireRelaySenderPublicKey(record, relayKeyVersion, fieldName);
  const envelope: GatewayRelayEnvelopeDoc = {
    payloadCiphertext,
    wrappedKey,
    relayEncryption,
    relayKeyVersion,
  };
  if (enc) envelope.enc = enc;
  if (senderPublicKey) envelope.senderPublicKey = senderPublicKey;
  return envelope;
}

/**
 * WRITE-path guard. Every NEW gateway write (a sealed message, attachment init,
 * or sealed control event) MUST use an authenticated production envelope: v2
 * 2-DH or v3 HPKE Auth. {@link requireGatewayRelayEnvelope} deliberately stays
 * v1-tolerant for the READ / legacy-sanitizer path so already-stored v1 docs are
 * not bricked; the trust boundary rejects new legacy envelopes.
 */
export function requireProductionGatewayRelayEnvelope(raw: unknown, fieldName: string): GatewayRelayEnvelopeDoc {
  if (gatewaySignalRequiredMode()) {
    throw new HttpsError(
      "failed-precondition",
      `${fieldName} is rejected in Signal-required gateway mode; write a Signal envelope instead.`,
    );
  }
  const envelope = requireGatewayRelayEnvelope(raw, fieldName);
  const productionVersions = productionGatewayRelayKeyVersions();
  if (!productionVersions.has(envelope.relayKeyVersion)) {
    throw new HttpsError(
      "invalid-argument",
      `${fieldName}.relayKeyVersion must be one of ${[...productionVersions].join(", ")} for new gateway writes.`,
    );
  }
  return envelope;
}

/**
 * Non-throwing shape check used by read-side serializers (serializeHermesGateway-
 * Event) to pass through a stored envelope verbatim without rejecting the whole
 * doc. Applies the SAME validation semantics as requireGatewayRelayEnvelope
 * (algorithm constant, the single supported key version, base64 + size caps) so
 * the read path can never surface a malformed/forged envelope that the write path
 * would have rejected — a corrupt, backfilled, or admin-written doc that fails any
 * check is treated as unreadable (returns undefined) rather than passed through.
 *
 * Implemented by delegating to {@link requireGatewayRelayEnvelope}: the accept /
 * reject decision and the returned object are byte-identical; the only difference
 * is that a rejection surfaces as `undefined` instead of a thrown HttpsError.
 */
export function sanitizeGatewayRelayEnvelope(raw: unknown): GatewayRelayEnvelopeDoc | undefined {
  try {
    return requireGatewayRelayEnvelope(raw, "relayEnvelope");
  } catch {
    return undefined;
  }
}

export interface HermesGatewayRelayEnvelopeCapabilities {
  supportsRelayEnvelopeVersions: number[];
  preferredRelayEnvelopeVersion: number;
  supportsHpkeV3: boolean;
  // Whether this endpoint can seal/open the official-libsignal `signalEnvelope`
  // (relay key v4). Defaults FALSE and stays FALSE for every shipping client until
  // the libsignal runtime readiness gate is complete — no negotiated pairing can
  // become Signal-capable while either side is false, and v4 is never folded into
  // the relay-envelope version ladder, so preferredRelayEnvelopeVersion can never
  // become 4. Purely a forward-compat capability bit (flag OFF).
  supportsSignalEnvelope: boolean;
  platform?: string;
  appBuild?: string;
}

function sanitizeGatewayCapabilityText(raw: unknown, max: number): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  return value ? value.slice(0, max) : undefined;
}

/**
 * Parse + validate the supportsRelayEnvelopeVersions field. Returns the sorted,
 * de-duplicated, production-only version list or routes every rejection through
 * `throwError` with the byte-identical messages of the former inline checks.
 */
function parseSupportsRelayEnvelopeVersions(versionField: unknown, throwError: (message: string) => never): number[] {
  if (versionField == null) {
    return [HERMES_GATEWAY_RELAY_KEY_VERSION];
  }
  if (!Array.isArray(versionField)) {
    throwError("supportsRelayEnvelopeVersions must be an array.");
  }
  const versions: number[] = [];
  for (const item of versionField) {
    const version = typeof item === "number" ? Math.floor(item) : Number(item);
    if (!HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS.has(version)) {
      throwError(
        `supportsRelayEnvelopeVersions must contain only ${[...HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS].join(", ")}.`,
      );
    }
    if (!versions.includes(version)) versions.push(version);
  }
  if (!versions.length) {
    throwError("supportsRelayEnvelopeVersions must include at least one production relay envelope version.");
  }
  return versions.sort((a, b) => a - b);
}

/**
 * Resolve supportsHpkeV3 against the negotiated version list. A boolean override
 * must be consistent with whether the list includes v3; an absent value derives
 * from the list. Every rejection mirrors the former inline messages.
 */
function resolveSupportsHpkeV3(
  rawSupportsHpkeV3: unknown,
  versionListIncludesV3: boolean,
  throwError: (message: string) => never,
): boolean {
  if (rawSupportsHpkeV3 != null && typeof rawSupportsHpkeV3 !== "boolean") {
    throwError("supportsHpkeV3 must be a boolean.");
  }
  if (rawSupportsHpkeV3 === true && !versionListIncludesV3) {
    throwError("supportsHpkeV3=true requires supportsRelayEnvelopeVersions to include 3.");
  }
  if (rawSupportsHpkeV3 === false && versionListIncludesV3) {
    throwError("supportsHpkeV3=false is inconsistent with supportsRelayEnvelopeVersions including 3.");
  }
  return rawSupportsHpkeV3 ?? versionListIncludesV3;
}

/**
 * Resolve supportsSignalEnvelope. It defaults FALSE and stays FALSE: a client may
 * only assert it true once v4 is in HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_-
 * VERSIONS (empty today), so any true value is rejected fail-closed while the
 * runtime readiness gate is open. Messages match the former inline checks.
 */
function resolveSupportsSignalEnvelope(
  rawSupportsSignalEnvelope: unknown,
  throwError: (message: string) => never,
): boolean {
  if (rawSupportsSignalEnvelope != null && typeof rawSupportsSignalEnvelope !== "boolean") {
    throwError("supportsSignalEnvelope must be a boolean.");
  }
  if (gatewaySignalRequiredMode() && rawSupportsSignalEnvelope !== true) {
    throwError("supportsSignalEnvelope=true is required in Signal-required gateway mode.");
  }
  if (
    rawSupportsSignalEnvelope === true &&
    !gatewaySignalRequiredMode() &&
    productionGatewaySignalEnvelopeVersions().size === 0
  ) {
    throwError("supportsSignalEnvelope is not yet negotiable: Signal envelope writes are disabled.");
  }
  return rawSupportsSignalEnvelope === true;
}

/**
 * Resolve preferredRelayEnvelopeVersion against the negotiated version list. An
 * absent value picks the highest supported version; an explicit value must be in
 * the list and must never be the Signal version (defense in depth). Messages match
 * the former inline checks.
 */
function resolvePreferredRelayEnvelopeVersion(
  rawPreferred: unknown,
  supportsRelayEnvelopeVersions: number[],
  throwError: (message: string) => never,
): number {
  const preferredRelayEnvelopeVersion =
    rawPreferred == null
      ? Math.max(...supportsRelayEnvelopeVersions)
      : typeof rawPreferred === "number"
        ? Math.floor(rawPreferred)
        : Number(rawPreferred);
  if (!supportsRelayEnvelopeVersions.includes(preferredRelayEnvelopeVersion)) {
    throwError("preferredRelayEnvelopeVersion must be included in supportsRelayEnvelopeVersions.");
  }
  // Defense in depth: the signal envelope (v4) is a SEPARATE wire family and is
  // never folded into the relay-envelope ladder, so the preferred RELAY version can
  // never be the signal version. Re-assert it so a future ladder edit can never
  // silently let production select v4 (which has no relay-envelope wire shape).
  if (preferredRelayEnvelopeVersion === HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL) {
    throwError("preferredRelayEnvelopeVersion must not be the Signal envelope version.");
  }
  return preferredRelayEnvelopeVersion;
}

export function sanitizeGatewayRelayEnvelopeCapabilities(
  raw: Record<string, unknown> | undefined,
  throwError: (message: string) => never = (message) => {
    throw new HttpsError("invalid-argument", message);
  },
): HermesGatewayRelayEnvelopeCapabilities {
  const supportsRelayEnvelopeVersions = parseSupportsRelayEnvelopeVersions(
    raw?.supportsRelayEnvelopeVersions,
    throwError,
  );
  const versionListIncludesV3 = supportsRelayEnvelopeVersions.includes(HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION);
  const supportsHpkeV3 = resolveSupportsHpkeV3(raw?.supportsHpkeV3, versionListIncludesV3, throwError);
  const supportsSignalEnvelope = resolveSupportsSignalEnvelope(raw?.supportsSignalEnvelope, throwError);
  const preferredRelayEnvelopeVersion = resolvePreferredRelayEnvelopeVersion(
    raw?.preferredRelayEnvelopeVersion,
    supportsRelayEnvelopeVersions,
    throwError,
  );

  const capabilities: HermesGatewayRelayEnvelopeCapabilities = {
    supportsRelayEnvelopeVersions,
    preferredRelayEnvelopeVersion,
    supportsHpkeV3,
    supportsSignalEnvelope,
  };
  const platform = sanitizeGatewayCapabilityText(raw?.clientPlatform ?? raw?.platform, 80);
  const appBuild = sanitizeGatewayCapabilityText(raw?.clientAppBuild ?? raw?.appBuild, 80);
  if (platform) capabilities.platform = platform;
  if (appBuild) capabilities.appBuild = appBuild;
  return capabilities;
}

export function negotiateGatewayRelayEnvelopeCapabilities(
  agent: HermesGatewayRelayEnvelopeCapabilities,
  phone: HermesGatewayRelayEnvelopeCapabilities,
): HermesGatewayRelayEnvelopeCapabilities {
  const shared = agent.supportsRelayEnvelopeVersions
    .filter((version) => phone.supportsRelayEnvelopeVersions.includes(version))
    .sort((a, b) => a - b);
  if (!shared.length) {
    throw new HttpsError(
      "invalid-argument",
      "No shared Hermes Gateway relay envelope version exists for this pairing.",
    );
  }
  // The shared set is an intersection of two PRODUCTION ladders (each already
  // excludes the Signal version), so Math.max can never be v4. The Signal
  // capability negotiates as the AND of both endpoints — false unless BOTH advertise
  // it, which no shipping client does while the runtime readiness gate is open.
  const preferredRelayEnvelopeVersion = Math.max(...shared);
  return {
    supportsRelayEnvelopeVersions: shared,
    preferredRelayEnvelopeVersion,
    supportsHpkeV3: shared.includes(HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION),
    supportsSignalEnvelope: agent.supportsSignalEnvelope && phone.supportsSignalEnvelope,
  };
}
