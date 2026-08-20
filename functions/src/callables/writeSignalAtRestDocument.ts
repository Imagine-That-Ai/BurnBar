import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { recordOrUndefined } from "../guards.js";
import { onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

type SignalAtRestDocumentRequest = {
  collection?: unknown;
  docId?: unknown;
  data?: unknown;
  documents?: unknown;
};

const MISSION_COLLECTION = "cli_agent_mission_requests";

function parseSignalDocument(raw: unknown): never {
  const input = recordOrUndefined(raw);
  if (!input) throw new HttpsError("invalid-argument", "Signal document must be an object.");
  if (input.collection === MISSION_COLLECTION) {
    throw new HttpsError("failed-precondition", "use createCliAgentMission");
  }
  throw new HttpsError("invalid-argument", "Unsupported Signal at-rest collection.");
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
    if (rawDocuments === undefined) {
      parseSignalDocument(input);
    }
    if (!Array.isArray(rawDocuments) || rawDocuments.length === 0 || rawDocuments.length > 100) {
      throw new HttpsError("invalid-argument", "documents must contain between 1 and 100 entries.");
    }
    rawDocuments.forEach((entry) => parseSignalDocument(entry));
  },
);
