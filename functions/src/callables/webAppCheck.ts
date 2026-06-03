/**
 * @fileoverview registerBrowserEscrowDevice — let a web browser join the escrow
 * trust circle so burnbar.ai can decrypt end-to-end data in-browser AFTER a
 * trusted native device approves it.
 *
 * Trust model (server NEVER sees the vault key):
 *   1. The browser generates an ECDH/ECDSA keypair in the Web Crypto API
 *      (non-extractable private key) and POSTs its PUBLIC key JWK here, gated by
 *      Firebase App Check (reCAPTCHA Enterprise on web) + a recaptchaToken bot
 *      signal.
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
import { createHash, randomBytes } from "node:crypto";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import { boundedTrimmedString } from "./shared.js";
import { stripUndefinedObject } from "../guards.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const ESCROW_WEB_PLATFORM = "Web";
const MAX_JWK_FIELD = 4096;

/** Supported web-crypto JWK key types for browser escrow public keys. */
const ALLOWED_JWK_KTY = new Set(["EC", "RSA", "OKP"]);

interface ParsedJwk {
  jwk: Record<string, unknown>;
  fingerprint: string;
  canonical: string;
}

/**
 * Validate a public-key JWK: must be a public key (no private components), a
 * supported kty, and within size bounds. Returns a canonical string +
 * SHA-256 fingerprint used as the escrow public-key id.
 */
function parsePublicKeyJwk(raw: unknown): ParsedJwk {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", "publicKeyJwk must be a JWK object.");
  }
  const jwk = raw as Record<string, unknown>;
  const kty = typeof jwk.kty === "string" ? jwk.kty : "";
  if (!ALLOWED_JWK_KTY.has(kty)) {
    throw new HttpsError("invalid-argument", "publicKeyJwk.kty must be EC, RSA, or OKP.");
  }
  // Reject any private-key material — only public keys may be uploaded.
  for (const privateField of ["d", "p", "q", "dp", "dq", "qi", "k"]) {
    if (privateField in jwk) {
      throw new HttpsError("invalid-argument", "publicKeyJwk must not contain private key material.");
    }
  }
  // Bound every string field to keep the doc small.
  const sanitized: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(jwk)) {
    if (typeof value === "string") {
      if (value.length > MAX_JWK_FIELD) {
        throw new HttpsError("invalid-argument", `publicKeyJwk.${key} is too large.`);
      }
      sanitized[key] = value;
    } else if (typeof value === "boolean" || typeof value === "number") {
      sanitized[key] = value;
    } else if (Array.isArray(value)) {
      sanitized[key] = value.filter((v): v is string => typeof v === "string").slice(0, 16);
    }
  }
  // Canonicalize on sorted keys so the fingerprint is stable.
  const canonical = JSON.stringify(
    Object.fromEntries(Object.entries(sanitized).sort(([a], [b]) => a.localeCompare(b))),
  );
  const fingerprint = createHash("sha256").update(canonical).digest("hex");
  return { jwk: sanitized, fingerprint, canonical };
}

/** Test-only surface for the pure JWK validator (no Firestore). */
export const __testing__ = {
  ESCROW_WEB_PLATFORM,
  ALLOWED_JWK_KTY,
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
    async (
      request: CallableRequest<{ publicKeyJwk?: unknown; recaptchaToken?: unknown; deviceName?: unknown }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before registering a browser for escrow.");
      // App Check (reCAPTCHA Enterprise on web) is the primary attestation; the
      // recaptchaToken below is an additional bot signal carried for the web
      // surface. Ownership + Auth + App Check are enforced here.
      enforceAuthAndAppCheck(request, uid);

      // recaptchaToken is required on the web surface as a defense-in-depth bot
      // signal. We validate it is present + well-formed; full reCAPTCHA Enterprise
      // assessment is performed by App Check's web provider upstream.
      const recaptchaToken = boundedTrimmedString(request.data?.recaptchaToken, "recaptchaToken", 4096, true);
      if (recaptchaToken.length < 8) {
        throw new HttpsError("invalid-argument", "recaptchaToken is invalid.");
      }

      const { jwk, fingerprint } = parsePublicKeyJwk(request.data?.publicKeyJwk);
      const deviceName =
        boundedTrimmedString(request.data?.deviceName, "deviceName", 256, false) ?? "Browser (burnbar.ai)";
      const escrowDeviceId = `web_${fingerprint.slice(0, 24)}`;

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

      const publicKeyRef = db.doc(`users/${uid}/escrow_public_keys/${escrowDeviceId}`);
      const batch = db.batch();
      batch.set(deviceRef, devicePayload, { merge: true });
      batch.set(
        publicKeyRef,
        stripUndefinedObject({
          deviceId: escrowDeviceId,
          platform: ESCROW_WEB_PLATFORM,
          fingerprint,
          publicKeyJwk: jwk,
          keyVersion: 1,
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

      // Note: the browser uses an opaque, deterministic id derived from its
      // public-key fingerprint so re-registration is idempotent and the
      // approving native device can match it. randomBytes kept available for any
      // future per-session nonce needs.
      void randomBytes;

      return { ok: true, escrowDeviceId, status: "pending" };
    },
  ),
);
