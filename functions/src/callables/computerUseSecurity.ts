/**
 * @fileoverview Computer Use / escrow high-risk callables (WS4 cloud defense-in-depth).
 *
 * Trust elevation and grant-adjacent mutations route through App-Check-enforced
 * callables with attestation-bound Auth custom claims instead of direct client
 * Firestore writes to `trustState: trusted`.
 */

import { createHash, createPublicKey, timingSafeEqual } from "node:crypto";

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
import { logInfo, logWarn, onCallProduction, wrapCallableHandler } from "../logging.js";
import { boundedTrimmedString } from "./shared.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { revokeSignalSessionsForDevice } from "../signalDirectoryRuntime.js";

const ESCROW_PLATFORMS = new Set(["macOS", "iOS", "iPadOS", "Android"]);
const ESCROW_WEB_PLATFORM = "Web";
const MAC_ESCROW_PLATFORMS = new Set(["macOS"]);
const PHONE_CONTROL_ESCROW_PLATFORMS = new Set(["iOS", "iPadOS", "Android"]);

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
    async (request: CallableRequest<{ deviceId?: unknown; approverDeviceId?: unknown; nonce?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before approving device trust.");
      await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);

      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
      const approverDeviceId = boundedTrimmedString(request.data.approverDeviceId, "approverDeviceId", 160, false);
      const ref = db.doc(`users/${uid}/escrow_devices/${deviceId}`);
      const result = await db.runTransaction(async (transaction) => {
        const snapshot = await transaction.get(ref);
        if (!snapshot.exists) {
          throw new HttpsError("not-found", "Escrow device is not registered.");
        }
        const platform = snapshot.get("platform");
        const trustState = snapshot.get("trustState");
        if (trustState === "trusted") {
          return { alreadyTrusted: true, approvedByDeviceId: snapshot.get("approvedByDeviceId") as string | undefined };
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
        const keyVersion =
          typeof snapshot.get("keyVersion") === "number" && Number.isInteger(snapshot.get("keyVersion"))
            ? (snapshot.get("keyVersion") as number)
            : 1;
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

        transaction.set(
          ref,
          {
            trustState: "trusted",
            approvedAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
            approvedByDeviceId,
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
    const publishedAtMillis =
      boundedInteger(request.data.publishedAtMillis ?? Date.now(), "publishedAtMillis", 1, Number.MAX_SAFE_INTEGER, true) ?? Date.now();
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
};
