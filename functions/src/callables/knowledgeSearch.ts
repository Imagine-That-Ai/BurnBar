/**
 * @fileoverview searchKnowledge — in-app Pensieve recall (E2EE).
 *
 * The hosted MCP tool (services/hosted-mcp burnbar_search_knowledge) serves
 * coding agents through the OAuth stdio shim. The BurnBar apps (iOS/iPad/macOS/
 * web console) authenticate with Firebase, not the MCP OAuth, so they need this
 * callable analog for in-app memory search.
 *
 * Zero-knowledge preserved end to end: the client embeds + CLOAKS the query
 * vector on-device with the vault key and sends only the opaque 384-dim vector.
 * The server runs Firestore vector ANN (findNearest, COSINE) over the member's
 * equally-cloaked stored vectors and returns SEALED ciphertext + metadata. The
 * client decrypts the hits on-device. The server never sees the query text, the
 * plaintext, or the vault key.
 */

import type { Query } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { wrapCallableHandler } from "../logging.js";
import { assertActiveBurnBarCloudProEntitlement, boundedTrimmedString } from "./shared.js";

const KNOWLEDGE_VECTOR_DIM = 384;
const MAX_LIMIT = 50;
const SOURCE_KINDS = new Set(["repo_docs", "notes", "chat_memory"]);

/** Validate the on-device-cloaked query vector: exactly 384 finite numbers. */
export function requireCloakedQueryVector(raw: unknown): number[] {
  if (!Array.isArray(raw) || raw.length !== KNOWLEDGE_VECTOR_DIM) {
    throw new HttpsError("invalid-argument", `queryVector must be a ${KNOWLEDGE_VECTOR_DIM}-dimension array.`);
  }
  const vec = raw.map((v) => Number(v));
  if (vec.some((v) => !Number.isFinite(v))) {
    throw new HttpsError("invalid-argument", "queryVector must contain only finite numbers.");
  }
  return vec;
}

export function clampLimit(raw: unknown): number {
  return Math.max(1, Math.min(Math.floor(Number(raw ?? 10)), MAX_LIMIT));
}

export const searchKnowledge = onCall(
  { region: "us-central1", enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 50 },
  wrapCallableHandler(
    "searchKnowledge",
    async (
      request: CallableRequest<{
        queryVector?: unknown;
        embeddingModelVersion?: unknown;
        sourceKind?: unknown;
        sourceSlug?: unknown;
        limit?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in to search your knowledge.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarCloudProEntitlement(uid);

      const queryVector = requireCloakedQueryVector(request.data?.queryVector);
      // Pin the model so we only compare vectors embedded the same way (cosine
      // across model versions is meaningless).
      const embeddingModelVersion = boundedTrimmedString(request.data?.embeddingModelVersion, "embeddingModelVersion", 120, true);
      const limit = clampLimit(request.data?.limit);

      // Plaintext-only server filters (sourceKind/sourceSlug are stored unsealed).
      const sourceKindRaw = boundedTrimmedString(request.data?.sourceKind, "sourceKind", 64, false);
      if (sourceKindRaw && !SOURCE_KINDS.has(sourceKindRaw)) {
        throw new HttpsError("invalid-argument", `sourceKind must be one of: ${[...SOURCE_KINDS].join(", ")}.`);
      }
      const sourceSlug = boundedTrimmedString(request.data?.sourceSlug, "sourceSlug", 256, false);

      let query: Query = db.collection(`users/${uid}/cloud_search_knowledge`).where("embeddingModelVersion", "==", embeddingModelVersion);
      if (sourceKindRaw) query = query.where("sourceKind", "==", sourceKindRaw);
      if (sourceSlug) query = query.where("sourceSlug", "==", sourceSlug);

      const snap = await query
        .findNearest({
          vectorField: "embedding",
          queryVector: FieldValue.vector(queryVector),
          limit,
          distanceMeasure: "COSINE",
          distanceResultField: "_distance",
        })
        .get();

      const hits = snap.docs.map((doc) => ({
        vectorId: doc.id,
        // sealed envelopes — opaque to the server; the client decrypts on-device.
        sealedCiphertext: doc.get("sealedCiphertext"),
        sealedMetadata: doc.get("sealedMetadata"),
        sourceKind: doc.get("sourceKind"),
        sourceSlug: doc.get("sourceSlug"),
        contentHash: doc.get("contentHash"),
        score: 1 - Number(doc.get("_distance") ?? 1), // COSINE distance -> similarity
        decryptMode: "local_decrypt",
      }));

      return { ok: true, hits, embeddingModelVersion };
    },
  ),
);
