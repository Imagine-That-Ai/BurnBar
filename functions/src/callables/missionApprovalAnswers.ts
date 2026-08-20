/**
 * Mac-signed single-use mission pre-auth. Functions never-widen; they do not
 * re-evaluate daemon grantCeiling.
 */

import { createHash, createPublicKey, createVerify, type KeyObject } from "node:crypto";

import { FieldValue } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { getConfig } from "../config.js";
import { recordOrUndefined } from "../guards.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { PHONE_CONTROL_ESCROW_PLATFORMS, boundedFirestoreDocumentId } from "./computerUseSecurityCodecs.js";
import {
  appendComputerUseAuditEvent,
  requireTrustedDeviceActionProof,
} from "./computerUseSecurityFirestore.js";
import { assertActiveBurnBarCloudProEntitlement, boundedTrimmedString } from "./shared.js";
import { assertCallableApprovalNotLocked, recordCallableApprovalFailure } from "./publicRateLimit.js";
import { verifyXEdDSACurve25519Signature } from "./computerUseSecurityCrypto.js";

const PHONE = PHONE_CONTROL_ESCROW_PLATFORMS;
const MAC = new Set(["macOS"]);
const MAX_TTL_MS = 24 * 60 * 60 * 1000;
const DEFAULT_TTL_MS = 60 * 60 * 1000;

export function canonicalCeilingBytes(fields: Record<string, unknown>): Buffer {
  const keys = [
    "missionID",
    "requestedGrant",
    "grantCeiling",
    "promptSHA256",
    "personaDigest",
    "requestedRuntime",
    "approvalMode",
    "issuedAt",
  ];
  const ordered: Record<string, unknown> = {};
  for (const key of keys) ordered[key] = fields[key];
  return Buffer.from(JSON.stringify(ordered), "utf8");
}

export function ceilingDigest(fields: Record<string, unknown>): string {
  return createHash("sha256").update(canonicalCeilingBytes(fields)).digest("hex");
}

function requestedIsSubsetOfCeiling(
  ceiling: { commandsAllowed?: boolean; fileEditsAllowed?: boolean; additionalCapabilities?: unknown },
  requested: { commandsAllowed?: boolean; fileEditsAllowed?: boolean; additionalCapabilities?: unknown },
): boolean {
  if (requested.commandsAllowed === true && ceiling.commandsAllowed !== true) return false;
  if (requested.fileEditsAllowed === true && ceiling.fileEditsAllowed !== true) return false;
  const ceilingCaps = new Set(
    Array.isArray(ceiling.additionalCapabilities) ? ceiling.additionalCapabilities.map(String) : [],
  );
  const requestedCaps = Array.isArray(requested.additionalCapabilities)
    ? requested.additionalCapabilities.map(String)
    : [];
  return requestedCaps.every((cap) => ceilingCaps.has(cap));
}

function looksLikePem(value: string): boolean {
  return value.includes("BEGIN") && value.includes("KEY");
}

function keyFromEscrowMaterial(raw: string): KeyObject {
  const trimmed = raw.trim();
  if (looksLikePem(trimmed)) {
    return createPublicKey(trimmed);
  }
  const asUtf8 = Buffer.from(trimmed, "base64").toString("utf8");
  if (looksLikePem(asUtf8)) {
    return createPublicKey(asUtf8);
  }
  const der = Buffer.from(trimmed, "base64");
  try {
    return createPublicKey({ key: der, format: "der", type: "spki" });
  } catch {
    return createPublicKey({ key: der, format: "der", type: "pkcs1" });
  }
}

async function resolveEscrowVerifyingKey(
  uid: string,
  deviceId: string,
  device: { get: (field: string) => unknown },
): Promise<KeyObject> {
  const pem = device.get("publicKeyPem");
  if (typeof pem === "string" && pem.trim()) return keyFromEscrowMaterial(pem);
  const b64 = device.get("publicKeyBase64");
  if (typeof b64 === "string" && b64.trim()) return keyFromEscrowMaterial(b64);
  const data = device.get("publicKeyData");
  if (typeof data === "string" && data.trim()) return keyFromEscrowMaterial(data);
  const keyVersion = typeof device.get("keyVersion") === "number" ? device.get("keyVersion") : 1;
  const stored = await db.doc(`users/${uid}/escrow_public_keys/${deviceId}_${keyVersion}`).get();
  const storedData = stored.get("publicKeyData");
  if (typeof storedData === "string" && storedData.trim()) return keyFromEscrowMaterial(storedData);
  throw new HttpsError("failed-precondition", "Escrow device is missing a verifying public key.");
}

async function verifyCeilingMacSignature(args: {
  uid: string;
  deviceId: string;
  device: { get: (field: string) => unknown };
  signature: string;
  bytes: Buffer;
}): Promise<boolean> {
  try {
    const publicKey = await resolveEscrowVerifyingKey(args.uid, args.deviceId, args.device);
    const verifier = createVerify("SHA256");
    verifier.update(args.bytes);
    if (verifier.verify(publicKey, args.signature, "base64")) return true;
  } catch {
    // No RSA/PEM escrow material, or verify threw — try published Signal identity.
  }
  const identityKeyId = args.device.get("targetSignalIdentityKeyId");
  if (typeof identityKeyId !== "string" || !identityKeyId.trim()) return false;
  const identity = await db.doc(`users/${args.uid}/signal_identity_public_keys/${identityKeyId}`).get();
  const keyB64 = identity.get("publicKeyData");
  if (typeof keyB64 !== "string" || !keyB64.trim()) return false;
  const publicKey = Buffer.from(keyB64.trim(), "base64");
  const sig = Buffer.from(args.signature, "base64");
  return verifyXEdDSACurve25519Signature(publicKey, args.bytes, sig);
}

export const publishMissionApprovalCeiling = onCallProduction(
  "publishMissionApprovalCeiling",
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 100 },
  async (request: CallableRequest<Record<string, unknown>>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Authentication is required.");
    const nonce = boundedTrimmedString(request.data.nonce, "nonce", 256, true);
    const deviceId = boundedFirestoreDocumentId(request.data.deviceId, "deviceId", 160);
    const requestId = boundedFirestoreDocumentId(request.data.requestId, "requestId", 160);
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, nonce);
    await requireTrustedDeviceActionProof({
      uid,
      deviceId,
      actionKind: "mission_approval_ceiling_publish",
      subjectId: requestId,
      approve: true,
      nonce,
      proofRaw: request.data.actionProof,
      allowedPlatforms: MAC,
    });
    const fields = recordOrUndefined(request.data.canonical) ?? {};
    const digest = boundedTrimmedString(request.data.ceilingDigest, "ceilingDigest", 64, true);
    if (ceilingDigest(fields) !== digest) {
      throw new HttpsError("invalid-argument", "ceilingDigest does not match canonical bytes.");
    }
    const signature = boundedTrimmedString(request.data.signature, "signature", 4096, true);
    const mission = await db.doc(`users/${uid}/cli_agent_mission_requests/${requestId}`).get();
    if (!mission.exists) throw new HttpsError("not-found", "Mission request was not found.");
    if (mission.get("claimedBy") !== deviceId) {
      throw new HttpsError("permission-denied", "Only the claiming Mac may publish a ceiling.");
    }
    const device = await db.doc(`users/${uid}/escrow_devices/${deviceId}`).get();
    const bytes = canonicalCeilingBytes(fields);
    const verified = await verifyCeilingMacSignature({
      uid,
      deviceId,
      device,
      signature,
      bytes,
    });
    if (!verified) {
      throw new HttpsError("permission-denied", "Mac signature did not verify.");
    }
    const gateKind = boundedTrimmedString(request.data.gateKind ?? "default", "gateKind", 40, true);
    await db.doc(`users/${uid}/mission_approval_ceilings/${requestId}`).set({
      requestId,
      claimedBy: deviceId,
      gateKind,
      ceilingDigest: digest,
      canonical: fields,
      signature,
      issuedAt: FieldValue.serverTimestamp(),
      expiresAtMs: Date.now() + DEFAULT_TTL_MS,
    });
    return { ok: true, ceilingDigest: digest };
  },
);

export const redeemMissionApprovalAnswer = onCallProduction(
  "redeemMissionApprovalAnswer",
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 100 },
  async (request: CallableRequest<Record<string, unknown>>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Authentication is required.");
    const nonce = boundedTrimmedString(request.data.nonce, "nonce", 256, true);
    const deviceId = boundedFirestoreDocumentId(request.data.deviceId, "deviceId", 160);
    const requestId = boundedFirestoreDocumentId(request.data.requestId, "requestId", 160);
    const gateKind = boundedTrimmedString(request.data.gateKind ?? "default", "gateKind", 40, true);
    const answerId = `${requestId}:${gateKind}`;
    const digest = boundedTrimmedString(request.data.ceilingDigest, "ceilingDigest", 64, true);
    try {
      await assertCallableApprovalNotLocked(uid, "mission_approval_fail");
      await enforceHighRiskComputerUseCallableWithNonce(request, uid, nonce);
      await assertActiveBurnBarCloudProEntitlement(uid);
      await requireTrustedDeviceActionProof({
        uid,
        deviceId,
        actionKind: "mission_approval_answer_redeem",
        subjectId: `${requestId}:${digest}:approve`,
        approve: true,
        nonce,
        proofRaw: request.data.actionProof,
        allowedPlatforms: PHONE,
      });
    } catch (error) {
      await recordCallableApprovalFailure(uid, "mission_approval_fail");
      throw error;
    }

    const ceilingRef = db.doc(`users/${uid}/mission_approval_ceilings/${requestId}`);
    const answerRef = db.doc(`users/${uid}/mission_approval_answers/${answerId}`);
    await db.runTransaction(async (tx) => {
      const [ceiling, existing] = await Promise.all([tx.get(ceilingRef), tx.get(answerRef)]);
      if (!ceiling.exists) throw new HttpsError("not-found", "Approval ceiling was not found.");
      if (ceiling.get("ceilingDigest") !== digest) {
        throw new HttpsError("failed-precondition", "ceilingDigest does not match the parked ceiling.");
      }
      const expiresAtMs = Number(ceiling.get("expiresAtMs") ?? 0);
      if (!Number.isFinite(expiresAtMs) || expiresAtMs < Date.now() || expiresAtMs > Date.now() + MAX_TTL_MS) {
        throw new HttpsError("failed-precondition", "Approval ceiling is expired.");
      }
      if (existing.exists && existing.get("consumedAt")) {
        throw new HttpsError("failed-precondition", "Pre-auth answer was already consumed.");
      }
      const requested = recordOrUndefined(request.data.requestedGrant) ?? {};
      const canonical = recordOrUndefined(ceiling.get("canonical")) ?? {};
      const grantCeiling = recordOrUndefined(canonical.grantCeiling) ?? {};
      if (!requestedIsSubsetOfCeiling(grantCeiling, requested)) {
        throw new HttpsError("failed-precondition", "Requested grant is wider than the Mac-signed ceiling.");
      }
      tx.set(answerRef, {
        answerId,
        requestId,
        ceilingDigest: digest,
        deviceId,
        consumedAt: FieldValue.serverTimestamp(),
      });
    });
    await appendComputerUseAuditEvent(uid, {
      actor: "phone",
      action: "mission_preauth_redeemed",
      subjectId: requestId,
    });
    logInfo({ event: "callable_info", message: "mission_preauth_redeemed", request_id: requestId });
    return { ok: true, requestId, consumed: true };
  },
);
