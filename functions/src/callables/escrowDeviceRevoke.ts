/**
 * @fileoverview Escrow-device trust revocation callable (`revokeEscrowDeviceTrust`).
 *
 * Extracted verbatim from `computerUseSecurity.ts` (U6 split). The revoke handler
 * is decomposed into cohesive helpers (`stageCloudVaultRotationRequirement`,
 * `clearRevokedControllerPairings`) — pure relocations with identical reads,
 * throws, and side-effects.
 */

import { randomBytes } from "node:crypto";

import {
  FieldValue,
  Timestamp,
  type DocumentData,
  type QueryDocumentSnapshot,
  type WriteBatch,
} from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { recordOrUndefined } from "../guards.js";
import { logInfo, logWarn, wrapCallableHandler } from "../logging.js";
import { boundedTrimmedString } from "./shared.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { revokeSignalSessionsForDevice } from "../signalDirectoryRuntime.js";
import { normalizedControllerDeviceAllowlist } from "./computerUseSecurityCodecs.js";
import { appendComputerUseAuditEvent } from "./computerUseSecurityFirestore.js";

/**
 * Determine whether a CloudVault rotation requirement must be written when a
 * trusted device is revoked, and stage it into the batch. Pure relocation of the
 * inline block; returns the values the receipt + response echo.
 */
async function stageCloudVaultRotationRequirement(args: {
  uid: string;
  deviceId: string;
  receiptId: string;
  now: Timestamp;
  batch: WriteBatch;
}): Promise<{ required: boolean; requirementId: string | null; blockedReason: string | null }> {
  const { uid, deviceId, receiptId, now, batch } = args;
  const stateSnap = await db.doc(`users/${uid}/cloud_vault_state/current`).get();
  const state = recordOrUndefined(stateSnap.data());
  if (!(stateSnap.exists && state?.status === "active" && typeof state.vaultKeyID === "string")) {
    return { required: false, requirementId: null, blockedReason: "no_active_cloud_vault_state" };
  }
  const trustedDevicesSnap = await db
    .collection(`users/${uid}/escrow_devices`)
    .where("trustState", "==", "trusted")
    .get();
  const survivorDeviceIds = trustedDevicesSnap.docs
    .map((doc) => doc.id)
    .filter((trustedDeviceId) => trustedDeviceId !== deviceId)
    .sort();
  if (survivorDeviceIds.length === 0) {
    return { required: false, requirementId: null, blockedReason: "no_surviving_trusted_device" };
  }
  batch.set(db.doc(`users/${uid}/cloud_vault_rotation_requirements/${receiptId}`), {
    requirementId: receiptId,
    uid,
    status: "pending",
    reason: "device_revoked",
    revokedDeviceId: deviceId,
    revokedAt: now,
    receiptId,
    currentVaultKeyID: state.vaultKeyID,
    currentVaultGeneration: typeof state.vaultGeneration === "number" ? state.vaultGeneration : 1,
    survivorDeviceIds,
    rotateCallable: "rotateCloudVaultKey",
    nextRotationReason: "revocation_rewrap",
    createdAt: FieldValue.serverTimestamp(),
    // Millis mirror of createdAt so the stale-pending detector
    // (detectStalePendingCloudVaultRotations) can range-query a
    // collection-group on a sortable scalar — a serverTimestamp() is
    // a sentinel at write time and cannot be compared in a query
    // predicate. Mirrors agent_notification_events.updatedAtMillis.
    createdAtMillis: now.toMillis(),
    updatedAt: FieldValue.serverTimestamp(),
    schemaVersion: 1,
  });
  return { required: true, requirementId: receiptId, blockedReason: null };
}

/**
 * F2 — clear the revoked device from every iroh pairing allowlist + controller
 * doc so a revoked phone is no longer dialable. Pure relocation; returns the
 * cleared controller peer node ids for the receipt.
 */
async function clearRevokedControllerPairings(args: {
  uid: string;
  deviceId: string;
  batch: WriteBatch;
}): Promise<string[]> {
  const { uid, deviceId, batch } = args;
  const revokedControllerPeerNodeIds: string[] = [];
  const pairings = await db.collection(`users/${uid}/iroh_pairing`).get();
  for (const pairing of pairings.docs) {
    const allowlist = normalizedControllerDeviceAllowlist(pairing.get("authorizedControllerDeviceIds"));
    if (allowlist.includes(deviceId)) {
      batch.set(
        pairing.ref,
        {
          authorizedControllerDeviceIds: allowlist.filter((controllerDeviceId) => controllerDeviceId !== deviceId),
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }
    const controllers = await pairing.ref.collection("controllers").where("deviceId", "==", deviceId).get();
    for (const controller of controllers.docs) {
      batch.delete(controller.ref);
      const peer = controller.get("peerNodeId");
      if (typeof peer === "string" && peer.length > 0) revokedControllerPeerNodeIds.push(peer);
    }
    const routeRef = db.doc(`${pairing.ref.path}/controller_routes/${deviceId}`);
    const route = await routeRef.get();
    if (route.exists) {
      const priorGeneration = route.get("generation");
      const nextGeneration = typeof priorGeneration === "number" && priorGeneration >= 1 ? priorGeneration + 1 : 1;
      const revokedAtMillis = Date.now();
      batch.set(
        routeRef,
        {
          status: "revoked",
          generation: nextGeneration,
          expiresAtMillis: revokedAtMillis,
          revokedAtMillis,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }
  }
  return revokedControllerPeerNodeIds;
}

type EscrowGrantDoc = QueryDocumentSnapshot<DocumentData>;

async function activeEscrowGrantDocsForDevice(uid: string, deviceId: string): Promise<EscrowGrantDoc[]> {
  const grantsRef = db.collection(`users/${uid}/escrow_grants`);
  const [targetGrants, sourceGrants] = await Promise.all([
    grantsRef.where("targetDeviceId", "==", deviceId).where("status", "==", "granted").get(),
    grantsRef.where("sourceDeviceId", "==", deviceId).where("status", "==", "granted").get(),
  ]);
  const grantsByPath = new Map<string, EscrowGrantDoc>();
  for (const grant of [...targetGrants.docs, ...sourceGrants.docs]) {
    grantsByPath.set(grant.ref.path, grant);
  }
  return [...grantsByPath.values()];
}

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

      const now = Timestamp.now();
      const receiptId = `revoke_${Date.now()}_${randomBytes(6).toString("hex")}`;
      // Flip the parent trust state before sweeping child grant records. Client
      // rules require trusted source/target devices for new grants, so once this
      // write commits, a new grant cannot race in after the sweep query. The
      // cleanup batch repeats the same parent write so the durable receipt and
      // child revocations converge idempotently if the callable is retried.
      await ref.set(
        {
          trustState: "revoked",
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

      const grants = await activeEscrowGrantDocsForDevice(uid, deviceId);
      const batch = db.batch();
      batch.set(
        ref,
        {
          trustState: "revoked",
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      for (const grant of grants) {
        batch.set(
          grant.ref,
          {
            status: "revoked",
            revokedAt: now,
          },
          { merge: true },
        );
      }

      const activeWrapperSnap = await db
        .collection(`users/${uid}/cloud_vault_key_wrappers`)
        .where("targetDeviceId", "==", deviceId)
        .where("status", "==", "active")
        .get();
      for (const wrapper of activeWrapperSnap.docs) {
        batch.set(
          wrapper.ref,
          {
            status: "revoked",
            revokedAt: now,
            revokedByDeviceTrustRevocationId: receiptId,
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }

      const rotation = await stageCloudVaultRotationRequirement({ uid, deviceId, receiptId, now, batch });
      const cloudVaultRotationRequired = rotation.required;
      const cloudVaultRotationRequirementId = rotation.requirementId;
      const cloudVaultRotationBlockedReason = rotation.blockedReason;

      // F2 — atomic revoke. A revoked device's controller record must be
      // cleared in the same pass, not left dialable: the Mac builds its iroh
      // inbound allowlist + phone-control key pin from
      // `iroh_pairing/{conn}/controllers/{peer}`, so a surviving doc keeps a
      // revoked phone connectable until the relay restarts. Scoped to this uid
      // by iterating the user's own pairings (no cross-tenant collectionGroup).
      const revokedControllerPeerNodeIds = await clearRevokedControllerPairings({ uid, deviceId, batch });

      // F2 — also retire the device's agent-grant authority (doc id == deviceId)
      // so a queued grant can no longer be minted against the revoked key.
      const agentGrantAuthorityRef = db.doc(`users/${uid}/agent_grant_authorities/${deviceId}`);
      const agentGrantAuthoritySnap = await agentGrantAuthorityRef.get();
      const clearedAgentGrantAuthority = agentGrantAuthoritySnap.exists;
      if (clearedAgentGrantAuthority) {
        batch.delete(agentGrantAuthorityRef);
      }

      await batch.commit();

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

      // F2 — emit a revocation receipt: a durable, tamper-evident audit record
      // of exactly what this revocation cleared, returned to the operator so a
      // revoke is observable and attributable rather than silent.
      await appendComputerUseAuditEvent(uid, {
        message: "phone_control_peer_revoked_receipt",
        receiptId,
        deviceId,
        revokedGrants: grants.length,
        revokedControllerPeerNodeIds,
        clearedAgentGrantAuthority,
        revokedSignalSessions,
        signalSessionRevokeFailed,
        revokedCloudVaultWrappers: activeWrapperSnap.size,
        cloudVaultRotationRequired,
        cloudVaultRotationRequirementId,
        cloudVaultRotationBlockedReason,
      });

      logInfo({
        event: "callable_info",
        message: "escrow_device_trust_revoked",
        device_id: deviceId,
        revoked_grants: grants.length,
        revoked_controllers: revokedControllerPeerNodeIds.length,
        cleared_agent_grant_authority: clearedAgentGrantAuthority,
        revoked_signal_sessions: revokedSignalSessions,
        signal_session_revoke_failed: signalSessionRevokeFailed,
        revoked_cloud_vault_wrappers: activeWrapperSnap.size,
        cloud_vault_rotation_required: cloudVaultRotationRequired,
        cloud_vault_rotation_requirement_id: cloudVaultRotationRequirementId,
        cloud_vault_rotation_blocked_reason: cloudVaultRotationBlockedReason,
        receipt_id: receiptId,
      });
      return {
        ok: true,
        deviceId,
        trustState: "revoked",
        revokedGrants: grants.length,
        revokedControllerPeerNodeIds,
        clearedAgentGrantAuthority,
        revokedSignalSessions,
        signalSessionRevokeFailed,
        revokedCloudVaultWrappers: activeWrapperSnap.size,
        cloudVaultRotationRequired,
        cloudVaultRotationRequirementId,
        cloudVaultRotationBlockedReason,
        receiptId,
      };
    },
  ),
);
