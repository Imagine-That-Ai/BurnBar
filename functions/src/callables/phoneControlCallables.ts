/**
 * @fileoverview iroh-pairing + phone-control publish/revoke callables — pairing
 * key/record publication, pairing revocation, phone-control authority + relay
 * sender-key publication, and agent-grant authority publication.
 *
 * Extracted verbatim from `computerUseSecurity.ts` (U6 split).
 */

import { createHash } from "node:crypto";

import { FieldValue } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import {
  appCheckAttestationDigestHex,
  enforceHighRiskComputerUseCallableWithNonce,
  isAppCheckAttestationClaimFresh,
  readAppCheckAttestationClaim,
} from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { logInfo, onCallProduction } from "../logging.js";
import { assertActiveBurnBarCloudProEntitlement, boundedTrimmedString } from "./shared.js";
import { recordOrUndefined } from "../guards.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  MAC_ESCROW_PLATFORMS,
  PHONE_CONTROL_ESCROW_PLATFORMS,
  RELAY_AUTH_ENCRYPTION,
  RELAY_AUTH_KEY_VERSION,
  boundedInteger,
  boundedStringArray,
  normalizedControllerDeviceAllowlist,
  parsePhoneControlSigningKeyKind,
  requireBase64Like,
  requireDerivedPhoneControlPeerNodeId,
  requireFreshPublicationMillis,
  requireP256X963PublicKey,
  requirePhoneControlAuthorityPublicKey,
} from "./computerUseSecurityCodecs.js";
import { requireTrustedDeviceActionProof, requireTrustedEscrowDevice } from "./computerUseSecurityFirestore.js";

const RELAY_SENDER_KEY_PUBLISH_ACTION_KIND = "relay_sender_key_publish";
const RELAY_SENDER_PROOF_PROTOCOL_VERSION = "3";

function boundAppCheckAttestationDigest(request: CallableRequest): string | undefined {
  const claim = readAppCheckAttestationClaim(recordOrUndefined(request.auth?.token));
  if (!claim || !isAppCheckAttestationClaimFresh(claim)) return undefined;
  return appCheckAttestationDigestHex(claim.appId, claim.boundAtMillis);
}

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
    await assertActiveBurnBarCloudProEntitlement(uid);

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
    await assertActiveBurnBarCloudProEntitlement(uid);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    await requireTrustedEscrowDevice(uid, deviceId, MAC_ESCROW_PLATFORMS);
    const connectionId = boundedTrimmedString(request.data.connectionId, "connectionId", 160, true);
    const nodeId = boundedTrimmedString(request.data.nodeId, "nodeId", 128, true);
    const relayURLRaw =
      request.data.relayURL == null ? undefined : boundedTrimmedString(request.data.relayURL, "relayURL", 512, false);
    const relayURL = relayURLRaw && relayURLRaw.length > 0 ? relayURLRaw : undefined;
    const directAddresses = boundedStringArray(request.data.directAddresses, "directAddresses", 16, 512);
    const publishedAtMillis =
      boundedInteger(request.data.publishedAtMillis, "publishedAtMillis", 1, Number.MAX_SAFE_INTEGER, true) ??
      Date.now();
    const protocolVersion = boundedInteger(request.data.protocolVersion, "protocolVersion", 1, 100, true) ?? 1;
    const signature = requireBase64Like(request.data.signature, "signature", 32, 256);

    const ref = db.doc(`users/${uid}/iroh_pairing/${connectionId}`);
    await db.runTransaction(async (transaction) => {
      const existing = await transaction.get(ref);
      const createdAt =
        existing.exists && existing.get("createdAt") != null ? existing.get("createdAt") : FieldValue.serverTimestamp();
      const existingControllerAllowlist = normalizedControllerDeviceAllowlist(
        existing.get("authorizedControllerDeviceIds"),
      );
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
      if (!existing.exists || existing.get("authorizedControllerDeviceIds") == null) {
        payload.authorizedControllerDeviceIds = [];
      } else {
        payload.authorizedControllerDeviceIds = existingControllerAllowlist;
      }
      transaction.set(ref, payload, { merge: true });
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
      keyKind?: unknown;
      publishedAtMillis?: unknown;
      protocolVersion?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before publishing phone-control authority.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);
    await assertActiveBurnBarCloudProEntitlement(uid);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    await requireTrustedEscrowDevice(uid, deviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
    const connectionId = boundedTrimmedString(request.data.connectionId, "connectionId", 160, true);
    const peerNodeId = boundedTrimmedString(request.data.peerNodeId, "peerNodeId", 160, true);
    const keyKind = parsePhoneControlSigningKeyKind(request.data.keyKind);
    const { bytes: publicKeyBytes, base64: publicKeyBase64 } = requirePhoneControlAuthorityPublicKey(
      request.data.publicKeyBase64,
      keyKind,
    );
    requireDerivedPhoneControlPeerNodeId(peerNodeId, publicKeyBytes, keyKind);
    const publishedAtMillis = requireFreshPublicationMillis(request.data.publishedAtMillis, "publishedAtMillis");
    const protocolVersion = boundedInteger(request.data.protocolVersion ?? 1, "protocolVersion", 1, 100, true) ?? 1;
    const appCheckAttestationHashBlake3 = boundAppCheckAttestationDigest(request);

    const pairingRef = db.doc(`users/${uid}/iroh_pairing/${connectionId}`);
    const controllerRef = db.doc(`users/${uid}/iroh_pairing/${connectionId}/controllers/${peerNodeId}`);
    await db.runTransaction(async (transaction) => {
      const pairing = await transaction.get(pairingRef);
      if (!pairing.exists) {
        throw new HttpsError("failed-precondition", "Phone-control authority must reference an existing iroh pairing.");
      }
      const allowlist = normalizedControllerDeviceAllowlist(pairing.get("authorizedControllerDeviceIds"));
      let nextAllowlist = allowlist;
      if (allowlist.length === 0) {
        nextAllowlist = [deviceId];
      } else if (allowlist.length !== 1 || allowlist[0] !== deviceId) {
        throw new HttpsError("permission-denied", "Phone-control authority is not authorized for this iroh pairing.");
      }

      transaction.set(
        pairingRef,
        {
          authorizedControllerDeviceIds: nextAllowlist,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      transaction.set(
        controllerRef,
        {
          id: peerNodeId,
          connectionId,
          peerNodeId,
          deviceId,
          publicKeyBase64,
          // F2: persist the key custody class. Absent on legacy records ⇒ ed25519.
          signingKeyKind: keyKind,
          publishedAtMillis,
          protocolVersion,
          publishedByDeviceId: deviceId,
          ...(appCheckAttestationHashBlake3 ? { appCheckAttestationHashBlake3 } : {}),
          schemaVersion: keyKind === "se-p256" ? 3 : 2,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    });

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

    const [identity, device] = await Promise.all([
      db.doc(`users/${uid}/signal_identity_public_keys/${signalIdentityKeyId}`).get(),
      db.doc(`users/${uid}/escrow_devices/${deviceId}`).get(),
    ]);
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
    if (device.exists && device.get("peerNodeId") && device.get("peerNodeId") !== peerNodeId) {
      throw new HttpsError("permission-denied", "Relay sender peer node does not match the trusted device binding.");
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

export const publishAgentGrantAuthority = onCallProduction(
  "publishAgentGrantAuthority",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      deviceId?: unknown;
      peerNodeId?: unknown;
      publicKeyBase64?: unknown;
      keyKind?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before publishing an agent grant authority.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);
    await assertActiveBurnBarCloudProEntitlement(uid);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    await requireTrustedEscrowDevice(uid, deviceId, PHONE_CONTROL_ESCROW_PLATFORMS);
    const peerNodeId = boundedTrimmedString(request.data.peerNodeId, "peerNodeId", 160, true);
    const keyKind = parsePhoneControlSigningKeyKind(request.data.keyKind);
    const { bytes: publicKeyBytes, base64: publicKeyBase64 } = requirePhoneControlAuthorityPublicKey(
      request.data.publicKeyBase64,
      keyKind,
    );
    requireDerivedPhoneControlPeerNodeId(peerNodeId, publicKeyBytes, keyKind);
    const appCheckAttestationHashBlake3 = boundAppCheckAttestationDigest(request);

    await db.doc(`users/${uid}/agent_grant_authorities/${deviceId}`).set(
      {
        sourceDeviceId: deviceId,
        peerNodeId,
        publicKeyBase64,
        signingKeyKind: keyKind,
        publishedAtMillis: Date.now(),
        ...(appCheckAttestationHashBlake3 ? { appCheckAttestationHashBlake3 } : {}),
        schemaVersion: keyKind === "se-p256" ? 3 : 2,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    logInfo({
      event: "callable_info",
      message: "agent_grant_authority_published",
      device_id: deviceId,
      peer_node_id: peerNodeId,
    });
    return { ok: true, deviceId, peerNodeId };
  },
);
