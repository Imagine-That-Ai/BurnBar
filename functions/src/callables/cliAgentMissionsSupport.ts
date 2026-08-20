/**
 * Shared helpers for CLI-agent mission callables.
 */
import { createHash, randomBytes } from "node:crypto";

import { FieldValue, type Transaction } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { enforceHighRiskComputerUseCallableWithNonce } from "../appCheckAttestation.js";
import { db } from "../adminRuntime.js";
import { recordOrUndefined } from "../guards.js";
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
import {
  boundedTrimmedString,
  requirePathBoundCloudVaultSealedPayload,
} from "./shared.js";

export const MISSION_COLLECTION = "cli_agent_mission_requests";
export const LIVE_CANCEL_STATUSES = new Set([
  "pending",
  "accepted",
  "starting",
  "running",
  "waiting_for_approval",
]);
export const TERMINAL_STATUSES = new Set(["completed", "failed", "canceled", "cancelled"]);
const MAC_PLATFORMS = new Set(["macOS"]);
export const CREATE_PLATFORMS = new Set([...PHONE_CONTROL_ESCROW_PLATFORMS, "macOS"]);
export const CREATE_TOKENS = new Set<string>(MISSION_RUNTIME_CREATE_TOKENS);
export const EVENT_TOKENS = new Set<string>(MISSION_RUNTIME_EVENT_TOKENS);

export function hashNonce(raw: string): string {
  return createHash("sha256").update(raw, "utf8").digest("hex");
}

export function mintHostWriteNonce(): { raw: string; hash: string } {
  const raw = randomBytes(32).toString("base64url");
  return { raw, hash: hashNonce(raw) };
}

export function missionRef(uid: string, requestId: string) {
  return db.doc(`users/${uid}/${MISSION_COLLECTION}/${requestId}`);
}

function commandLockRef(uid: string, remoteCommandID: string) {
  return db.doc(`users/${uid}/_mission_command_locks/${remoteCommandID}`);
}

export function eventRef(uid: string, requestId: string, eventId: string) {
  return db.doc(`users/${uid}/${MISSION_COLLECTION}/${requestId}/events/${eventId}`);
}

export async function requireAuth(request: CallableRequest<Record<string, unknown>>): Promise<string> {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Authentication is required.");
  return uid;
}

export async function requirePhoneProof(args: {
  request: CallableRequest<Record<string, unknown>>;
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

export async function requireMacProof(args: {
  request: CallableRequest<Record<string, unknown>>;
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

export function requireRuntimeToken(value: unknown, field: string, allowed: Set<string>): string {
  const token = boundedTrimmedString(value, field, 80, true);
  if (!allowed.has(token) || !isKnownMissionRuntime(token)) {
    throw new HttpsError("invalid-argument", `${field} is not a catalog runtime.`);
  }
  return token;
}

export function requireSealed(
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
    if (value && typeof value === "object" && "_methodName" in value) {
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
  signalEnvelope?: ReturnType<typeof assertSignalAtRestEnvelopeForWrite>["envelope"];
  initialEvent: Record<string, unknown>;
};

export function parseCreateLeaf(
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
  let signalEnvelope: ReturnType<typeof assertSignalAtRestEnvelopeForWrite>["envelope"] | undefined;
  if (raw.signalEnvelope !== undefined) {
    signalEnvelope = assertSignalAtRestEnvelopeForWrite(raw.signalEnvelope, {
      uid,
      collection: MISSION_COLLECTION,
      docId: requestId,
      field: "signalEnvelope",
    }).envelope;
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

export async function writePendingMissionInTransaction(
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

