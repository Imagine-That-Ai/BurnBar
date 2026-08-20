/**
 * Server-owned CLI-agent mission create / claim / status / cancel / event append.
 * Firestore is a courier; daemon evaluate() remains the only attenuation authority.
 */

import { timingSafeEqual } from "node:crypto";

import { FieldValue } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { getConfig } from "../config.js";
import { recordOrUndefined } from "../guards.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { boundedFirestoreDocumentId } from "./computerUseSecurityCodecs.js";
import { requireTrustedDeviceActionProof } from "./computerUseSecurityFirestore.js";
import { checkMissionCreateRateLimit } from "./publicRateLimit.js";
import { boundedTrimmedString } from "./shared.js";
import {
  CREATE_PLATFORMS,
  CREATE_TOKENS,
  EVENT_TOKENS,
  LIVE_CANCEL_STATUSES,
  MISSION_COLLECTION,
  TERMINAL_STATUSES,
  eventRef,
  hashNonce,
  mintHostWriteNonce,
  missionRef,
  parseCreateLeaf,
  requireAuth,
  requireMacProof,
  requirePhoneProof,
  requireRuntimeToken,
  requireSealed,
  writePendingMissionInTransaction,
} from "./cliAgentMissionsSupport.js";

const HOST_STATUS_TRANSITIONS: Record<string, ReadonlySet<string>> = {
  accepted: new Set(["starting", "waiting_for_approval", "failed", "canceled"]),
  starting: new Set(["running", "failed", "canceled"]),
  running: new Set(["completed", "failed", "canceled", "waiting_for_approval"]),
  waiting_for_approval: new Set(["accepted", "starting", "running", "canceled", "failed"]),
};

export function isLegalHostStatusTransition(from: string, to: string): boolean {
  return HOST_STATUS_TRANSITIONS[from]?.has(to) === true;
}

export const createCliAgentMission = onCallProduction<Record<string, unknown>, { ok: true; requestId: string; idempotent?: boolean }>(
  "createCliAgentMission",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request) => {
    const uid = await requireAuth(request);
    const nonce = boundedTrimmedString(request.data.nonce, "nonce", 256, true);
    const deviceId = boundedFirestoreDocumentId(request.data.deviceId, "deviceId", 160);
    const parent = parseCreateLeaf(recordOrUndefined(request.data) ?? {}, uid);
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, nonce);
    await requireTrustedDeviceActionProof({
      uid,
      deviceId,
      actionKind: "cli_agent_mission_create",
      subjectId: parent.requestId,
      approve: true,
      nonce,
      proofRaw: request.data.actionProof,
      allowedPlatforms: CREATE_PLATFORMS,
    });

    const siblingRaw = request.data.siblings;
    const siblings: Array<ReturnType<typeof parseCreateLeaf>> = [];
    if (siblingRaw !== undefined) {
      if (!Array.isArray(siblingRaw) || siblingRaw.length > 15) {
        throw new HttpsError("invalid-argument", "siblings must contain at most 15 entries.");
      }
      for (const entry of siblingRaw) {
        const rec = recordOrUndefined(entry);
        if (!rec) throw new HttpsError("invalid-argument", "sibling must be an object.");
        siblings.push(parseCreateLeaf(rec, uid));
      }
    }
    if (1 + siblings.length > 16) {
      throw new HttpsError("invalid-argument", "fan-out may include at most 16 missions.");
    }

    for (let i = 0; i < 1 + siblings.length; i += 1) {
      await checkMissionCreateRateLimit(uid);
    }

    const written = await db.runTransaction(async (tx) => {
      const parentWrite = await writePendingMissionInTransaction(tx, uid, parent);
      for (const sibling of siblings) {
        await writePendingMissionInTransaction(tx, uid, sibling);
      }
      return parentWrite;
    });
    logInfo({
      event: "callable_info",
      message: "cli_agent_mission_created",
      request_id: written.requestId,
      sibling_count: siblings.length,
    });
    return { ok: true, requestId: written.requestId, idempotent: written.idempotent };
  },
);

export const claimCliAgentMission = onCallProduction<
  Record<string, unknown>,
  { ok: true; requestId: string; hostWriteNonce: string; claimedBy: string; status: string }
>(
  "claimCliAgentMission",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request) => {
    const uid = await requireAuth(request);
    const nonce = boundedTrimmedString(request.data.nonce, "nonce", 256, true);
    const requestId = boundedFirestoreDocumentId(request.data.requestId, "requestId", 160);
    const deviceId = boundedFirestoreDocumentId(request.data.deviceId, "deviceId", 160);
    const nextStatus = boundedTrimmedString(request.data.nextStatus, "nextStatus", 40, true);
    if (nextStatus !== "accepted" && nextStatus !== "waiting_for_approval") {
      throw new HttpsError("invalid-argument", "nextStatus must be accepted or waiting_for_approval.");
    }
    const selectedRuntime = requireRuntimeToken(request.data.selectedRuntime, "selectedRuntime", CREATE_TOKENS);
    const selectedRuntimeName = boundedTrimmedString(
      request.data.selectedRuntimeName,
      "selectedRuntimeName",
      120,
      true,
    );
    const approvalRequestId =
      nextStatus === "waiting_for_approval"
        ? boundedFirestoreDocumentId(request.data.approvalRequestId, "approvalRequestId", 160)
        : undefined;
    if (nextStatus === "waiting_for_approval" && !approvalRequestId) {
      throw new HttpsError("invalid-argument", "approvalRequestId is required when claiming for approval.");
    }
    const sealedStatePayload = requireSealed(
      request.data.sealedStatePayload,
      uid,
      MISSION_COLLECTION,
      requestId,
      "sealedStatePayload",
    );
    await requireMacProof({
      request,
      uid,
      deviceId,
      actionKind: "cli_agent_mission_claim",
      subjectId: requestId,
      nonce,
    });

    const host = mintHostWriteNonce();
    const ref = missionRef(uid, requestId);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) throw new HttpsError("not-found", "Mission request was not found.");
      if (snap.get("status") !== "pending" || snap.get("claimedBy")) {
        throw new HttpsError("failed-precondition", "Mission is not available to claim.");
      }
      const write: Record<string, unknown> = {
        status: nextStatus,
        claimedBy: deviceId,
        selectedRuntime,
        selectedRuntimeName,
        hostWriteNonceHash: host.hash,
        sealedStatePayload,
        sealedStateSchemaVersion: 1,
        sealedStateVaultKeyID: sealedStatePayload.vaultKeyID,
        contentSealed: true,
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (request.data.selectedModelID !== undefined) {
        write.selectedModelID = boundedTrimmedString(request.data.selectedModelID, "selectedModelID", 160, true);
      }
      if (approvalRequestId) {
        write.approvalRequestId = approvalRequestId;
        write.approvalStatus = "pending";
        write.approvalRequestedAt = FieldValue.serverTimestamp();
      }
      tx.set(ref, write, { merge: true });
    });
    return {
      ok: true,
      requestId,
      hostWriteNonce: host.raw,
      claimedBy: deviceId,
      status: nextStatus,
    };
  },
);

function assertHostNonce(storedHash: unknown, presented: string): void {
  if (typeof storedHash !== "string" || storedHash.length !== 64) {
    throw new HttpsError("permission-denied", "hostWriteNonce does not match the claiming Mac.");
  }
  const expected = Buffer.from(storedHash, "hex");
  const actual = Buffer.from(hashNonce(presented), "hex");
  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
    throw new HttpsError("permission-denied", "hostWriteNonce does not match the claiming Mac.");
  }
}

export const updateCliAgentMissionStatus = onCallProduction<
  Record<string, unknown>,
  { ok: true; requestId: string; status: string }
>(
  "updateCliAgentMissionStatus",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request) => {
    const uid = await requireAuth(request);
    const nonce = boundedTrimmedString(request.data.nonce, "nonce", 256, true);
    const requestId = boundedFirestoreDocumentId(request.data.requestId, "requestId", 160);
    const deviceId = boundedFirestoreDocumentId(request.data.deviceId, "deviceId", 160);
    const hostWriteNonce = boundedTrimmedString(request.data.hostWriteNonce, "hostWriteNonce", 128, true);
    if (request.data.releaseClaim === true) {
      const sealedStatePayload = requireSealed(
        request.data.sealedStatePayload,
        uid,
        MISSION_COLLECTION,
        requestId,
        "sealedStatePayload",
      );
      await requireMacProof({
        request,
        uid,
        deviceId,
        actionKind: "cli_agent_mission_status",
        subjectId: requestId,
        nonce,
      });
      const ref = missionRef(uid, requestId);
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists) throw new HttpsError("not-found", "Mission request was not found.");
        if (snap.get("claimedBy") !== deviceId) {
          throw new HttpsError("permission-denied", "Only the claiming Mac may release the claim.");
        }
        assertHostNonce(snap.get("hostWriteNonceHash"), hostWriteNonce);
        const current = snap.get("status");
        if (current !== "accepted") {
          throw new HttpsError("failed-precondition", "Only an accepted unstarted claim can be released.");
        }
        tx.set(
          ref,
          {
            status: "pending",
            claimedBy: FieldValue.delete(),
            hostWriteNonceHash: FieldValue.delete(),
            selectedRuntime: FieldValue.delete(),
            selectedRuntimeName: FieldValue.delete(),
            sealedStatePayload,
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      });
      return { ok: true, requestId, status: "pending" };
    }
    const status = boundedTrimmedString(request.data.status, "status", 80, true);
    if (!["starting", "running", "completed", "failed", "canceled", "waiting_for_approval"].includes(status)) {
      throw new HttpsError("invalid-argument", "status is not a legal host transition.");
    }
    const approvalRequestId =
      status === "waiting_for_approval"
        ? boundedFirestoreDocumentId(request.data.approvalRequestId, "approvalRequestId", 160)
        : undefined;
    if (status === "waiting_for_approval" && !approvalRequestId) {
      throw new HttpsError("invalid-argument", "approvalRequestId is required when parking for approval.");
    }
    const sealedStatePayload = requireSealed(
      request.data.sealedStatePayload,
      uid,
      MISSION_COLLECTION,
      requestId,
      "sealedStatePayload",
    );
    await requireMacProof({
      request,
      uid,
      deviceId,
      actionKind: "cli_agent_mission_status",
      subjectId: requestId,
      nonce,
    });

    const ref = missionRef(uid, requestId);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) throw new HttpsError("not-found", "Mission request was not found.");
      if (snap.get("claimedBy") !== deviceId) {
        throw new HttpsError("permission-denied", "Only the claiming Mac may update status.");
      }
      assertHostNonce(snap.get("hostWriteNonceHash"), hostWriteNonce);
      const current = snap.get("status");
      if (typeof current !== "string" || TERMINAL_STATUSES.has(current)) {
        throw new HttpsError("failed-precondition", "Host cannot revive a terminal mission.");
      }
      const allowed = HOST_STATUS_TRANSITIONS[current];
      if (!allowed || !allowed.has(status)) {
        throw new HttpsError("failed-precondition", `Illegal host transition ${String(current)} → ${status}.`);
      }
      tx.set(
        ref,
        {
          status,
          sealedStatePayload,
          sealedStateSchemaVersion: 1,
          sealedStateVaultKeyID: sealedStatePayload.vaultKeyID,
          contentSealed: true,
          updatedAt: FieldValue.serverTimestamp(),
          ...(status === "completed" || status === "failed" || status === "canceled"
            ? { completedAt: FieldValue.serverTimestamp() }
            : {}),
          ...(status === "starting" || status === "running" ? { startedAt: FieldValue.serverTimestamp() } : {}),
          ...(approvalRequestId
            ? {
                approvalRequestId,
                approvalStatus: "pending",
                approvalRequestedAt: FieldValue.serverTimestamp(),
              }
            : {}),
        },
        { merge: true },
      );
    });
    return { ok: true, requestId, status };
  },
);

export const cancelCliAgentMission = onCallProduction<
  Record<string, unknown>,
  { ok: true; requestId: string; status: "cancelled" }
>(
  "cancelCliAgentMission",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request) => {
    const uid = await requireAuth(request);
    const nonce = boundedTrimmedString(request.data.nonce, "nonce", 256, true);
    const requestId = boundedFirestoreDocumentId(request.data.requestId, "requestId", 160);
    const deviceId = boundedFirestoreDocumentId(request.data.deviceId, "deviceId", 160);
    const sealedStatePayload = requireSealed(
      request.data.sealedStatePayload,
      uid,
      MISSION_COLLECTION,
      requestId,
      "sealedStatePayload",
    );
    await requirePhoneProof({
      request,
      uid,
      deviceId,
      actionKind: "cli_agent_mission_cancel",
      subjectId: requestId,
      nonce,
    });

    const ref = missionRef(uid, requestId);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) throw new HttpsError("not-found", "Mission request was not found.");
      const current = snap.get("status");
      if (typeof current !== "string" || !LIVE_CANCEL_STATUSES.has(current)) {
        throw new HttpsError("failed-precondition", "Cancel is not allowed from a terminal status.");
      }
      tx.set(
        ref,
        {
          status: "cancelled",
          sealedStatePayload,
          sealedStateSchemaVersion: 1,
          sealedStateVaultKeyID: sealedStatePayload.vaultKeyID,
          contentSealed: true,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    });
    return { ok: true, requestId, status: "cancelled" };
  },
);

export const appendCliAgentMissionEvent = onCallProduction<
  Record<string, unknown>,
  { ok: true; requestId: string; eventId: string }
>(
  "appendCliAgentMissionEvent",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  async (request) => {
    const uid = await requireAuth(request);
    const nonce = boundedTrimmedString(request.data.nonce, "nonce", 256, true);
    const requestId = boundedFirestoreDocumentId(request.data.requestId, "requestId", 160);
    const deviceId = boundedFirestoreDocumentId(request.data.deviceId, "deviceId", 160);
    const hostWriteNonce = boundedTrimmedString(request.data.hostWriteNonce, "hostWriteNonce", 128, true);
    const eventId = boundedFirestoreDocumentId(request.data.eventId, "eventId", 32);
    if (!/^\d{6}$/u.test(eventId)) {
      throw new HttpsError("invalid-argument", "eventId must be a zero-padded sequence.");
    }
    const shape = recordOrUndefined(request.data.publicEventShape);
    if (!shape) throw new HttpsError("invalid-argument", "publicEventShape is required.");
    for (const forbidden of ["title", "message", "fullMessage"]) {
      if (forbidden in shape) {
        throw new HttpsError("invalid-argument", "event public shape must not include plaintext.");
      }
    }
    const sequence = shape.sequence;
    if (typeof sequence !== "number" || !Number.isInteger(sequence) || sequence < 2) {
      throw new HttpsError("invalid-argument", "publicEventShape.sequence must be an integer ≥ 2.");
    }
    const expectedId = String(sequence).padStart(6, "0");
    if (eventId !== expectedId) {
      throw new HttpsError("invalid-argument", "eventId must match publicEventShape.sequence.");
    }
    const runtime = requireRuntimeToken(shape.runtime, "runtime", EVENT_TOKENS);
    const kind = boundedTrimmedString(shape.kind, "kind", 80, true);
    const phase = boundedTrimmedString(shape.phase, "phase", 80, true);
    if (shape.source !== "mac") throw new HttpsError("invalid-argument", "event source must be mac.");
    const sealedEvent = requireSealed(
      request.data.sealedEvent,
      uid,
      `${MISSION_COLLECTION}/events`,
      `${requestId}/${eventId}`,
      "sealedPayload",
    );
    await requireMacProof({
      request,
      uid,
      deviceId,
      actionKind: "cli_agent_mission_append_event",
      subjectId: requestId,
      nonce,
    });

    const parent = missionRef(uid, requestId);
    const ev = eventRef(uid, requestId, eventId);
    await db.runTransaction(async (tx) => {
      const [mission, existing] = await Promise.all([tx.get(parent), tx.get(ev)]);
      if (!mission.exists) throw new HttpsError("not-found", "Mission request was not found.");
      if (mission.get("claimedBy") !== deviceId) {
        throw new HttpsError("permission-denied", "Only the claiming Mac may append events.");
      }
      assertHostNonce(mission.get("hostWriteNonceHash"), hostWriteNonce);
      if (existing.exists) {
        throw new HttpsError("already-exists", "Duplicate eventId.");
      }
      const last = mission.get("lastEventSequence");
      const lastSeq = typeof last === "number" ? last : 1;
      if (sequence !== lastSeq + 1) {
        throw new HttpsError("failed-precondition", "event sequence must be the next value.");
      }
      tx.set(ev, {
        sequence,
        timestamp: new Date().toISOString(),
        kind,
        phase,
        runtime,
        source: "mac",
        isError: shape.isError === true,
        contentSealed: true,
        sealedSchemaVersion: 2,
        vaultKeyID: sealedEvent.vaultKeyID,
        sealedPayload: sealedEvent,
      });
      tx.set(
        parent,
        { lastEventSequence: sequence, updatedAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
    });
    return { ok: true, requestId, eventId };
  },
);
