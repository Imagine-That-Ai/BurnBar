/**
 * @fileoverview Trusted-device agent-grant authority publication.
 */

import { FieldValue } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "@openburnbar/functions-shared/adminRuntime.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "@openburnbar/functions-shared/appCheckAttestation.js";
import { getConfig } from "@openburnbar/functions-shared/config.js";
import { logInfo, onCallProduction } from "@openburnbar/functions-shared/logging.js";
import { FUNCTIONS_REGION } from "@openburnbar/functions-shared/runtimeOptions.js";
import {
  parsePhoneControlSigningKeyKind,
  PHONE_CONTROL_ESCROW_PLATFORMS,
  requireDerivedPhoneControlPeerNodeId,
  requirePhoneControlAuthorityPublicKey,
} from "@openburnbar/functions-shared/callables/computerUseSecurityCodecs.js";
import { requireTrustedEscrowDevice } from "@openburnbar/functions-shared/callables/computerUseSecurityFirestore.js";
import {
  bindTrustedEscrowDevicePeerNodeId,
  boundAppCheckAttestationDigest,
} from "./phoneControlCallables.js";
import { assertActiveBurnBarCloudProEntitlement } from "@openburnbar/functions-shared/shared/entitlements.js";
import { boundedTrimmedString } from "@openburnbar/functions-shared/shared/validators.js";

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
