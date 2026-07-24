/**
 * @fileoverview Trusted-device agent-grant authority publication.
 */

import { FieldValue } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { getConfig } from "../config.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  parsePhoneControlSigningKeyKind,
  PHONE_CONTROL_ESCROW_PLATFORMS,
  requireDerivedPhoneControlPeerNodeId,
  requirePhoneControlAuthorityPublicKey,
} from "./computerUseSecurityCodecs.js";
import { requireTrustedEscrowDevice } from "./computerUseSecurityFirestore.js";
import {
  bindTrustedEscrowDevicePeerNodeId,
  boundAppCheckAttestationDigest,
} from "./phoneControlCallables.js";
import { assertActiveBurnBarCloudProEntitlement, boundedTrimmedString } from "./shared.js";

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
    await bindTrustedEscrowDevicePeerNodeId({
      uid,
      deviceId,
      peerNodeId,
      permittedPriorPeerRefs: [db.doc(`users/${uid}/agent_grant_authorities/${deviceId}`)],
    });
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
