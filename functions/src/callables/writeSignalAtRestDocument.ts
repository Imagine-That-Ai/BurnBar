import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { recordOrUndefined } from "../guards.js";
import { logInfo, onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { assertSignalAtRestEnvelopeForWrite } from "../signalAtRestWrite.js";

type SignalAtRestDocumentRequest = {
  collection?: unknown;
  docId?: unknown;
  data?: unknown;
  documents?: unknown;
};

const MISSION_COLLECTION = "cli_agent_mission_requests";
const MISSION_KEYS = new Set([
  "id", "missionKind", "requestedRuntime", "requestedModelID", "depth", "approvalMode", "commandsAllowed",
  "fileEditsAllowed", "source", "sourceSkillID", "sourceSurface", "deliveryMode", "presentationMode",
  "parentHermesThreadID", "status", "createdAt", "updatedAt", "startedAt", "completedAt", "claimedBy",
  "selectedRuntime", "selectedRuntimeName", "selectedModelID", "sessionId", "approvalRequestId", "approvalStatus",
  "approvalRequestedAt", "approvalRespondedAt", "lastEventSequence", "schemaVersion", "groupID", "siblingIndex",
  "siblingCount", "isGroupChild", "personaID", "clientThreadID", "parentSessionID", "resumeAction",
  "contentSealed", "sealedSchemaVersion", "vaultKeyID", "sealedPayload", "signalEnvelope",
]);

function requiredAtRestWrites(): boolean {
  return [
    process.env.OPENBURNBAR_SIGNAL_AT_REST_REQUIRED,
    process.env.OPENBURNBAR_SIGNAL_AT_REST_WRITES_REQUIRED,
  ].some((value) => value === "1" || value === "true");
}

function boundedIdentifier(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 512 || /[\r\n/]/u.test(value)) {
    throw new HttpsError("invalid-argument", `${label} must be a bounded identifier.`);
  }
  return value;
}

function requireMissionPublicShape(data: Record<string, unknown>, docId: string): void {
  if (!Object.keys(data).every((key) => MISSION_KEYS.has(key))) {
    throw new HttpsError("invalid-argument", "Signal mission payload contains an unlisted field.");
  }
  if (data.id !== docId || typeof data.status !== "string" || typeof data.missionKind !== "string") {
    throw new HttpsError("invalid-argument", "Signal mission payload identity/status is invalid.");
  }
  if (typeof data.requestedRuntime !== "string" || typeof data.source !== "string") {
    throw new HttpsError("invalid-argument", "Signal mission routing metadata is invalid.");
  }
  if (typeof data.schemaVersion !== "number" || !Number.isInteger(data.schemaVersion) || data.schemaVersion < 1) {
    throw new HttpsError("invalid-argument", "Signal mission schemaVersion is invalid.");
  }
}

function parseSignalDocument(
  raw: unknown,
  uid: string,
): { collection: typeof MISSION_COLLECTION; docId: string; data: Record<string, unknown> } {
  const input = recordOrUndefined(raw);
  if (!input) throw new HttpsError("invalid-argument", "Signal document must be an object.");
  const collection = input.collection === MISSION_COLLECTION
    ? MISSION_COLLECTION
    : (() => { throw new HttpsError("invalid-argument", "Unsupported Signal at-rest collection."); })();
  const docId = boundedIdentifier(input.docId, "docId");
  const data = recordOrUndefined(input.data);
  if (!data) throw new HttpsError("invalid-argument", "data must be an object.");
  requireMissionPublicShape(data, docId);
  const envelope = assertSignalAtRestEnvelopeForWrite(data.signalEnvelope, {
    uid,
    collection,
    docId,
    field: "signalEnvelope",
  }).envelope;
  if (requiredAtRestWrites() && ("contentSealed" in data || "sealedPayload" in data)) {
    throw new HttpsError("failed-precondition", "Signal at-rest required mode rejects legacy siblings.");
  }
  return {
    collection,
    docId,
    data: { ...data, signalEnvelope: envelope },
  };
}

export const writeSignalAtRestDocument = onCallProduction<SignalAtRestDocumentRequest, { ok: true }>(
  "writeSignalAtRestDocument",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: true,
    maxInstances: 100,
  },
  async (request: CallableRequest<SignalAtRestDocumentRequest>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Authentication is required.");

    const input = recordOrUndefined(request.data) ?? {};
    const rawDocuments = input.documents;
    const documents = rawDocuments === undefined
      ? [parseSignalDocument(input, uid)]
      : (() => {
          if (!Array.isArray(rawDocuments) || rawDocuments.length === 0 || rawDocuments.length > 100) {
            throw new HttpsError("invalid-argument", "documents must contain between 1 and 100 entries.");
          }
          return rawDocuments.map((entry) => parseSignalDocument(entry, uid));
        })();
    const batch = db.batch();
    for (const document of documents) {
      const persisted: Record<string, unknown> = { ...document.data, updatedAt: Timestamp.now() };
      batch.set(
        db.collection("users").doc(uid).collection(document.collection).doc(document.docId),
        persisted,
      );
    }
    await batch.commit();
    logInfo({
      event: "signal_at_rest_document_written",
      collection: MISSION_COLLECTION,
      documents: documents.length,
      schema_version: typeof documents[0].data.schemaVersion === "number" ? documents[0].data.schemaVersion : 0,
      required_mode: requiredAtRestWrites(),
    });
    return { ok: true };
  },
);
