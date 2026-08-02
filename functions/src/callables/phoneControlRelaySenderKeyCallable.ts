import { createHash } from "node:crypto";

import { FieldValue } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { getConfig } from "../config.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  PHONE_CONTROL_ESCROW_PLATFORMS,
  RELAY_AUTH_ENCRYPTION,
  RELAY_AUTH_KEY_VERSION,
  boundedInteger,
  requireFreshPublicationMillis,
  requireP256X963PublicKey,
} from "./computerUseSecurityCodecs.js";
import { requireTrustedDeviceActionProof, requireTrustedEscrowDevice } from "./computerUseSecurityFirestore.js";
import { assertActiveBurnBarCloudProEntitlement } from "./shared/entitlements.js";
import { boundedTrimmedString } from "./shared/validators.js";
import { bindTrustedEscrowDevicePeerNodeId } from "./trustedEscrowDevicePeerBinding.js";

const RELAY_SENDER_KEY_PUBLISH_ACTION_KIND = "relay_sender_key_publish";
const RELAY_SENDER_PROOF_PROTOCOL_VERSION = "3";

function relaySenderKeyPublishProofSubjectId(args: {
  deviceId: string;
  peerNodeId: string;
  keyId: string;
  publicKeySHA256Hex: string;
  publishedAtMillis: number;
  signalIdentityKeyId: string;
  signalIdentityKeyVersion: number;
  signalIdentityPublicKeyFingerprint: string;
}): string {
  const segments = [
    "version",
    "1",
    "deviceId",
    args.deviceId,
    "peerNodeId",
    args.peerNodeId,
    "keyId",
    args.keyId,
    "publicKeySHA256Hex",
    args.publicKeySHA256Hex,
    "relayKeyVersion",
    RELAY_SENDER_PROOF_PROTOCOL_VERSION,
    "publishedAtMillis",
    String(args.publishedAtMillis),
    "signalIdentityKeyId",
    args.signalIdentityKeyId,
    "signalIdentityKeyVersion",
    String(args.signalIdentityKeyVersion),
    "signalIdentityPublicKeyFingerprint",
    args.signalIdentityPublicKeyFingerprint,
  ];
  const canonical = `OpenBurnBar-RelaySenderKeyPublish-v1\n${segments
    .map((segment) => `${Buffer.byteLength(segment, "utf8")}:${segment}\n`)
    .join("")}`;
  return createHash("sha256").update(canonical).digest("hex");
}

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
      actionProof?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before publishing a relay sender key.");
    const nonce = boundedTrimmedString(request.data.nonce, "nonce", 256, true);
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, nonce);
    await assertActiveBurnBarCloudProEntitlement(uid);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    await requireTrustedEscrowDevice(uid, deviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
    const peerNodeId = boundedTrimmedString(request.data.peerNodeId, "peerNodeId", 160, true);
    const keyId = boundedTrimmedString(request.data.keyId, "keyId", 128, true);
    if (!/^relay-v3-[a-f0-9]{24}$/u.test(keyId)) {
      throw new HttpsError("invalid-argument", "keyId must be a v3 relay sender key id.");
    }
    const relayKeyVersion =
      boundedInteger(
        request.data.relayKeyVersion,
        "relayKeyVersion",
        RELAY_AUTH_KEY_VERSION,
        RELAY_AUTH_KEY_VERSION,
        true,
      ) ?? RELAY_AUTH_KEY_VERSION;
    const relaySenderKey = requireP256X963PublicKey(request.data.publicKeyBase64, "publicKeyBase64");
    const publicKeySHA256Hex = createHash("sha256").update(relaySenderKey.decoded).digest("hex");
    const derivedKeyId = `relay-v3-${publicKeySHA256Hex.slice(0, 24)}`;
    if (keyId !== derivedKeyId) {
      throw new HttpsError("invalid-argument", "keyId does not match the relay sender key.");
    }
    const publishedAtMillis = requireFreshPublicationMillis(request.data.publishedAtMillis, "publishedAtMillis");
    const signalIdentityKeyId = boundedTrimmedString(
      request.data.signalIdentityKeyId,
      "signalIdentityKeyId",
      200,
      true,
    );
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

    const identity = await db.doc(`users/${uid}/signal_identity_public_keys/${signalIdentityKeyId}`).get();
    if (
      !identity.exists ||
      identity.get("deviceId") !== deviceId ||
      identity.get("identityKeyId") !== signalIdentityKeyId ||
      identity.get("publicKeyFingerprint") !== signalIdentityPublicKeyFingerprint ||
      identity.get("keyVersion") !== signalIdentityKeyVersion
    ) {
      throw new HttpsError(
        "permission-denied",
        "Relay sender key requires a published Signal identity for this trusted device.",
      );
    }
    await requireTrustedDeviceActionProof({
      uid,
      deviceId,
      actionKind: RELAY_SENDER_KEY_PUBLISH_ACTION_KIND,
      subjectId: relaySenderKeyPublishProofSubjectId({
        deviceId,
        peerNodeId,
        keyId,
        publicKeySHA256Hex,
        publishedAtMillis,
        signalIdentityKeyId,
        signalIdentityKeyVersion,
        signalIdentityPublicKeyFingerprint,
      }),
      approve: true,
      nonce,
      proofRaw: request.data.actionProof,
      allowedPlatforms: PHONE_CONTROL_ESCROW_PLATFORMS,
    });
    await bindTrustedEscrowDevicePeerNodeId({
      uid,
      deviceId,
      peerNodeId,
      permittedPriorPeerRefs: [db.doc(`users/${uid}/relay_sender_keys/${deviceId}`)],
    });

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
