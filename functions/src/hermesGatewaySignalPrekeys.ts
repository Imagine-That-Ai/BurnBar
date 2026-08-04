/**
 * @fileoverview Strict public-PQXDH bundle parsing for Hermes Gateway pairing.
 *
 * The Gateway is a blind exchange point: it stores only public libsignal
 * identity/prekey material and never receives private keys or session records.
 * Identity material is pinned by the route layer; a later bundle may rotate the
 * one-time prekeys only when the identity key remains byte-identical.
 */

import { Buffer } from "node:buffer";

import { recordOrUndefined } from "./guards.js";
import type { HermesGatewaySignalPrekeyBundleDoc } from "./types/generated/hermes-gateway.js";

const SIGNAL_PREKEY_BUNDLE_VERSION = 1;
const SIGNAL_EC_PUBLIC_KEY_BYTES = 33;
const SIGNAL_SIGNATURE_BYTES = 64;
const SIGNAL_KYBER_PUBLIC_KEY_BYTES = 1_569;
const SIGNAL_REGISTRATION_ID_MAX = 16_383;
const SIGNAL_DEVICE_ID_MAX = 127;
const SIGNAL_PREKEY_ID_MAX = 2_147_483_647;
const SIGNAL_SAFE_ID = /^[A-Za-z0-9_-]{8,160}$/u;

type SignalPrekeyPrefix = "agent" | "phone";

type ThrowSignalPrekeyError = (message: string) => never;

function canonicalBase64(raw: unknown, exactBytes: number): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || !/^[A-Za-z0-9+/]+={0,2}$/u.test(value)) return undefined;
  let bytes: Buffer;
  try {
    bytes = Buffer.from(value, "base64");
  } catch {
    return undefined;
  }
  if (bytes.length !== exactBytes || bytes.toString("base64") !== value) return undefined;
  return value;
}

function safeID(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  return SIGNAL_SAFE_ID.test(value) ? value : undefined;
}

function boundedInteger(raw: unknown, min: number, max: number): number | undefined {
  const value = typeof raw === "number" ? raw : Number(raw);
  return Number.isSafeInteger(value) && value >= min && value <= max ? value : undefined;
}

function canonicalTimestamp(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  const millis = Date.parse(value);
  if (!Number.isFinite(millis)) return undefined;
  const canonical = new Date(millis).toISOString();
  return value === canonical ? canonical : undefined;
}

function bundleField(body: Record<string, unknown>, prefix: SignalPrekeyPrefix): unknown {
  return body[`${prefix}SignalPrekeyBundle`] ?? body.signalPrekeyBundle;
}

/** Parse one endpoint's exact official-libsignal PQXDH public bundle. */
export function parseGatewaySignalPrekeyBundle(
  body: Record<string, unknown>,
  prefix: SignalPrekeyPrefix,
  throwError: ThrowSignalPrekeyError,
): HermesGatewaySignalPrekeyBundleDoc | undefined {
  const raw = bundleField(body, prefix);
  if (raw == null) return undefined;
  const record = recordOrUndefined(raw);
  if (!record) throwError(`${prefix}SignalPrekeyBundle must be an object.`);

  const version = boundedInteger(record.version, SIGNAL_PREKEY_BUNDLE_VERSION, SIGNAL_PREKEY_BUNDLE_VERSION);
  const bundleId = safeID(record.bundleId);
  const identityKeyId = safeID(record.identityKeyId);
  const identityKeyB64 = canonicalBase64(record.identityKeyB64, SIGNAL_EC_PUBLIC_KEY_BYTES);
  const registrationId = boundedInteger(record.registrationId, 1, SIGNAL_REGISTRATION_ID_MAX);
  const deviceId = boundedInteger(record.deviceId, 1, SIGNAL_DEVICE_ID_MAX);
  const signedPreKeyId = boundedInteger(record.signedPreKeyId, 1, SIGNAL_PREKEY_ID_MAX);
  const signedPreKeyPublicB64 = canonicalBase64(record.signedPreKeyPublicB64, SIGNAL_EC_PUBLIC_KEY_BYTES);
  const signedPreKeySignatureB64 = canonicalBase64(record.signedPreKeySignatureB64, SIGNAL_SIGNATURE_BYTES);
  const oneTimePreKeyId = boundedInteger(record.oneTimePreKeyId, 1, SIGNAL_PREKEY_ID_MAX);
  const oneTimePreKeyPublicB64 = canonicalBase64(record.oneTimePreKeyPublicB64, SIGNAL_EC_PUBLIC_KEY_BYTES);
  const kyberPreKeyId = boundedInteger(record.kyberPreKeyId, 1, SIGNAL_PREKEY_ID_MAX);
  const kyberPreKeyPublicB64 = canonicalBase64(record.kyberPreKeyPublicB64, SIGNAL_KYBER_PUBLIC_KEY_BYTES);
  const kyberPreKeySignatureB64 = canonicalBase64(record.kyberPreKeySignatureB64, SIGNAL_SIGNATURE_BYTES);
  const generatedAt = canonicalTimestamp(record.generatedAt);

  if (version === undefined) throwError(`${prefix}SignalPrekeyBundle.version must be 1.`);
  if (!bundleId) throwError(`${prefix}SignalPrekeyBundle.bundleId must be a safe 8-160 character identifier.`);
  if (!identityKeyId) {
    throwError(`${prefix}SignalPrekeyBundle.identityKeyId must be a safe 8-160 character identifier.`);
  }
  if (!identityKeyB64) {
    throwError(`${prefix}SignalPrekeyBundle.identityKeyB64 must be canonical base64 for a 33-byte Signal public key.`);
  }
  if (registrationId === undefined) {
    throwError(`${prefix}SignalPrekeyBundle.registrationId must be an integer from 1 through 16383.`);
  }
  if (deviceId === undefined) {
    throwError(`${prefix}SignalPrekeyBundle.deviceId must be an integer from 1 through 127.`);
  }
  if (signedPreKeyId === undefined || !signedPreKeyPublicB64 || !signedPreKeySignatureB64) {
    throwError(`${prefix}SignalPrekeyBundle signed prekey fields are invalid.`);
  }
  if (oneTimePreKeyId === undefined || !oneTimePreKeyPublicB64) {
    throwError(`${prefix}SignalPrekeyBundle one-time prekey fields are invalid.`);
  }
  if (kyberPreKeyId === undefined || !kyberPreKeyPublicB64 || !kyberPreKeySignatureB64) {
    throwError(`${prefix}SignalPrekeyBundle Kyber prekey fields are invalid.`);
  }
  if (!generatedAt) {
    throwError(`${prefix}SignalPrekeyBundle.generatedAt must be a canonical ISO-8601 timestamp.`);
  }

  return {
    version: SIGNAL_PREKEY_BUNDLE_VERSION,
    bundleId,
    identityKeyId,
    identityKeyB64,
    registrationId,
    deviceId,
    signedPreKeyId,
    signedPreKeyPublicB64,
    signedPreKeySignatureB64,
    oneTimePreKeyId,
    oneTimePreKeyPublicB64,
    kyberPreKeyId,
    kyberPreKeyPublicB64,
    kyberPreKeySignatureB64,
    generatedAt,
  };
}

/** True only when a replacement bundle preserves the pairing's identity pin. */
export function sameGatewaySignalIdentity(
  pinned: HermesGatewaySignalPrekeyBundleDoc,
  replacement: HermesGatewaySignalPrekeyBundleDoc,
): boolean {
  return (
    pinned.identityKeyId === replacement.identityKeyId &&
    pinned.identityKeyB64 === replacement.identityKeyB64 &&
    pinned.registrationId === replacement.registrationId &&
    pinned.deviceId === replacement.deviceId
  );
}
