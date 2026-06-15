/**
 * @fileoverview Cryptographic plumbing for the BurnBar Cloud Hermes Gateway —
 * relay/ratchet public-key parsing, client signing keys, proof-of-possession
 * (PoP) payload canonicalization + verification. Split out of hermesGateway.ts
 * to keep every gateway module under the file-length cap; re-exported from there
 * byte-identically.
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { createPublicKey, verify as verifySignature } from "node:crypto";

import { db } from "../adminRuntime.js";
import {
  HERMES_GATEWAY_RELAY_ENCRYPTION,
  HERMES_GATEWAY_RELAY_PUBLIC_KEY_VERSION,
  HERMES_GATEWAY_SCHEMA_VERSION,
  isGatewayRelayPublicKeyB64,
  safeEqualHex,
  sha256Hex,
} from "../hermesGateway.js";
import type { HermesGatewayClientDoc } from "../types/generated/hermes-gateway.js";
import {
  gatewayHeader,
  gatewayPath,
  type HttpRequest,
  httpError,
  requestBody,
  stableJSONString,
} from "./hermesGatewayHttp.js";
import { nowISO } from "./shared.js";

const ED25519_PUBLIC_KEY_BYTE_LENGTH = 32;
const ED25519_SPKI_DER_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const GATEWAY_POP_CLOCK_SKEW_MS = 5 * 60 * 1000;

interface ParsedRelayPublicKey {
  publicKey: string;
  keyVersion: number;
  encryption: string;
}

interface ParsedRatchetPrekeyBundle {
  identityPublicKey: string;
  signingPublicKey: string;
  signedPreKeyPublicKey: string;
  signedPreKeyId: string;
  signedPreKeySignature: string;
  supportsRatchetV1: boolean;
}

// Internal cross-module plumbing types (not schema/wire surface): declared
// module-private and re-exported so sibling gateway modules can import them
// without growing the hand-maintained exported-type budget.
export type { ParsedRelayPublicKey, ParsedRatchetPrekeyBundle };

/**
 * Parse + validate a published relay public-key trio from a request body. Reads
 * `<publicKeyField>` (base64 X9.63 P-256, 65B/0x04), `<keyVersionField>` (int
 * 1..100, default 1) and `<encryptionField>` (must equal the relay algorithm
 * constant, default the constant). Returns undefined when the public key is
 * absent (legacy pairing); throws on a malformed/forged value. `throwError`
 * adapts the error type to the calling surface (HTTP vs callable).
 */
export function parseRelayPublicKey(
  body: Record<string, unknown>,
  fields: { publicKeyField: string; keyVersionField: string; encryptionField: string },
  throwError: (message: string) => never,
): ParsedRelayPublicKey | undefined {
  const rawKey = body[fields.publicKeyField];
  if (rawKey == null || rawKey === "") return undefined;
  const publicKey = isGatewayRelayPublicKeyB64(rawKey);
  if (!publicKey) {
    throwError(`${fields.publicKeyField} must be a base64 X9.63 P-256 public key (65 bytes, 0x04-prefixed).`);
  }
  const rawVersion = body[fields.keyVersionField];
  const keyVersion =
    rawVersion == null
      ? HERMES_GATEWAY_RELAY_PUBLIC_KEY_VERSION
      : typeof rawVersion === "number"
        ? Math.floor(rawVersion)
        : Number(rawVersion);
  if (keyVersion !== HERMES_GATEWAY_RELAY_PUBLIC_KEY_VERSION) {
    throwError(`${fields.keyVersionField} must be ${HERMES_GATEWAY_RELAY_PUBLIC_KEY_VERSION}.`);
  }
  const rawEncryption = body[fields.encryptionField];
  const encryption =
    rawEncryption == null || rawEncryption === ""
      ? HERMES_GATEWAY_RELAY_ENCRYPTION
      : typeof rawEncryption === "string"
        ? rawEncryption.trim()
        : "";
  if (encryption !== HERMES_GATEWAY_RELAY_ENCRYPTION) {
    throwError(`${fields.encryptionField} must be ${HERMES_GATEWAY_RELAY_ENCRYPTION}.`);
  }
  return { publicKey, keyVersion, encryption };
}

function ratchetBundleField(body: Record<string, unknown>, prefix: "agent" | "phone", suffix: string): unknown {
  const prefixed = `${prefix}Ratchet${suffix}`;
  const generic = `ratchet${suffix}`;
  return body[prefixed] ?? body[generic];
}

function ratchetBundleBoolean(body: Record<string, unknown>, prefix: "agent" | "phone"): boolean | undefined {
  const raw = body[`${prefix}SupportsRatchetV1`] ?? body.supportsRatchetV1;
  if (raw === undefined || raw === null || raw === "") return undefined;
  return raw === true;
}

function ratchetPrekeyId(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > 160 || /[\r\n/]/u.test(value)) return undefined;
  return value;
}

function ratchetSignature(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > 1024 || !/^[A-Za-z0-9+/=]+$/u.test(value)) return undefined;
  try {
    Buffer.from(value, "base64");
  } catch {
    return undefined;
  }
  return value;
}

export function parseRatchetPrekeyBundle(
  body: Record<string, unknown>,
  prefix: "agent" | "phone",
  throwError: (message: string) => never,
): ParsedRatchetPrekeyBundle | undefined {
  const supports = ratchetBundleBoolean(body, prefix);
  const rawIdentityPublicKey = ratchetBundleField(body, prefix, "IdentityPublicKey");
  const rawSigningPublicKey = ratchetBundleField(body, prefix, "SigningPublicKey");
  const rawSignedPreKeyPublicKey = ratchetBundleField(body, prefix, "SignedPreKeyPublicKey");
  const rawSignedPreKeyId = ratchetBundleField(body, prefix, "SignedPreKeyId");
  const rawSignedPreKeySignature = ratchetBundleField(body, prefix, "SignedPreKeySignature");
  const identityPublicKey = isGatewayRelayPublicKeyB64(rawIdentityPublicKey);
  const signingPublicKey = isGatewayRelayPublicKeyB64(rawSigningPublicKey);
  const signedPreKeyPublicKey = isGatewayRelayPublicKeyB64(rawSignedPreKeyPublicKey);
  const signedPreKeyId = ratchetPrekeyId(rawSignedPreKeyId);
  const signedPreKeySignature = ratchetSignature(rawSignedPreKeySignature);
  const rawFieldsPresent =
    rawIdentityPublicKey !== undefined ||
    rawSigningPublicKey !== undefined ||
    rawSignedPreKeyPublicKey !== undefined ||
    rawSignedPreKeyId !== undefined ||
    rawSignedPreKeySignature !== undefined;
  const anyPresent = supports !== undefined || rawFieldsPresent;
  if (!anyPresent) return undefined;
  if (supports === false && !rawFieldsPresent) return undefined;
  if (!identityPublicKey) throwError(`${prefix}RatchetIdentityPublicKey must be a base64 X9.63 P-256 public key.`);
  if (!signingPublicKey) throwError(`${prefix}RatchetSigningPublicKey must be a base64 X9.63 P-256 public key.`);
  if (!signedPreKeyPublicKey) {
    throwError(`${prefix}RatchetSignedPreKeyPublicKey must be a base64 X9.63 P-256 public key.`);
  }
  if (!signedPreKeyId) throwError(`${prefix}RatchetSignedPreKeyId must be a non-empty safe identifier.`);
  if (!signedPreKeySignature) throwError(`${prefix}RatchetSignedPreKeySignature must be base64 within the size cap.`);
  return {
    identityPublicKey,
    signingPublicKey,
    signedPreKeyPublicKey,
    signedPreKeyId,
    signedPreKeySignature,
    supportsRatchetV1: true,
  };
}

function parseGatewayClientSigningPublicKey(raw: unknown): Buffer | undefined {
  const value = typeof raw === "string" ? raw.trim() : "";
  const publicKey = Buffer.from(value, "base64");
  if (publicKey.length !== ED25519_PUBLIC_KEY_BYTE_LENGTH || publicKey.toString("base64") !== value) {
    return undefined;
  }
  return publicKey;
}

export function requireGatewayClientSigningPublicKey(raw: unknown): Buffer {
  const publicKey = parseGatewayClientSigningPublicKey(raw);
  if (!publicKey) throw httpError(400, "invalid_client_signing_public_key");
  return publicKey;
}

export function requireCallableGatewayClientSigningPublicKey(raw: unknown): Buffer {
  const publicKey = parseGatewayClientSigningPublicKey(raw);
  if (!publicKey) {
    throw new HttpsError("failed-precondition", "Hermes Gateway clients must publish a request signing public key.");
  }
  return publicKey;
}

function gatewayRequestBodyHash(req: HttpRequest): string {
  return sha256Hex(stableJSONString(requestBody(req)));
}

function gatewayPopSignablePayload(options: {
  tokenHash: string;
  method: string;
  path: string;
  bodyHash: string;
  nonce: string;
  timestamp: string;
}): Buffer {
  return Buffer.from(
    [
      "OpenBurnBar.HermesGatewayPoP.v1",
      options.tokenHash,
      options.method.toUpperCase(),
      options.path,
      options.bodyHash,
      options.nonce,
      options.timestamp,
    ].join("\n"),
    "utf8",
  );
}

// L2 — fold the query string into the signed PoP payload (PoP v2).
//
// PoP v1 covers tokenHash | METHOD | path | bodyHash | nonce | timestamp, so a
// GET's query params (e.g. /events?cursor=…&destinationId=…) are not
// integrity-protected. v2 binds a canonical query string into the signature.
// The version is negotiated per request via the `x-openburnbar-pop-version`
// header; the server accepts both v1 and v2 during the transition (a unilateral
// flip would 401 every paired client), and refuses a v1 downgrade only once a
// client has registered v2 capability (`popVersion >= 2`).

/// Canonical query string for PoP v2 — decoded params sorted by key then value
/// and joined `key=value` with `&`. Decoded (not re-encoded) so Node and the
/// Python client agree byte-for-byte without percent-encoding variance.
function canonicalGatewayQueryString(req: HttpRequest): string {
  const pairs: Array<[string, string]> = [];
  for (const [key, value] of Object.entries(req.query ?? {})) {
    if (Array.isArray(value)) {
      for (const item of value) pairs.push([key, String(item)]);
    } else if (value !== undefined && value !== null) {
      pairs.push([key, String(value)]);
    }
  }
  pairs.sort((a, b) => (a[0] === b[0] ? (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0) : a[0] < b[0] ? -1 : 1));
  return pairs.map(([key, value]) => `${key}=${value}`).join("&");
}

/// The PoP version the client declares it signed with. Absent / "1" ⇒ v1.
function gatewayPopVersion(req: HttpRequest): 1 | 2 {
  const raw = gatewayHeader(req, "x-openburnbar-pop-version", "x-obb-pop-version")?.trim();
  return raw === "2" ? 2 : 1;
}

/// The persisted PoP capability a client advertises at pairing/registration.
/// Only 2 ("supports v2") is meaningful; anything else is recorded as 1.
export function parseGatewayPopVersionCapability(raw: unknown): number {
  const value = typeof raw === "number" ? raw : Number(raw);
  return Number.isFinite(value) && value >= 2 ? 2 : 1;
}

function gatewayPopSignablePayloadV2(options: {
  tokenHash: string;
  method: string;
  path: string;
  query: string;
  bodyHash: string;
  nonce: string;
  timestamp: string;
}): Buffer {
  return Buffer.from(
    [
      "OpenBurnBar.HermesGatewayPoP.v2",
      options.tokenHash,
      options.method.toUpperCase(),
      options.path,
      options.query,
      options.bodyHash,
      options.nonce,
      options.timestamp,
    ].join("\n"),
    "utf8",
  );
}

interface VerifiedPopHeaders {
  nonce: string;
  timestamp: string;
  timestampMillis: number;
  suppliedBodyHash: string;
  signature: Buffer;
}

/**
 * Validate the PoP version negotiation and the PoP request headers (nonce,
 * timestamp, body hash, signature shape). Throws the same 401s the inline guard
 * did, in the same order. A pure relocation of the header-parsing prefix of
 * verifyGatewayRequestPoP.
 */
function parseVerifiedPopHeaders(req: HttpRequest, client: HermesGatewayClientDoc): VerifiedPopHeaders {
  // L2 — version negotiation. Accept v1 and v2 during the transition, but once a
  // client has registered v2 capability refuse a v1 downgrade (an attacker could
  // otherwise strip the query binding by claiming v1).
  const declaredPopVersion = gatewayPopVersion(req);
  const clientPopVersion = typeof client.popVersion === "number" ? client.popVersion : 1;
  if (clientPopVersion >= 2 && declaredPopVersion < 2) {
    throw httpError(401, "pop_v2_required");
  }
  const nonce = gatewayHeader(req, "x-openburnbar-pop-nonce", "x-obb-pop-nonce")?.trim() ?? "";
  const timestamp = gatewayHeader(req, "x-openburnbar-pop-timestamp", "x-obb-pop-timestamp")?.trim() ?? "";
  const suppliedBodyHash =
    gatewayHeader(req, "x-openburnbar-pop-body-sha256", "x-obb-pop-body-sha256")?.trim().toLowerCase() ?? "";
  const signatureBase64 =
    gatewayHeader(req, "x-openburnbar-pop-signature-ed25519", "x-obb-pop-signature-ed25519")?.trim() ?? "";
  if (!/^[A-Za-z0-9._:-]{16,160}$/u.test(nonce)) throw httpError(401, "missing_pop_nonce");
  const timestampMillis = Number.isFinite(Number(timestamp)) ? Number(timestamp) : Date.parse(timestamp);
  if (!Number.isFinite(timestampMillis) || Math.abs(Date.now() - timestampMillis) > GATEWAY_POP_CLOCK_SKEW_MS) {
    throw httpError(401, "expired_pop_timestamp");
  }
  const expectedBodyHash = gatewayRequestBodyHash(req);
  if (!safeEqualHex(suppliedBodyHash, expectedBodyHash)) {
    throw httpError(401, "bad_pop_body_hash");
  }
  const signature = Buffer.from(signatureBase64, "base64");
  if (signature.length !== 64 || signature.toString("base64") !== signatureBase64) {
    throw httpError(401, "bad_pop_signature");
  }
  return { nonce, timestamp, timestampMillis, suppliedBodyHash, signature };
}

/**
 * Verify the Ed25519 PoP signature against the negotiated (v1 or v2) signable
 * payload. Throws 401 `legacy_pop_required` if the pinned public key is the
 * wrong byte length and 401 `bad_pop_signature` if the signature does not verify.
 */
function verifyPopSignature(
  req: HttpRequest,
  client: HermesGatewayClientDoc,
  tokenHash: string,
  headers: VerifiedPopHeaders,
): void {
  const publicKeyRaw = Buffer.from(client.agentClientSigningPublicKeyBase64 ?? "", "base64");
  if (publicKeyRaw.length !== ED25519_PUBLIC_KEY_BYTE_LENGTH) {
    throw httpError(401, "legacy_pop_required");
  }
  const publicKey = createPublicKey({
    key: Buffer.concat([ED25519_SPKI_DER_PREFIX, publicKeyRaw]),
    format: "der",
    type: "spki",
  });
  const payload =
    gatewayPopVersion(req) >= 2
      ? gatewayPopSignablePayloadV2({
          tokenHash,
          method: req.method ?? "GET",
          path: gatewayPath(req),
          query: canonicalGatewayQueryString(req),
          bodyHash: headers.suppliedBodyHash,
          nonce: headers.nonce,
          timestamp: headers.timestamp,
        })
      : gatewayPopSignablePayload({
          tokenHash,
          method: req.method ?? "GET",
          path: gatewayPath(req),
          bodyHash: headers.suppliedBodyHash,
          nonce: headers.nonce,
          timestamp: headers.timestamp,
        });
  if (!verifySignature(null, payload, publicKey, headers.signature)) {
    throw httpError(401, "bad_pop_signature");
  }
}

/**
 * Single-use nonce guard: create the nonce doc inside a transaction so a replay
 * (existing doc) is rejected with 401. The TTL doc auto-expires past the skew
 * window. A pure relocation of the replay-guard suffix of verifyGatewayRequestPoP.
 */
async function recordPopNonce(
  uid: string,
  clientId: string,
  tokenHash: string,
  headers: VerifiedPopHeaders,
): Promise<void> {
  const nonceRef = db.doc(`users/${uid}/hermes_gateway_clients/${clientId}/pop_nonces/${headers.nonce}`);
  await db.runTransaction(async (transaction) => {
    const snap = await transaction.get(nonceRef);
    if (snap.exists) {
      throw httpError(401, "pop_nonce_replay");
    }
    transaction.create(nonceRef, {
      nonce: headers.nonce,
      tokenHash,
      observedAt: nowISO(),
      expireAt: Timestamp.fromMillis(Math.max(Date.now(), headers.timestampMillis) + GATEWAY_POP_CLOCK_SKEW_MS),
      schemaVersion: HERMES_GATEWAY_SCHEMA_VERSION,
    });
  });
}

export async function verifyGatewayRequestPoP(
  req: HttpRequest,
  options: { uid: string; clientId: string; client: HermesGatewayClientDoc; tokenHash: string },
): Promise<void> {
  if (!options.client.agentClientSigningPublicKeyBase64 || options.client.popRequired !== true) {
    throw httpError(401, "legacy_pop_required");
  }
  const headers = parseVerifiedPopHeaders(req, options.client);
  verifyPopSignature(req, options.client, options.tokenHash, headers);
  await recordPopNonce(options.uid, options.clientId, options.tokenHash, headers);
}
