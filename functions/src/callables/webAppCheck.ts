/**
 * @fileoverview registerBrowserEscrowDevice — let a web browser join the escrow
 * trust circle so burnbar.ai can decrypt end-to-end data in-browser AFTER a
 * trusted native device approves it.
 *
 * Trust model (server NEVER sees the vault key):
 *   1. The browser generates an ECDH/ECDSA keypair in the Web Crypto API
 *      (non-extractable private key) and POSTs its PUBLIC P-256 JWK here,
 *      gated by Firebase App Check (reCAPTCHA Enterprise on web).
 *   2. This callable registers a PENDING escrow device (platform "Web") plus its
 *      public key, exactly like registerEscrowDevice does for native devices.
 *   3. The user opens a TRUSTED native device (Mac/iPhone) and approves it via
 *      the existing approveEscrowDeviceTrust callable, which flips trustState to
 *      "trusted" and lets that device mint a cloud_vault_key_wrapper (the vault
 *      key wrapped to the browser's public key). The browser unwraps it locally.
 *
 * This file owns ONLY the browser registration step; approval + wrapper minting
 * reuse the already-shipped escrow callables (computerUseSecurity.ts) and rules.
 */

import { FieldValue } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { createHash } from "node:crypto";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import { boundedTrimmedString } from "./shared.js";
import { stripUndefinedObject } from "../guards.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const ESCROW_WEB_PLATFORM = "Web";
const P256_COORDINATE_LENGTH = 32;
const P256_X963_LENGTH = 65;

interface ParsedJwk {
  jwk: Record<string, unknown>;
  fingerprint: string;
  publicKeyDataBase64: string;
  canonical: string;
}

function base64UrlDecode(raw: unknown, fieldName: string): Buffer {
  if (typeof raw !== "string" || raw.length === 0 || !/^[A-Za-z0-9_-]+$/u.test(raw)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be base64url.`);
  }
  const decoded = Buffer.from(raw, "base64url");
  if (decoded.length !== P256_COORDINATE_LENGTH) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a P-256 coordinate.`);
  }
  return decoded;
}

/**
 * Validate a public-key JWK: it must be a P-256 ECDH public key and must not
 * include private material. Returns the native-compatible X9.63 public key bytes
 * as base64 plus the same base64 SHA-256 fingerprint native devices publish.
 */
function parsePublicKeyJwk(raw: unknown): ParsedJwk {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", "publicKeyJwk must be a JWK object.");
  }
  const jwk = raw as Record<string, unknown>;
  const kty = typeof jwk.kty === "string" ? jwk.kty : "";
  const crv = typeof jwk.crv === "string" ? jwk.crv : "";
  if (kty !== "EC" || crv !== "P-256") {
    throw new HttpsError("invalid-argument", "publicKeyJwk must be an EC P-256 public key.");
  }
  // Reject any private-key material — only public keys may be uploaded.
  for (const privateField of ["d", "p", "q", "dp", "dq", "qi", "k"]) {
    if (privateField in jwk) {
      throw new HttpsError("invalid-argument", "publicKeyJwk must not contain private key material.");
    }
  }
  const x = base64UrlDecode(jwk.x, "publicKeyJwk.x");
  const y = base64UrlDecode(jwk.y, "publicKeyJwk.y");
  const publicKeyData = Buffer.concat([Buffer.from([0x04]), x, y]);
  if (publicKeyData.length !== P256_X963_LENGTH) {
    throw new HttpsError("invalid-argument", "publicKeyJwk must export a 65-byte X9.63 public key.");
  }
  const sanitized = stripUndefinedObject({
    kty: "EC",
    crv: "P-256",
    x: jwk.x,
    y: jwk.y,
    ext: jwk.ext === true ? true : undefined,
    key_ops: Array.isArray(jwk.key_ops)
      ? jwk.key_ops.filter((v): v is string => typeof v === "string").slice(0, 4)
      : undefined,
  });
  const canonical = JSON.stringify(sanitized);
  const fingerprint = createHash("sha256").update(publicKeyData).digest("base64");
  return {
    jwk: sanitized,
    fingerprint,
    publicKeyDataBase64: publicKeyData.toString("base64"),
    canonical,
  };
}

/** Test-only surface for the pure JWK validator (no Firestore). */
export const __testing__ = {
  ESCROW_WEB_PLATFORM,
  parsePublicKeyJwk,
};

export const registerBrowserEscrowDevice = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler(
    "registerBrowserEscrowDevice",
    async (request: CallableRequest<{ publicKeyJwk?: unknown; deviceName?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before registering a browser for escrow.");
      // App Check (reCAPTCHA Enterprise on web) is the bot/device attestation.
      // Ownership + Auth + App Check are enforced here.
      enforceAuthAndAppCheck(request, uid);

      const { jwk, fingerprint, publicKeyDataBase64 } = parsePublicKeyJwk(request.data?.publicKeyJwk);
      const deviceName =
        boundedTrimmedString(request.data?.deviceName, "deviceName", 256, false) ?? "Browser (burnbar.ai)";
      const escrowDeviceId = `web_${createHash("sha256").update(fingerprint).digest("hex").slice(0, 24)}`;

      const deviceRef = db.doc(`users/${uid}/escrow_devices/${escrowDeviceId}`);
      const existing = await deviceRef.get();
      if (existing.exists && existing.get("trustState") === "trusted") {
        // Idempotent: an already-approved browser re-registering stays trusted.
        return { ok: true, escrowDeviceId, status: "trusted" };
      }

      const devicePayload: Record<string, unknown> = {
        deviceId: escrowDeviceId,
        deviceName,
        platform: ESCROW_WEB_PLATFORM,
        trustState: "pending",
        publicKeyFingerprint: fingerprint,
        keyVersion: 1,
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (!existing.exists) devicePayload.createdAt = FieldValue.serverTimestamp();

      const publicKeyRef = db.doc(`users/${uid}/escrow_public_keys/${escrowDeviceId}_1`);
      const batch = db.batch();
      batch.set(deviceRef, devicePayload, { merge: true });
      batch.set(
        publicKeyRef,
        stripUndefinedObject({
          deviceId: escrowDeviceId,
          platform: ESCROW_WEB_PLATFORM,
          fingerprint,
          publicKeyFingerprint: fingerprint,
          publicKeyData: publicKeyDataBase64,
          publicKeyJwk: jwk,
          keyVersion: 1,
          algorithm: "ECIES-P256-AESGCM",
          createdAt: existing.exists ? undefined : FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        }),
        { merge: true },
      );
      await batch.commit();

      logInfo({
        event: "callable_info",
        message: "browser_escrow_device_registered",
        device_id: escrowDeviceId,
        platform: ESCROW_WEB_PLATFORM,
      });

      return { ok: true, escrowDeviceId, status: "pending" };
    },
  ),
);
