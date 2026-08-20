/**
 * Server-owned CLI-agent mission create / claim / status / cancel / event append.
 * Firestore is a courier; daemon evaluate() remains the only attenuation authority.
 */

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

import { FieldValue, type Transaction } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { getConfig } from "../config.js";
import { recordOrUndefined } from "../guards.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { assertSignalAtRestEnvelopeForWrite } from "../signalAtRestWrite.js";
import {
  isKnownMissionRuntime,
  MISSION_RUNTIME_CREATE_TOKENS,
  MISSION_RUNTIME_EVENT_TOKENS,
} from "../generated/missionRuntimeCatalog.generated.js";
import {
  PHONE_CONTROL_ESCROW_PLATFORMS,
  boundedFirestoreDocumentId,
} from "./computerUseSecurityCodecs.js";
import { requireTrustedDeviceActionProof } from "./computerUseSecurityFirestore.js";
import { checkMissionCreateRateLimit } from "./publicRateLimit.js";
import {
  boundedTrimmedString,
  requirePathBoundCloudVaultSealedPayload,
} from "./shared.js";

const MISSION_COLLECTION = "cli_agent_mission_requests";
const LIVE_CANCEL_STATUSES = new Set([
  "pending",
  "accepted",
  "starting",
  "running",
  "waiting_for_approval",
]);
const TERMINAL_STATUSES = new Set(["completed", "failed", "canceled", "cancelled"]);
const MAC_PLATFORMS = new Set(["macOS"]);
const CREATE_PLATFORMS = new Set([...PHONE_CONTROL_ESCROW_PLATFORMS, "macOS"]);
const CREATE_TOKENS = new Set<string>(MISSION_RUNTIME_CREATE_TOKENS);
const EVENT_TOKENS = new Set<string>(MISSION_RUNTIME_EVENT_TOKENS);

const HOST_STATUS_TRANSITIONS: Record<string, ReadonlySet<string>> = {
  accepted: new Set(["starting", "waiting_for_approval", "failed", "canceled"]),
  starting: new Set(["running", "failed", "canceled"]),
  running: new Set(["completed", "failed", "canceled", "waiting_for_approval"]),
  waiting_for_approval: new Set(["accepted", "starting", "running", "canceled", "failed"]),
};

type MissionCallableRequest = {
  requestId?: unknown;
  remoteCommandID?: unknown;
  publicFields?: unknown;
  sealedPayload?: unknown;
  signalEnvelope?: unknown;
  initialEvent?: unknown;
  siblings?: unknown;
  nonce?: unknown;
  actionProof?: unknown;
  deviceId?: unknown;
  nextStatus?: unknown;
  selectedRuntime?: unknown;
  selectedRuntimeName?: unknown;
  selectedModelID?: unknown;
  approvalRequestId?: unknown;
  sealedStatePayload?: unknown;
  status?: unknown;
  hostWriteNonce?: unknown;
  releaseClaim?: unknown;
  eventId?: unknown;
  sealedEvent?: unknown;
  publicEventShape?: unknown;
};

function hashNonce(raw: string): string {
  return createHash("sha256").update(raw, "utf8").digest("hex");
}

function mintHostWriteNonce(): { raw: string; hash: string } {
  const raw = randomBytes(32).toString("base64url");
  return { raw, hash: hashNonce(raw) };
}

function missionRef(uid: string, requestId: string) {
  return db.doc(`users/${uid}/${MISSION_COLLECTION}/${requestId}`);
}

function commandLockRef(uid: string, remoteCommandID: string) {
  return db.doc(`users/${uid}/_mission_command_locks/${remoteCommandID}`);
}

function eventRef(uid: string, requestId: string, eventId: string) {
  return db.doc(`users/${uid}/${MISSION_COLLECTION}/${requestId}/events/${eventId}`);
}

async function requireAuth(request: CallableRequest<MissionCallableRequest>): Promise<string> {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Authentication is required.");
  return uid;
}

async function requirePhoneProof(args: {
  request: CallableRequest<MissionCallableRequest>;
  uid: string;
  deviceId: string;
  actionKind: string;
  subjectId: string;
  nonce: string;
}): Promise<void> {
  await enforceHighRiskComputerUseCallableWithNonce(args.request, args.uid, args.nonce);
  await requireTrustedDeviceActionProof({
    uid: args.uid,
    deviceId: args.deviceId,
    actionKind: args.actionKind,
    subjectId: args.subjectId,
    approve: true,
    nonce: args.nonce,
    proofRaw: args.request.data.actionProof,
    allowedPlatforms: PHONE_CONTROL_ESCROW_PLATFORMS,
  });
}

async function requireMacProof(args: {
  request: CallableRequest<MissionCallableRequest>;
  uid: string;
  deviceId: string;
  actionKind: string;
  subjectId: string;
  nonce: string;
}): Promise<void> {
  await enforceHighRiskComputerUseCallableWithNonce(args.request, args.uid, args.nonce);
  await requireTrustedDeviceActionProof({
    uid: args.uid,
    deviceId: args.deviceId,
    actionKind: args.actionKind,
    subjectId: args.subjectId,
    approve: true,
    nonce: args.nonce,
    proofRaw: args.request.data.actionProof,
    allowedPlatforms: MAC_PLATFORMS,
  });
}

function requireRuntimeToken(value: unknown, field: string, allowed: Set<string>): string {
  const token = boundedTrimmedString(value, field, 80, true);
  if (!allowed.has(token) || !isKnownMissionRuntime(token)) {
    throw new HttpsError("invalid-argument", `${field} is not a catalog runtime.`);
  }
  return token;
}

function requireSealed(
  raw: unknown,
  uid: string,
  collection: string,
  docId: string,
  field: string,
): Record<string, unknown> {
  return requirePathBoundCloudVaultSealedPayload(raw, uid, collection, docId, field);
}

const CREATE_PUBLIC_KEYS = new Set([
  "id",
  "missionKind",
  "requestedRuntime",
  "requestedModelID",
  "depth",
  "approvalMode",
  "commandsAllowed",
  "fileEditsAllowed",
  "source",
  "sourceSkillID",
  "sourceSurface",
  "deliveryMode",
  "presentationMode",
  "parentHermesThreadID",
  "schemaVersion",
  "groupID",
  "siblingIndex",
  "siblingCount",
  "isGroupChild",
  "personaID",
  "clientThreadID",
  "parentSessionID",
  "resumeAction",
  "originatorKind",
  "originatorRef",
  "targetBodyID",
]);

const PLAINTEXT_PUBLIC_KEYS = new Set([
  "title",
  "prompt",
  "liveSummary",
  "resultPreview",
  "errorMessage",
  "approvalTitle",
  "approvalMessage",
  "synthesisSummary",
  "targetProject",
]);

function parsePublicFields(raw: unknown, requestId: string): Record<string, unknown> {
  const fields = recordOrUndefined(raw);
  if (!fields) throw new HttpsError("invalid-argument", "publicFields must be an object.");
  const out: Record<string, unknown> = { id: requestId };
  for (const [key, value] of Object.entries(fields)) {
    if (PLAINTEXT_PUBLIC_KEYS.has(key)) continue;
    if (!CREATE_PUBLIC_KEYS.has(key)) continue;
    if (value && typeof value === "object" && "_methodName" in (value as object)) {
      throw new HttpsError("invalid-argument", `publicFields.${key} must not be a FieldValue sentinel.`);
    }
    out[key] = value;
  }
  if (fields.id !== undefined && fields.id !== requestId) {
    throw new HttpsError("invalid-argument", "publicFields.id must match requestId.");
  }
  return out;
}

type ParsedCreate = {
  requestId: string;
  remoteCommandID: string;
  publicFields: Record<string, unknown>;
  sealedPayload: Record<string, unknown>;
  signalEnvelope?: Record<string, unknown>;
  initialEvent: Record<string, unknown>;
};

function parseCreateLeaf(
  raw: Record<string, unknown>,
  uid: string,
): ParsedCreate {
  const requestId = boundedFirestoreDocumentId(raw.requestId, "requestId", 160);
  const remoteCommandID = boundedFirestoreDocumentId(raw.remoteCommandID, "remoteCommandID", 160);
  const publicFields = parsePublicFields(raw.publicFields, requestId);
  const requestedRuntime = requireRuntimeToken(
    publicFields.requestedRuntime ?? "auto",
    "requestedRuntime",
    CREATE_TOKENS,
  );
  const sealedPayload = requireSealed(raw.sealedPayload, uid, MISSION_COLLECTION, requestId, "sealedPayload");
  const initialEventRaw = recordOrUndefined(raw.initialEvent);
  if (!initialEventRaw) throw new HttpsError("invalid-argument", "initialEvent is required.");
  const sealedEvent = requireSealed(
    initialEventRaw.sealedEvent ?? initialEventRaw.sealedPayload ?? initialEventRaw,
    uid,
    `${MISSION_COLLECTION}/events`,
    `${requestId}/000001`,
    "sealedPayload",
  );
  let signalEnvelope: Record<string, unknown> | undefined;
  if (raw.signalEnvelope !== undefined) {
    signalEnvelope = assertSignalAtRestEnvelopeForWrite(raw.signalEnvelope, {
      uid,
      collection: MISSION_COLLECTION,
      docId: requestId,
      field: "signalEnvelope",
    }).envelope as Record<string, unknown>;
  }
  return {
    requestId,
    remoteCommandID,
    publicFields: { ...publicFields, requestedRuntime, id: requestId },
    sealedPayload,
    signalEnvelope,
    initialEvent: {
      sequence: 1,
      timestamp: new Date().toISOString(),
      kind: "status",
      phase: "queued",
      runtime: requestedRuntime,
      source: typeof publicFields.source === "string" ? publicFields.source : "ios",
      isError: false,
      contentSealed: true,
      sealedSchemaVersion: 2,
      vaultKeyID: sealedEvent.vaultKeyID,
      sealedPayload: sealedEvent,
    },
  };
}

function isNonTerminal(status: unknown): boolean {
  return typeof status === "string" && !TERMINAL_STATUSES.has(status);
}

function pendingMissionDocument(parsed: ParsedCreate): Record<string, unknown> {
  const now = FieldValue.serverTimestamp();
  const doc: Record<string, unknown> = {
    id: parsed.requestId,
    missionKind: parsed.publicFields.missionKind ?? "chat",
    requestedRuntime: parsed.publicFields.requestedRuntime,
    source: parsed.publicFields.source ?? "ios",
    schemaVersion: typeof parsed.publicFields.schemaVersion === "number" ? parsed.publicFields.schemaVersion : 2,
    remoteCommandID: parsed.remoteCommandID,
    status: "pending",
    lastEventSequence: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: parsed.sealedPayload.vaultKeyID,
    sealedPayload: parsed.sealedPayload,
    createdAt: now,
    updatedAt: now,
  };
  for (const key of CREATE_PUBLIC_KEYS) {
    if (key === "id") continue;
    if (parsed.publicFields[key] !== undefined) doc[key] = parsed.publicFields[key];
  }
  if (parsed.signalEnvelope) doc.signalEnvelope = parsed.signalEnvelope;
  return doc;
}

async function writePendingMissionInTransaction(
  tx: Transaction,
  uid: string,
  parsed: ParsedCreate,
): Promise<{ requestId: string; idempotent: boolean }> {
  const lock = commandLockRef(uid, parsed.remoteCommandID);
  const mission = missionRef(uid, parsed.requestId);
  const [lockSnap, missionSnap] = await Promise.all([tx.get(lock), tx.get(mission)]);
  if (lockSnap.exists) {
    const lockedId = String(lockSnap.get("requestId") ?? "");
    if (lockedId) {
      const lockedMission = await tx.get(missionRef(uid, lockedId));
      if (lockedMission.exists && isNonTerminal(lockedMission.get("status"))) {
        return { requestId: lockedId, idempotent: true };
      }
    }
  }
  if (missionSnap.exists) {
    const data = missionSnap.data() ?? {};
    if (data.remoteCommandID === parsed.remoteCommandID && isNonTerminal(data.status)) {
      return { requestId: parsed.requestId, idempotent: true };
    }
    throw new HttpsError("already-exists", "Mission requestId is already used.");
  }
  tx.create(mission, pendingMissionDocument(parsed));
  tx.create(eventRef(uid, parsed.requestId, "000001"), parsed.initialEvent);
  tx.set(lock, {
    requestId: parsed.requestId,
    remoteCommandID: parsed.remoteCommandID,
    updatedAt: FieldValue.serverTimestamp(),
  });
  return { requestId: parsed.requestId, idempotent: false };
}

export const createCliAgentMission = onCallProduction<
  MissionCallableRequest,
  { ok: true; requestId: string; idempotent?: boolean }
>(
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
    const siblings: ParsedCreate[] = [];
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
  MissionCallableRequest,
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
  MissionCallableRequest,
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
  MissionCallableRequest,
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
  MissionCallableRequest,
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
