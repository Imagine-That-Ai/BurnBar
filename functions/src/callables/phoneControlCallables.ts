/**
 * @fileoverview iroh-pairing + phone-control publish/revoke callables — pairing
 * key/record publication, pairing revocation, phone-control authority + relay
 * sender-key publication.
 *
 * Extracted verbatim from `computerUseSecurity.ts` (U6 split).
 */

import { randomUUID } from "node:crypto";

import { FieldValue } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import {
  appCheckAttestationDigestHex,
  enforceHighRiskComputerUseCallableWithNonce,
  isAppCheckAttestationClaimFresh,
  readAppCheckAttestationClaim,
  readAppIdFromCallableRequest,
} from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { logInfo, onCallProduction } from "../logging.js";
import { assertActiveBurnBarCloudProEntitlement } from "./shared/entitlements.js";
import { boundedTrimmedString } from "./shared/validators.js";
import { recordOrUndefined } from "../guards.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  IROH_CONTROLLER_DEVICE_LIMIT,
  IROH_HOST_ESCROW_PLATFORMS,
  PHONE_CONTROL_ESCROW_PLATFORMS,
  boundedInteger,
  boundedStringArray,
  normalizedControllerDeviceAllowlist,
  parsePhoneControlSigningKeyKind,
  requireBase64Like,
  requireDerivedPhoneControlPeerNodeId,
  requireFreshPublicationMillis,
  requirePhoneControlAuthorityPublicKey,
} from "./computerUseSecurityCodecs.js";
import { requireTrustedEscrowDevice } from "./computerUseSecurityFirestore.js";
import { revokeIrohPairingAndControllerRoutes } from "./irohControllerRouteFirestore.js";
import { requireApprovedLinuxAppCheckIrohHost } from "./linuxAppCheckDevices.js";
import { stageTrustedEscrowDevicePeerNodeBinding } from "./trustedEscrowDevicePeerBinding.js";

const PHONE_CONTROL_ENROLLMENT_GRANT_TTL_MS = 2 * 60 * 1000;

export { publishRelaySenderKey } from "./phoneControlRelaySenderKeyCallable.js";
export { bindTrustedEscrowDevicePeerNodeId } from "./trustedEscrowDevicePeerBinding.js";

async function requireApprovedIrohHostMutationDevice(
  request: CallableRequest,
  uid: string,
  deviceId: string,
): Promise<void> {
  if (readAppIdFromCallableRequest(request) === getConfig().linuxAppCheckAppID) {
    await requireApprovedLinuxAppCheckIrohHost(request, uid, deviceId);
    return;
  }
  await requireTrustedEscrowDevice(uid, deviceId, IROH_HOST_ESCROW_PLATFORMS);
}

export function boundAppCheckAttestationDigest(request: CallableRequest): string | undefined {
  const claim = readAppCheckAttestationClaim(recordOrUndefined(request.auth?.token));
  if (!claim || !isAppCheckAttestationClaimFresh(claim)) return undefined;
  return appCheckAttestationDigestHex(claim.appId, claim.boundAtMillis);
}

function rejectMismatchedExpectedUID(expectedUID: unknown, authenticatedUID: string): void {
  if (expectedUID == null) return;
  if (typeof expectedUID !== "string" || expectedUID.length === 0 || expectedUID.length > 128) {
    throw new HttpsError("invalid-argument", "expectedUid must be a valid authenticated account identifier.");
  }
  if (expectedUID !== authenticatedUID) {
    throw new HttpsError("permission-denied", "Authenticated account changed during authority publication.");
  }
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
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce, {
      allowLowerTrustDesktop: true,
    });
    await assertActiveBurnBarCloudProEntitlement(uid);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    const roleId = boundedTrimmedString(request.data.roleId ?? "host", "roleId", 32, true);
    if (roleId !== "host") {
      throw new HttpsError("invalid-argument", "Only the host iroh pairing key role is client-publishable.");
    }
    await requireApprovedIrohHostMutationDevice(request, uid, deviceId);
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
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce, {
      allowLowerTrustDesktop: true,
    });
    await assertActiveBurnBarCloudProEntitlement(uid);

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    await requireApprovedIrohHostMutationDevice(request, uid, deviceId);
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
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce, {
      allowLowerTrustDesktop: true,
    });

    const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
    const connectionId = boundedTrimmedString(request.data.connectionId, "connectionId", 160, true);
    await requireApprovedIrohHostMutationDevice(request, uid, deviceId);
    await revokeIrohPairingAndControllerRoutes(uid, connectionId);

    logInfo({
      event: "callable_info",
      message: "iroh_pairing_record_revoked",
      connection_id: connectionId,
      device_id: deviceId,
    });
    return { ok: true, connectionId };
  },
);

export const issuePhoneControlEnrollmentGrant = onCallProduction(
  "issuePhoneControlEnrollmentGrant",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (
    request: CallableRequest<{
      hostDeviceId?: unknown;
      connectionId?: unknown;
      controllerDeviceId?: unknown;
      controllerPeerNodeId?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before approving phone-control enrollment.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce, {
      allowLowerTrustDesktop: true,
    });
    await assertActiveBurnBarCloudProEntitlement(uid);

    const hostDeviceId = boundedTrimmedString(request.data.hostDeviceId, "hostDeviceId", 160, true);
    const connectionId = boundedTrimmedString(request.data.connectionId, "connectionId", 160, true);
    const controllerDeviceId = boundedTrimmedString(request.data.controllerDeviceId, "controllerDeviceId", 160, true);
    const controllerPeerNodeId = boundedTrimmedString(
      request.data.controllerPeerNodeId,
      "controllerPeerNodeId",
      160,
      true,
    );
    await requireApprovedIrohHostMutationDevice(request, uid, hostDeviceId);
    await requireTrustedEscrowDevice(uid, controllerDeviceId, PHONE_CONTROL_ESCROW_PLATFORMS);

    const issuedAtMillis = Date.now();
    const expiresAtMillis = issuedAtMillis + PHONE_CONTROL_ENROLLMENT_GRANT_TTL_MS;
    const grantNonce = randomUUID();
    const pairingRef = db.doc(`users/${uid}/iroh_pairing/${connectionId}`);
    const grantRef = db.doc(
      `users/${uid}/iroh_pairing/${connectionId}/controller_enrollment_grants/${controllerDeviceId}`,
    );
    await db.runTransaction(async (transaction) => {
      const pairing = await transaction.get(pairingRef);
      if (!pairing.exists) {
        throw new HttpsError("failed-precondition", "Phone-control enrollment requires an active iroh pairing.");
      }
      if (pairing.get("publishedByDeviceId") !== hostDeviceId) {
        throw new HttpsError(
          "permission-denied",
          "Only the trusted host that published this iroh pairing may approve a controller.",
        );
      }
      transaction.set(
        grantRef,
        {
          connectionId,
          controllerDeviceId,
          controllerPeerNodeId,
          grantNonce,
          status: "pending",
          issuedByDeviceId: hostDeviceId,
          issuedAtMillis,
          expiresAtMillis,
          schemaVersion: 1,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: false },
      );
    });

    logInfo({
      event: "callable_info",
      message: "phone_control_enrollment_grant_issued",
      connection_id: connectionId,
      controller_device_id: controllerDeviceId,
      controller_peer_node_id: controllerPeerNodeId,
      host_device_id: hostDeviceId,
    });
    return {
      ok: true,
      connectionId,
      controllerDeviceId,
      controllerPeerNodeId,
      grantNonce,
      expiresAtMillis,
    };
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
      expectedUid?: unknown;
      nonce?: unknown;
    }>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before publishing phone-control authority.");
    rejectMismatchedExpectedUID(request.data.expectedUid, uid);
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
    const enrollmentGrantRef = db.doc(
      `users/${uid}/iroh_pairing/${connectionId}/controller_enrollment_grants/${deviceId}`,
    );
    await db.runTransaction(async (transaction) => {
      const pairing = await transaction.get(pairingRef);
      if (!pairing.exists) {
        throw new HttpsError("failed-precondition", "Phone-control authority must reference an existing iroh pairing.");
      }
      const allowlist = normalizedControllerDeviceAllowlist(pairing.get("authorizedControllerDeviceIds"));
      if (allowlist.length > IROH_CONTROLLER_DEVICE_LIMIT) {
        throw new HttpsError("failed-precondition", "Phone-control authority list exceeds the supported device limit.");
      }
      const existingController = await transaction.get(controllerRef);
      if (existingController.exists && existingController.get("deviceId") !== deviceId) {
        throw new HttpsError(
          "permission-denied",
          "Phone-control authority is already bound to another trusted device.",
        );
      }
      const isExistingAuthorityRenewal = allowlist.includes(deviceId) && existingController.exists;
      if (!isExistingAuthorityRenewal && allowlist.length === IROH_CONTROLLER_DEVICE_LIMIT) {
        throw new HttpsError("resource-exhausted", "This iroh pairing has reached its trusted controller limit.");
      }
      if (!isExistingAuthorityRenewal) {
        const grant = await transaction.get(enrollmentGrantRef);
        const grantExpiresAtMillis = grant.get("expiresAtMillis");
        if (
          !grant.exists ||
          grant.get("status") !== "pending" ||
          grant.get("connectionId") !== connectionId ||
          grant.get("controllerDeviceId") !== deviceId ||
          grant.get("controllerPeerNodeId") !== peerNodeId ||
          grant.get("issuedByDeviceId") !== pairing.get("publishedByDeviceId") ||
          typeof grant.get("grantNonce") !== "string" ||
          typeof grantExpiresAtMillis !== "number" ||
          grantExpiresAtMillis < Date.now()
        ) {
          throw new HttpsError("permission-denied", "Phone-control authority requires a fresh approval from this Mac.");
        }
        transaction.set(
          enrollmentGrantRef,
          {
            status: "consumed",
            consumedAtMillis: Date.now(),
            consumedByPeerNodeId: peerNodeId,
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }
      const nextAllowlist = allowlist.includes(deviceId) ? allowlist : [...allowlist, deviceId];
      await stageTrustedEscrowDevicePeerNodeBinding({
        transaction,
        uid,
        deviceId,
        peerNodeId,
        permittedPriorPeerRefForPeerNodeId: (priorPeerNodeId) =>
          db.doc(`users/${uid}/iroh_pairing/${connectionId}/controllers/${priorPeerNodeId}`),
      });

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
