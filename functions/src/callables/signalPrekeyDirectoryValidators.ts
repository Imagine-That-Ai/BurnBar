/**
 * @fileoverview Pure validators + Firestore-doc builders for the L41 Signal
 * prekey/session directory callables. Split out of signalPrekeyDirectory.ts to
 * keep each module under the per-file line ceiling. These helpers NEVER touch
 * Firestore so they unit-test the fail-closed shape the same way
 * signalAtRestWrite.ts does. See signalPrekeyDirectory.ts for the runtime glue
 * and the full design rationale.
 */

import { Timestamp } from "firebase-admin/firestore";
import type { DocumentData } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { boundedTrimmedString, safeCloudDocumentID, requireBoundedNumber } from "./shared.js";

// ---------------------------------------------------------------------------
// Constants mirrored from firestore.rules / the L41 design doc.
// ---------------------------------------------------------------------------

const SIGNED_PREKEY_ALGORITHM = "signal-pqxdh-signed-prekey-v1";
const ONE_TIME_PREKEY_ALGORITHM = "signal-pqxdh-one-time-prekey-v1";
const KYBER_PREKEY_ALGORITHM = "signal-pqxdh-kyber-prekey-v1";

// Fail-closed to the documented scope: only same-user multi-device sessions are
// accepted. A cross-user "gateway-transport" mode is a deliberate FUTURE
// extension and must NOT be accepted until that feature ships with its own
// cross-user authorization checks.
const SESSION_MODES = new Set(["same-user-device"]);
const ROTATION_REASONS = new Set(["scheduled", "suspected_compromise", "device_repair", "revocation_rewrap", "manual"]);

const MAX_INT32 = 2147483647;
// Per-call batch ceilings. Kyber bundles are large (PQXDH) so they are smaller.
export const MAX_ONE_TIME_PREKEYS_PER_CALL = 100;
export const MAX_KYBER_PREKEYS_PER_CALL = 20;
// Reject expiries beyond ~13 months out (matches a generous prekey rotation).
const MAX_PREKEY_TTL_MS = 400 * 24 * 60 * 60 * 1000;

// Below these counts the device should publish more prekeys (one-time prekeys are
// consumed one-per-inbound-session; Kyber is mandatory for PQXDH).
export const MIN_AVAILABLE_ONE_TIME_PREKEYS = 10;
export const MIN_AVAILABLE_KYBER_PREKEYS = 3;

// Forbidden secret/private/session-state fields — a SUPERSET of the union of
// hasNoPlaintextSecretFields() (firestore.rules:56-69) and
// signalDirectoryDocumentLimits() (firestore.rules:3564-3574). Verified against
// those line ranges; "privateKey" is an extra (harmless) superset member.
export const FORBIDDEN_FIELDS = [
  "apiKey",
  "token",
  "refreshToken",
  "accessToken",
  "idToken",
  "cookie",
  "password",
  "secret",
  "secretVersionName",
  "authorization",
  "bearer",
  "credential",
  "privateKey",
  "privateKeyData",
  "privateKeyB64",
  "serializedSession",
  "serializedSessionB64",
  "sessionState",
  "sessionStateB64",
  "ratchetState",
  "ratchetStateB64",
] as const;

// ---------------------------------------------------------------------------
// Pure validators (exported via signalPrekeyDirectory's __testing__). These
// never touch Firestore so they unit-test the fail-closed shape the same way
// signalAtRestWrite.ts does.
// ---------------------------------------------------------------------------

interface DirectoryContext {
  identityKeyId: string;
  deviceId: string;
  keyVersion: number;
}

/** Mirror firestore.rules validSignalBase64(value, maxLen). */
export function parseSignalBase64(raw: unknown, fieldName: string, maxLen: number): string {
  if (typeof raw !== "string") {
    throw new HttpsError("invalid-argument", `${fieldName} must be a base64 string.`);
  }
  if (raw.length === 0 || raw.length > maxLen || raw.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/u.test(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be canonical base64 (<= ${maxLen} chars).`);
  }
  return raw;
}

/** Reject any payload carrying a secret/private/session-state field. */
export function assertNoForbiddenFields(raw: Record<string, unknown>, fieldName: string): void {
  for (const forbidden of FORBIDDEN_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(raw, forbidden)) {
      throw new HttpsError("invalid-argument", `${fieldName} must not contain private or secret field "${forbidden}".`);
    }
  }
}

/** Convert a client epoch-ms expiry into a future-bounded Timestamp. */
export function parseFutureExpiry(
  raw: unknown,
  fieldName: string,
  nowMs: number,
  required: boolean,
): Timestamp | undefined {
  if (raw === undefined || raw === null) {
    if (required) throw new HttpsError("invalid-argument", `${fieldName} is required.`);
    return undefined;
  }
  const ms = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(ms)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be an epoch-millisecond number.`);
  }
  const floored = Math.floor(ms);
  if (floored <= nowMs) {
    throw new HttpsError("invalid-argument", `${fieldName} must be in the future.`);
  }
  if (floored > nowMs + MAX_PREKEY_TTL_MS) {
    throw new HttpsError("invalid-argument", `${fieldName} is too far in the future.`);
  }
  return Timestamp.fromMillis(floored);
}

function requireFutureExpiry(raw: unknown, fieldName: string, nowMs: number): Timestamp {
  const expiresAt = parseFutureExpiry(raw, fieldName, nowMs, true);
  if (!expiresAt) throw new HttpsError("invalid-argument", `${fieldName} is required.`);
  return expiresAt;
}

/** Build the persisted signed-prekey doc body (minus server createdAt/updatedAt). */
export function buildSignedPreKeyDoc(
  raw: Record<string, unknown>,
  ctx: DirectoryContext,
  nowMs: number,
): { id: string; data: DocumentData } {
  assertNoForbiddenFields(raw, "signedPreKey");
  const signedPreKeyId = safeCloudDocumentID(raw.signedPreKeyId, "signedPreKey.signedPreKeyId");
  const signedPreKeyNumericId = requireBoundedNumber(
    raw.signedPreKeyNumericId,
    "signedPreKey.signedPreKeyNumericId",
    1,
    MAX_INT32,
  );
  const expiresAt = parseFutureExpiry(raw.expiresAt, "signedPreKey.expiresAt", nowMs, false);
  const data: DocumentData = {
    signedPreKeyId,
    signedPreKeyNumericId,
    identityKeyId: ctx.identityKeyId,
    deviceId: ctx.deviceId,
    keyVersion: ctx.keyVersion,
    publicKeyB64: parseSignalBase64(raw.publicKeyB64, "signedPreKey.publicKeyB64", 256),
    signatureB64: parseSignalBase64(raw.signatureB64, "signedPreKey.signatureB64", 512),
    algorithm: SIGNED_PREKEY_ALGORITHM,
    status: "active",
  };
  if (expiresAt) data.expiresAt = expiresAt;
  return { id: signedPreKeyId, data };
}

/** Build a one-time-prekey doc body (expiresAt REQUIRED, status available). */
export function buildOneTimePreKeyDoc(
  raw: Record<string, unknown>,
  ctx: DirectoryContext,
  nowMs: number,
): { id: string; data: DocumentData } {
  assertNoForbiddenFields(raw, "oneTimePreKey");
  const oneTimePreKeyId = safeCloudDocumentID(raw.oneTimePreKeyId, "oneTimePreKey.oneTimePreKeyId");
  const oneTimePreKeyNumericId = requireBoundedNumber(
    raw.oneTimePreKeyNumericId,
    "oneTimePreKey.oneTimePreKeyNumericId",
    1,
    MAX_INT32,
  );
  const expiresAt = requireFutureExpiry(raw.expiresAt, "oneTimePreKey.expiresAt", nowMs);
  return {
    id: oneTimePreKeyId,
    data: {
      oneTimePreKeyId,
      oneTimePreKeyNumericId,
      identityKeyId: ctx.identityKeyId,
      deviceId: ctx.deviceId,
      keyVersion: ctx.keyVersion,
      publicKeyB64: parseSignalBase64(raw.publicKeyB64, "oneTimePreKey.publicKeyB64", 256),
      algorithm: ONE_TIME_PREKEY_ALGORITHM,
      status: "available",
      expiresAt,
    },
  };
}

/** Build a Kyber-prekey doc body (mandatory for PQXDH; larger base64 bounds). */
export function buildKyberPreKeyDoc(
  raw: Record<string, unknown>,
  ctx: DirectoryContext,
  nowMs: number,
): { id: string; data: DocumentData } {
  assertNoForbiddenFields(raw, "kyberPreKey");
  const kyberPreKeyId = safeCloudDocumentID(raw.kyberPreKeyId, "kyberPreKey.kyberPreKeyId");
  const kyberPreKeyNumericId = requireBoundedNumber(
    raw.kyberPreKeyNumericId,
    "kyberPreKey.kyberPreKeyNumericId",
    1,
    MAX_INT32,
  );
  const expiresAt = requireFutureExpiry(raw.expiresAt, "kyberPreKey.expiresAt", nowMs);
  return {
    id: kyberPreKeyId,
    data: {
      kyberPreKeyId,
      kyberPreKeyNumericId,
      identityKeyId: ctx.identityKeyId,
      deviceId: ctx.deviceId,
      keyVersion: ctx.keyVersion,
      publicKeyB64: parseSignalBase64(raw.publicKeyB64, "kyberPreKey.publicKeyB64", 4096),
      signatureB64: parseSignalBase64(raw.signatureB64, "kyberPreKey.signatureB64", 4096),
      algorithm: KYBER_PREKEY_ALGORITHM,
      status: "available",
      expiresAt,
    },
  };
}

/** Build a session-directory metadata doc (never serialized session state). */
export function buildSessionDoc(
  raw: Record<string, unknown>,
  ctx: DirectoryContext,
  ownerUid: string,
): { id: string; data: DocumentData } {
  assertNoForbiddenFields(raw, "session");
  const sessionId = safeCloudDocumentID(raw.sessionId, "session.sessionId");
  const mode = boundedTrimmedString(raw.mode, "session.mode", 40, true);
  if (!SESSION_MODES.has(mode)) {
    throw new HttpsError("invalid-argument", `session.mode must be one of: ${[...SESSION_MODES].join(", ")}.`);
  }
  // Scope is same-user multi-device only: the peer is another device of the SAME
  // account, so when a peerUid is asserted it MUST equal the owner. This blocks a
  // caller from registering a session doc that names an arbitrary other user as
  // the peer (fail-closed to the documented scope; cross-user sessions are not
  // an accepted mode yet — see SESSION_MODES).
  const peerUid = boundedTrimmedString(raw.peerUid, "session.peerUid", 160, true);
  if (peerUid && peerUid !== ownerUid) {
    throw new HttpsError(
      "invalid-argument",
      "session.peerUid must be the same account (same-user multi-device scope).",
    );
  }
  return {
    id: sessionId,
    data: {
      sessionId,
      identityKeyId: ctx.identityKeyId,
      deviceId: ctx.deviceId,
      keyVersion: ctx.keyVersion,
      peerUid,
      peerDeviceId: boundedTrimmedString(raw.peerDeviceId, "session.peerDeviceId", 160, true),
      peerIdentityKeyId: boundedTrimmedString(raw.peerIdentityKeyId, "session.peerIdentityKeyId", 200, true),
      mode,
      stateStorage: "device-local-only",
      status: "active",
    },
  };
}

/** Build a rotation-event doc (append-only; status planned). */
export function buildRotationEventDoc(
  raw: Record<string, unknown>,
  ctx: DirectoryContext,
  rewrapJobId: string | undefined,
): { id: string; data: DocumentData } {
  assertNoForbiddenFields(raw, "rotation");
  const rotationId = safeCloudDocumentID(raw.rotationId, "rotation.rotationId");
  const fromKeyVersion = requireBoundedNumber(raw.fromKeyVersion, "rotation.fromKeyVersion", 1, 10);
  const toKeyVersion = requireBoundedNumber(raw.toKeyVersion, "rotation.toKeyVersion", 2, 10);
  if (toKeyVersion <= fromKeyVersion) {
    throw new HttpsError("invalid-argument", "rotation.toKeyVersion must be greater than fromKeyVersion.");
  }
  const reason = boundedTrimmedString(raw.reason, "rotation.reason", 40, true);
  if (!ROTATION_REASONS.has(reason)) {
    throw new HttpsError("invalid-argument", `rotation.reason must be one of: ${[...ROTATION_REASONS].join(", ")}.`);
  }
  const rewrapRequired = raw.rewrapRequired === true;
  const data: DocumentData = {
    rotationId,
    identityKeyId: ctx.identityKeyId,
    deviceId: ctx.deviceId,
    keyVersion: ctx.keyVersion,
    fromKeyVersion,
    toKeyVersion,
    reason,
    status: "planned",
    rewrapRequired,
  };
  if (rewrapRequired && rewrapJobId) data.rewrapJobId = rewrapJobId;
  if (raw.revokedIdentityKeyId !== undefined) {
    data.revokedIdentityKeyId = boundedTrimmedString(
      raw.revokedIdentityKeyId,
      "rotation.revokedIdentityKeyId",
      200,
      true,
    );
  }
  return { id: rotationId, data };
}

/**
 * Decide which available prekey to claim from a candidate list. Pure so the
 * single-claim selection is unit-testable independent of the transaction. Picks
 * the lowest numericId for deterministic, gap-free consumption.
 */
export function selectPrekeyToClaim<T extends { numericId: number; id: string }>(candidates: T[]): T | undefined {
  if (candidates.length === 0) return undefined;
  return [...candidates].sort((a, b) => a.numericId - b.numericId || a.id.localeCompare(b.id))[0];
}

/** Pure low-watermark decision so a recipient device knows when to replenish. */
export function prekeyReplenishStatus(
  availableOneTime: number,
  availableKyber: number,
): { needsReplenish: boolean; lowOneTime: boolean; lowKyber: boolean } {
  const lowOneTime = availableOneTime < MIN_AVAILABLE_ONE_TIME_PREKEYS;
  const lowKyber = availableKyber < MIN_AVAILABLE_KYBER_PREKEYS;
  return { needsReplenish: lowOneTime || lowKyber, lowOneTime, lowKyber };
}
