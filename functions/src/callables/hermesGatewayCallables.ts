/**
 * @fileoverview Owner-authenticated management callables + the approval reaper
 * for the BurnBar Cloud Hermes Gateway (client list / revoke / token rotation,
 * oversight mode, approval response, scheduled reaper). Split out of
 * hermesGateway.ts to keep every gateway module under the file-length cap;
 * re-exported from there byte-identically. The larger device-grant approval and
 * event-enqueue callables live in ./hermesGatewayApprove.js and
 * ./hermesGatewayEnqueue.js respectively.
 */

import { type DocumentData, type Query } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";

import { db } from "../adminRuntime.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { stripUndefinedObject } from "../guards.js";
import { requireTrustedDeviceActionProof } from "./computerUseSecurity.js";
import {
  gatewayTokenExpiryISO,
  generateHermesGatewayBearerToken,
  hashHermesGatewayBearerToken,
  isHermesGatewayApprovalDoc,
  isHermesGatewayApprovalExpired,
  isHermesGatewayClientDoc,
  publicClientView,
  sanitizeHermesGatewayOversightMode,
  tokenPreview,
} from "../hermesGateway.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import type { HermesGatewayApprovalDoc, HermesGatewayClientDoc } from "../types/generated/hermes-gateway.js";
import { assertCallableApprovalNotLocked, recordCallableApprovalFailure } from "./publicRateLimit.js";
import { boundedTrimmedString, nowISO, requiredIdentifier } from "./shared.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  assertActiveHermesGatewayClient,
  assertActiveHermesGatewayEntitlement,
  assertTrustedNativeEscrowDevice,
  NATIVE_ESCROW_PLATFORMS,
} from "./hermesGatewayResolve.js";

export const listHermesGatewayClients = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("listHermesGatewayClients", async (request: CallableRequest<{ includeRevoked?: boolean }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before listing Hermes Gateway clients.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHermesGatewayEntitlement(uid);
    const snap = await db.collection(`users/${uid}/hermes_gateway_clients`).get();
    const clients = snap.docs
      .flatMap((doc): HermesGatewayClientDoc[] => {
        const client = doc.data();
        return isHermesGatewayClientDoc(client) ? [client] : [];
      })
      .filter((client) => request.data.includeRevoked === true || client.status !== "revoked")
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
      .map(publicClientView);
    return { clients };
  }),
);

const GATEWAY_REVOKE_BATCH_LIMIT = 400;

async function deleteGatewayQueryDocs(query: Query<DocumentData>): Promise<number> {
  let deleted = 0;
  for (;;) {
    const snap = await query.limit(GATEWAY_REVOKE_BATCH_LIMIT).get();
    if (snap.empty) break;
    const batch = db.batch();
    for (const doc of snap.docs) batch.delete(doc.ref);
    await batch.commit();
    deleted += snap.size;
    if (snap.size < GATEWAY_REVOKE_BATCH_LIMIT) break;
  }
  return deleted;
}

async function deleteGatewayAttachmentStorage(uid: string, clientId: string): Promise<number> {
  const bucket = getStorage().bucket();
  const prefix = `users/${uid}/hermes_gateway_attachments/${clientId}/`;
  const [files] = await bucket.getFiles({ prefix });
  if (files.length > 0) await bucket.deleteFiles({ prefix, force: true });
  return files.length;
}

async function deleteHermesGatewayClientContent(
  uid: string,
  clientId: string,
): Promise<{
  firestoreDocs: number;
  storageObjects: number;
}> {
  const [messages, attachments, approvals, typing, targetedEvents, storageObjects] = await Promise.all([
    deleteGatewayQueryDocs(db.collection(`users/${uid}/hermes_gateway_messages`).where("clientId", "==", clientId)),
    deleteGatewayQueryDocs(db.collection(`users/${uid}/hermes_gateway_attachments`).where("clientId", "==", clientId)),
    deleteGatewayQueryDocs(db.collection(`users/${uid}/hermes_gateway_approvals`).where("clientId", "==", clientId)),
    deleteGatewayQueryDocs(db.collection(`users/${uid}/hermes_gateway_typing`).where("clientId", "==", clientId)),
    deleteGatewayQueryDocs(db.collection(`users/${uid}/hermes_gateway_events`).where("targetClientId", "==", clientId)),
    deleteGatewayAttachmentStorage(uid, clientId),
  ]);
  return {
    firestoreDocs: messages + attachments + approvals + typing + targetedEvents,
    storageObjects,
  };
}

export const revokeHermesGatewayClient = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("revokeHermesGatewayClient", async (request: CallableRequest<{ clientId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before revoking Hermes Gateway clients.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveHermesGatewayEntitlement(uid);
    const clientId = requiredIdentifier(request.data.clientId, "clientId");
    const ref = db.doc(`users/${uid}/hermes_gateway_clients/${clientId}`);
    const snap = await ref.get();
    const client = snap.data();
    if (!snap.exists || !isHermesGatewayClientDoc(client)) {
      throw new HttpsError("not-found", "Hermes Gateway client not found.");
    }
    const now = nowISO();
    await Promise.all([
      ref.set({ status: "revoked", revokedAt: now, updatedAt: now }, { merge: true }),
      db.doc(`hermes_gateway_token_index/${client.tokenHash}`).delete(),
    ]);
    const deleted = await deleteHermesGatewayClientContent(uid, clientId);
    return { success: true, clientId, deleted };
  }),
);

export const rotateHermesGatewayClientToken = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("rotateHermesGatewayClientToken", async (request: CallableRequest<{ clientId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before rotating Hermes Gateway tokens.");
    enforceAuthAndAppCheck(request, uid);
    await assertCallableApprovalNotLocked(uid, "hermes_gateway_approve_fail");
    await assertActiveHermesGatewayEntitlement(uid);
    const clientId = requiredIdentifier(request.data.clientId, "clientId");
    const ref = db.doc(`users/${uid}/hermes_gateway_clients/${clientId}`);
    const snap = await ref.get();
    const client = snap.data();
    if (!snap.exists || !isHermesGatewayClientDoc(client)) {
      await recordCallableApprovalFailure(uid, "hermes_gateway_approve_fail");
      throw new HttpsError("not-found", "Hermes Gateway client not found.");
    }
    if (client.status !== "active") {
      throw new HttpsError("failed-precondition", "Revoked Hermes Gateway clients cannot be rotated.");
    }
    if (!client.agentClientSigningPublicKeyBase64 || client.popRequired !== true) {
      throw new HttpsError(
        "failed-precondition",
        "Legacy Hermes Gateway clients must re-pair with request proof-of-possession.",
      );
    }
    const previousTokenHash = client.tokenHash;
    const token = generateHermesGatewayBearerToken();
    const tokenHash = hashHermesGatewayBearerToken(token);
    if (tokenHash === previousTokenHash) {
      throw new HttpsError("aborted", "Token rotation collision; please retry.");
    }
    const now = nowISO();
    const tokenExpiresAt = gatewayTokenExpiryISO();
    // Atomic-enough swap: write the NEW index first (so a crash mid-rotation
    // leaves the new token usable rather than locking the client out), then
    // repoint the client doc, then delete the OLD index hash. The old token is
    // invalidated the moment the client doc's tokenHash changes because
    // resolveGatewayGrant re-derives and compares against the client doc.
    const batch = db.batch();
    batch.set(db.doc(`hermes_gateway_token_index/${tokenHash}`), {
      uid,
      clientId,
      status: "active",
      createdAt: now,
      expiresAt: tokenExpiresAt,
    });
    batch.set(
      ref,
      {
        tokenHash,
        tokenPreview: tokenPreview(token),
        expiresAt: tokenExpiresAt,
        rotatedAt: now,
        updatedAt: now,
      },
      { merge: true },
    );
    if (previousTokenHash && previousTokenHash !== tokenHash) {
      batch.delete(db.doc(`hermes_gateway_token_index/${previousTokenHash}`));
    }
    await batch.commit();
    logInfo({
      event: "hermes_gateway.token_rotated",
      user_id_hash: uid.slice(0, 8),
      client_id: clientId,
    });
    const rotated: HermesGatewayClientDoc = {
      ...client,
      tokenHash,
      tokenPreview: tokenPreview(token),
      expiresAt: tokenExpiresAt,
      rotatedAt: now,
      updatedAt: now,
    };
    return { client: publicClientView(rotated), accessToken: token, tokenType: "Bearer", expiresAt: tokenExpiresAt };
  }),
);

/**
 * Set a paired client's human-in-the-loop oversight mode. "supervised" arms an
 * approval gate before each risky agent action; "autonomous" runs unattended.
 * The runtime reads this via /state and obeys it. Default (unset) is supervised.
 */
export const setHermesGatewayOversightMode = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler(
    "setHermesGatewayOversightMode",
    async (request: CallableRequest<{ clientId?: unknown; mode?: unknown; deviceId?: unknown; nonce?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before changing Hermes Gateway oversight.");
      await assertActiveHermesGatewayEntitlement(uid);
      const clientId = requiredIdentifier(request.data.clientId, "clientId");
      const mode = sanitizeHermesGatewayOversightMode(request.data.mode);
      if (!mode) throw new HttpsError("invalid-argument", "mode must be 'supervised' or 'autonomous'.");
      await assertActiveHermesGatewayClient(uid, clientId);
      let elevatedByDeviceId: string | undefined;
      if (mode === "autonomous") {
        await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);
        elevatedByDeviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
        await assertTrustedNativeEscrowDevice(uid, elevatedByDeviceId);
      } else {
        enforceAuthAndAppCheck(request, uid);
      }
      const now = nowISO();
      await db.doc(`users/${uid}/hermes_gateway_clients/${clientId}`).set(
        stripUndefinedObject({
          oversightMode: mode,
          oversightModeUpdatedAt: now,
          oversightModeElevatedByDeviceId: elevatedByDeviceId,
          updatedAt: now,
        }),
        { merge: true },
      );
      logInfo({
        event: "hermes_gateway.oversight_mode_set",
        client_id: clientId,
        mode,
        elevated_by_device_id: elevatedByDeviceId,
      });
      return stripUndefinedObject({ clientId, oversightMode: mode, elevatedByDeviceId });
    },
  ),
);

/**
 * Resolve a Hermes Gateway oversight gate from a TRUSTED NATIVE device.
 *
 * This reuses the exact hardened approval semantics of the CLI-agent mission
 * primitive — App-Check-bound caller, a trusted native escrow device, single
 * transactional resolution, and a server-stamped `approvedByDeviceId` — but
 * targets the gateway's own `hermes_gateway_approvals` collection (the agent
 * arms gates over a bearer token and can never self-approve). It does NOT touch
 * the E2E-sealed `cli_agent_mission_requests` collection, which is client-created
 * and cannot be armed by a server-side gateway action.
 */
export const respondHermesGatewayApproval = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "respondHermesGatewayApproval",
    async (
      request: CallableRequest<{
        approvalId?: unknown;
        approve?: unknown;
        deviceId?: unknown;
        nonce?: unknown;
        actionProof?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before responding to an oversight request.");
      const nonce = boundedTrimmedString(request.data.nonce, "nonce", 256, true);
      await enforceHighRiskComputerUseCallableWithNonce(request, uid, nonce);
      const approvalId = boundedTrimmedString(request.data.approvalId, "approvalId", 160, true);
      const deviceId = boundedTrimmedString(request.data.deviceId, "deviceId", 160, true);
      if (typeof request.data.approve !== "boolean") {
        throw new HttpsError("invalid-argument", "approve must be a boolean.");
      }
      const approve = request.data.approve;
      await requireTrustedDeviceActionProof({
        uid,
        deviceId,
        actionKind: "hermes_gateway_approval",
        subjectId: approvalId,
        approve,
        nonce,
        proofRaw: request.data.actionProof,
        allowedPlatforms: NATIVE_ESCROW_PLATFORMS,
      });

      const approvalRef = db.doc(`users/${uid}/hermes_gateway_approvals/${approvalId}`);
      const deviceRef = db.doc(`users/${uid}/escrow_devices/${deviceId}`);

      const result = await db.runTransaction(async (transaction) => {
        const [approvalSnap, deviceSnap] = await Promise.all([
          transaction.get(approvalRef),
          transaction.get(deviceRef),
        ]);
        const approval = approvalSnap.data();
        if (!approvalSnap.exists || !isHermesGatewayApprovalDoc(approval)) {
          throw new HttpsError("not-found", "Oversight request was not found.");
        }
        if (approval.status !== "waiting_for_approval") {
          throw new HttpsError("failed-precondition", "Oversight request has already been resolved.");
        }
        if (isHermesGatewayApprovalExpired(approval.expiresAt)) {
          throw new HttpsError("failed-precondition", "Oversight request has expired.");
        }
        if (
          !deviceSnap.exists ||
          deviceSnap.get("trustState") !== "trusted" ||
          !NATIVE_ESCROW_PLATFORMS.has(deviceSnap.get("platform"))
        ) {
          throw new HttpsError(
            "permission-denied",
            "Oversight approvals require a trusted native device. Trust this device first.",
          );
        }
        transaction.set(
          approvalRef,
          {
            status: approve ? "approved" : "rejected",
            respondedAt: nowISO(),
            approvedByDeviceId: deviceId,
          },
          { merge: true },
        );
        const status: HermesGatewayApprovalDoc["status"] = approve ? "approved" : "rejected";
        return { status };
      });

      logInfo({
        event: "hermes_gateway.approval_resolved",
        approval_id: approvalId,
        approved_by_device_id: deviceId,
        status: result.status,
      });
      return { ok: true, approvalId, status: result.status, approvedByDeviceId: deviceId };
    },
  ),
);

/**
 * Reap oversight gates left unanswered past their TTL by flipping them to
 * "expired" so the phone UI and the agent both see a terminal state. Resolution
 * paths already fail-close on expiry (publicApprovalView derives "expired"), so
 * this is a tidy-up sweep, not a correctness dependency.
 */
export const reapHermesGatewayApprovals = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "UTC",
    region: FUNCTIONS_REGION,
    timeoutSeconds: 120,
  },
  async () => {
    const now = Date.now();
    const snap = await db
      .collectionGroup("hermes_gateway_approvals")
      .where("status", "==", "waiting_for_approval")
      .limit(400)
      .get();
    let reaped = 0;
    let batch = db.batch();
    for (const doc of snap.docs) {
      const approval = doc.data();
      if (!isHermesGatewayApprovalDoc(approval) || !isHermesGatewayApprovalExpired(approval.expiresAt, now)) continue;
      batch.set(doc.ref, { status: "expired", respondedAt: new Date(now).toISOString() }, { merge: true });
      reaped += 1;
      if (reaped % 400 === 0) {
        await batch.commit();
        batch = db.batch();
      }
    }
    if (reaped % 400 !== 0) await batch.commit();
    if (reaped > 0) logInfo({ event: "hermes_gateway.approvals_reaped", count: reaped });
  },
);
