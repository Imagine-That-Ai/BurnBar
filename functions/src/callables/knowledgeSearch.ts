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
import { assertActiveBurnBarCloudProEntitlement, boundedTrimmedString, requireHexDigest } from "./shared.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

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
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 50 },
  wrapCallableHandler(
    "searchKnowledge",
    async (
      request: CallableRequest<{
        queryVector?: unknown;
        embeddingModelVersion?: unknown;
        sourceKind?: unknown;
        sourceSlug?: unknown;
        slugHmac?: unknown;
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
      const embeddingModelVersion = boundedTrimmedString(
        request.data?.embeddingModelVersion,
        "embeddingModelVersion",
        120,
        true,
      );
      const limit = clampLimit(request.data?.limit);

      // Server filters carry no content (B-SEC-2): `sourceKind` is one of three
      // coarse buckets (accepted leakage) and the source filter is keyed by the
      // vault-keyed `slugHmac` the device sends — not the cleartext slug. Older
      // clients may still pass `sourceSlug`; we honor it so pre-B-SEC-2 rows stay
      // filterable until they are re-ingested under `slugHmac`.
      const sourceKindRaw = boundedTrimmedString(request.data?.sourceKind, "sourceKind", 64, false);
      if (sourceKindRaw && !SOURCE_KINDS.has(sourceKindRaw)) {
        throw new HttpsError("invalid-argument", `sourceKind must be one of: ${[...SOURCE_KINDS].join(", ")}.`);
      }
      const slugHmac =
        request.data?.slugHmac !== undefined ? requireHexDigest(request.data?.slugHmac, "slugHmac") : undefined;
      const sourceSlug = slugHmac
        ? undefined
        : boundedTrimmedString(request.data?.sourceSlug, "sourceSlug", 256, false);

      let query: Query = db
        .collection(`users/${uid}/cloud_search_knowledge`)
        .where("embeddingModelVersion", "==", embeddingModelVersion);
      if (sourceKindRaw) query = query.where("sourceKind", "==", sourceKindRaw);
      if (slugHmac) query = query.where("slugHmac", "==", slugHmac);
      else if (sourceSlug) query = query.where("sourceSlug", "==", sourceSlug);

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
        // Sealed envelopes — opaque to the server; the client decrypts on-device.
        // Field names match the hosted-MCP burnbar_search_knowledge hit shape AND
        // the iOS reader (PensieveMemorySearchView): `ciphertext` + `sealedMetadata`.
        // The real source path/slug live inside `sealedMetadata` (decrypted on
        // device); the server returns only the vault-keyed `slugHmac`/`dedupHash`
        // so the client can correlate hits without exposing a cleartext hash/path
        // (B-SEC-2). Legacy rows fall back to their pre-B-SEC-2 fields.
        ciphertext: doc.get("sealedCiphertext"),
        sealedMetadata: doc.get("sealedMetadata"),
        sourceKind: doc.get("sourceKind"),
        slugHmac: doc.get("slugHmac") ?? doc.get("sourceSlug"),
        dedupHash: doc.get("dedupHash") ?? doc.get("contentHash"),
        score: 1 - Number(doc.get("_distance") ?? 1), // COSINE distance -> similarity
        decryptMode: "local_decrypt",
      }));

      return { ok: true, hits, embeddingModelVersion };
    },
  ),
);
