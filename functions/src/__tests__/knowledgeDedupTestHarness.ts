/**
 * Shared in-memory Firestore double + device-side derivation helpers for the
 * knowledge dedup suites (`knowledgeMemoryDedupHash.test.ts` and
 * `knowledgeMemoryDedupLifecycle.test.ts`). Extracted so each suite stays
 * under the repo's max-lines lint floor without duplicating the harness.
 *
 * Both suites must install the same module mocks (logger, sentry, auth,
 * callables/shared, firebase-admin/firestore, adminRuntime) and reference
 * `FIELD_DELETE` / `makeDb` from here via async `vi.mock` factories, so the
 * harness and the mocked runtime share ONE `stored` map instance.
 */
import { createHash, createHmac, hkdfSync } from "node:crypto";

import { runFakeFirestoreTransaction } from "./fakeFirestoreTransaction.js";

/** Sentinel returned by the mocked `FieldValue.delete()`. */
export const FIELD_DELETE = Symbol("FieldValue.delete");

// In-memory Firestore double. Records every `.set()` on the knowledge collection
// keyed by `users/{uid}/cloud_search_knowledge/{vectorId}` so tests can dump
// the stored record.
export const stored = new Map<string, Record<string, unknown>>();

type FakeRef = {
  __path: string;
  get: () => Promise<unknown>;
  set: (data: Record<string, unknown>) => Promise<void>;
  delete: () => Promise<void>;
};

function applySet(path: string, data: Record<string, unknown>) {
  const merged = { ...stored.get(path), ...data };
  for (const key of Object.keys(merged)) {
    if (merged[key] === FIELD_DELETE) delete merged[key];
  }
  stored.set(path, merged);
}

type WherePred = { field: string; op: string; value: unknown };

/** A doc snapshot shaped like a Firestore QueryDocumentSnapshot for the query path. */
function docSnap(path: string) {
  return {
    id: path.split("/").pop(),
    ref: { __path: path },
    exists: stored.has(path),
    data: () => stored.get(path),
    get: (field: string) => stored.get(path)?.[field],
  };
}

/**
 * A query double that RECORDS `where` predicates and honors them on `.get()`
 * (so the dedupHashVersion / embeddingModelVersion floors are actually tested)
 * and on `.findNearest()` (search) — mirroring the predicate-recording pattern
 * used in privacyBackfill.test.ts. `limit` caps results; `findNearest` ignores
 * vector distance (the fake just returns the filtered set, score-less).
 */
function makeQuery(base: string, preds: WherePred[] = [], limitN = Infinity) {
  const matchingPaths = () =>
    [...stored.keys()].filter((path) => {
      if (!path.startsWith(`${base}/`)) return false;
      const data = stored.get(path) ?? {};
      return preds.every((p) => p.op === "==" && data[p.field] === p.value);
    });
  const self = {
    where: (field: string, op: string, value: unknown) => makeQuery(base, [...preds, { field, op, value }], limitN),
    limit: (n: number) => makeQuery(base, preds, n),
    findNearest: (_opts: unknown) => self, // distance ignored; filter set is what matters
    // Honour the where predicates so the cap aggregate's `dedupHashVersion == 1`
    // floor is actually exercised (count + sum(byteCount) over the matching set).
    aggregate: (_spec: unknown) => ({
      get: async () => {
        const paths = matchingPaths();
        const n = paths.length;
        const bytes = paths.reduce((acc, path) => acc + Number(stored.get(path)?.byteCount ?? 0), 0);
        return { data: () => ({ n, bytes }) };
      },
    }),
    get: async () => {
      const paths = matchingPaths().slice(0, limitN);
      const docs = paths.map((path) => docSnap(path));
      return { empty: docs.length === 0, size: docs.length, docs };
    },
  };
  return self;
}

export function makeDb() {
  const docRef = (path: string): FakeRef => ({
    __path: path,
    get: async () => ({
      id: path.split("/").pop(),
      exists: stored.has(path),
      data: () => stored.get(path),
      get: (field: string) => stored.get(path)?.[field],
    }),
    set: async (data: Record<string, unknown>) => applySet(path, data),
    delete: async () => void stored.delete(path),
  });
  const collectionRef = (base: string) => ({
    doc: (id: string) => docRef(`${base}/${id}`),
    // Unfiltered aggregate (no `.where`) counts the whole collection — the
    // commit path no longer uses this (it floors `dedupHashVersion == 1`), but
    // keep it consistent with the filtered makeQuery aggregate.
    aggregate: (spec: unknown) => makeQuery(base).aggregate(spec),
    count: () => ({
      get: async () => {
        const count = [...stored.keys()].filter((path) => path.startsWith(`${base}/`)).length;
        return { data: () => ({ count }) };
      },
    }),
    where: (field: string, op: string, value: unknown) => makeQuery(base, [{ field, op, value }]),
  });
  return {
    doc: (path: string) => docRef(path),
    collection: (path: string) => collectionRef(path),
    getAll: async (...refs: FakeRef[]) => Promise.all(refs.map((r) => r.get())),
    // Mirrors commitBatchedWrites' use of db.batch() + batch.set(ref, data).
    batch: () => ({
      set: (ref: FakeRef, data: Record<string, unknown>) => applySet(ref.__path, data),
      delete: (ref: { __path: string }) => void stored.delete(ref.__path),
      commit: async () => undefined,
    }),
    runTransaction: runFakeFirestoreTransaction,
  };
}

// --- Device-side derivation (mirrors what PensieveKnowledgeChunker must ship) ---
export const PLAINTEXT = "deploy the daemon before midnight";
export const SOURCE_PATH = "/Users/alberto/Documents/Windsurf/BurnBar/docs/secret-runbook.md";
const SOURCE_SLUG = "burnbar-docs-secret-runbook";
export const KNOWN_PLAINTEXT_SHA256 = createHash("sha256").update(PLAINTEXT, "utf8").digest("hex");

/** HKDF-derive a per-user dedup key from the vault key, then HMAC the value. */
function vaultKeyedHmac(vaultKey: Buffer, label: string, value: string): string {
  const dedupKey = Buffer.from(hkdfSync("sha256", vaultKey, Buffer.alloc(0), `pensieve-dedup:${label}`, 32));
  return createHmac("sha256", dedupKey).update(value, "utf8").digest("hex");
}

function sealedText(tag: string) {
  // requireSealedText demands base64 nonce/ciphertext/tag (opaque to the server).
  const b64 = (s: string) => Buffer.from(s, "utf8").toString("base64");
  return {
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    nonce: b64(`${tag}-nonce`),
    ciphertext: b64(`${tag}-ciphertext`),
    tag: b64(`${tag}-tag`),
  };
}

export function callableRequest<T extends Record<string, unknown>>(uid: string, data: T) {
  return { auth: { uid, token: {} }, app: { appId: "test-app" }, rawRequest: { headers: {} }, data };
}

export function signalEnvelopeForKnowledgeVector(uid: string, docId: string, overrides: Record<string, unknown> = {}) {
  const b64 = (s: string) => Buffer.from(s, "utf8").toString("base64");
  return {
    signalEnvelopeFormatVersion: 1,
    mode: "at-rest",
    relayEncryption: "signal-hpke-identity-seal-v1",
    ciphertextLayer: {
      payloadCiphertextB64: b64("signal-payload"),
      payloadAADLabel: "cloudvault:cloud_search_knowledge/sealedCiphertext",
      schemaVersion: 1,
    },
    keyDelivery: {
      scheme: "signal-hpke-identity-seal-v1",
      contentKeyLength: 32,
      wraps: [
        {
          recipientKind: "device",
          recipientIdentityKeyId: "device-1",
          recipientIdentityKeyB64: b64("identity-key"),
          sealedContentKeyB64: b64("sealed-content-key"),
        },
      ],
    },
    binding: {
      uid,
      scope: "cloudvault",
      collection: "cloud_search_knowledge",
      docId,
      field: "sealedCiphertext",
      mode: "at-rest",
      formatVersion: 1,
    },
    senderAuth: {
      senderIdentityKeyId: "sender-device-1",
      senderIdentityKeyB64: Buffer.alloc(33, 4).toString("base64"),
      signatureB64: Buffer.alloc(64, 5).toString("base64"),
      signatureVersion: 1,
    },
    ...overrides,
  };
}

export function commitRequestForUser(uid: string, vaultKey: Buffer) {
  const dedupHash = vaultKeyedHmac(vaultKey, "content", PLAINTEXT);
  const slugHmac = vaultKeyedHmac(vaultKey, "slug", SOURCE_SLUG);
  return callableRequest(uid, {
    // Legacy request alias: older clients still send the opaque source
    // manifest id as `sourceSlug`. The server stores canonical
    // `sourceManifestId` on the manifest doc.
    sourceSlug: slugHmac,
    slugHmac,
    embeddingModelVersion: "bge-small-en-v1.5-cloak-v1",
    vectors: [
      {
        cloakedVector: Array.from({ length: 384 }, (_, i) => Math.sin(i) / 7),
        sealedCiphertext: sealedText("ct"),
        // The real path lives ONLY inside the sealed metadata blob.
        sealedMetadata: sealedText("md"),
        dedupHash,
        sourceKind: "repo_docs",
        chunkIndex: 0,
        byteCount: Buffer.byteLength(PLAINTEXT, "utf8"),
      },
    ],
  });
}

export function makeApprovedChatMemory(req: ReturnType<typeof commitRequestForUser>) {
  const vector = vectorForMutation(req);
  vector.sourceKind = "chat_memory";
  vector.reviewStatus = "approved";
  vector.provenance = {
    schemaVersion: 1,
    sourceKind: "chat_memory",
    reviewStatus: "approved",
    sourceSlugHmac: req.data.slugHmac,
    sourceTranscriptHash: "11".repeat(32),
    extractorKind: "claude-cli",
    extractorPromptHash: "22".repeat(32),
    extractorOutputHash: "33".repeat(32),
    extractorPromptVersion: "pensieve-chat-memory-v1",
    createdAt: "2026-06-13T00:00:00.000Z",
    approvedAt: "2026-06-13T00:01:00.000Z",
  };
  return vector;
}

export function callableRun(callable: unknown): (request: unknown) => Promise<unknown> {
  const run = Reflect.get(Object(callable), "run");
  if (typeof run !== "function") {
    throw new Error("Expected callable to expose run()");
  }
  return run;
}

export function firstKnowledgeRecord(uid: string): Record<string, unknown> {
  const found = [...stored.entries()].find(([k]) => k.startsWith(`users/${uid}/cloud_search_knowledge/`));
  if (!found) {
    throw new Error(`Expected stored knowledge record for ${uid}`);
  }
  return found[1];
}

export function manifestRecord(uid: string, sourceManifestId: string): Record<string, unknown> {
  const record = stored.get(`users/${uid}/knowledge_sync_manifests/${sourceManifestId}`);
  if (!record) {
    throw new Error(`Expected manifest record for ${uid}/${sourceManifestId}`);
  }
  return record;
}

export function vectorForMutation(req: ReturnType<typeof commitRequestForUser>): Record<string, unknown> {
  const [vector] = req.data.vectors;
  if (!vector) {
    throw new Error("Expected request vector");
  }
  return vector;
}

export function rawHitsFromResult(result: unknown): Array<Record<string, unknown>> {
  const hits = Reflect.get(Object(result), "hits");
  if (!Array.isArray(hits)) {
    throw new Error("Expected search result hits");
  }
  return hits.filter((hit): hit is Record<string, unknown> => !!hit && typeof hit === "object" && !Array.isArray(hit));
}

export function hitsFromResult(result: unknown): Array<{ vectorId: string }> {
  return rawHitsFromResult(result).flatMap((hit) => {
    const vectorId = Reflect.get(Object(hit), "vectorId");
    return typeof vectorId === "string" ? [{ vectorId }] : [];
  });
}

export function purgeCounts(result: unknown): { deletedByVersion: unknown; deletedByRetiredTag: unknown; deleted: unknown } {
  return {
    deletedByVersion: Reflect.get(Object(result), "deletedByVersion"),
    deletedByRetiredTag: Reflect.get(Object(result), "deletedByRetiredTag"),
    deleted: Reflect.get(Object(result), "deleted"),
  };
}

export const NEW_MODEL_TAG = "bge-small-en-v1.5-vault-dedup-v1";
export const RETIRED_MODEL_TAG = "bge-small-en-v1.5";

export function searchRequest(uid: string, modelTag: string) {
  return callableRequest(uid, {
    queryVector: Array.from({ length: 384 }, (_, i) => Math.cos(i) / 9),
    embeddingModelVersion: modelTag,
    limit: 50,
  });
}

export function seedVector(
  uid: string,
  vectorId: string,
  fields: { dedupHashVersion: number; embeddingModelVersion: string; dedupHash: string; byteCount?: number },
) {
  stored.set(`users/${uid}/cloud_search_knowledge/${vectorId}`, {
    uid,
    vectorId,
    sealedCiphertext: sealedText("ct"),
    sealedMetadata: sealedText("md"),
    sourceKind: "repo_docs",
    chunkIndex: 0,
    byteCount: fields.byteCount ?? 16,
    embedding: { __vector: Array.from({ length: 384 }, () => 0) },
    ...fields,
  });
}

export function seedRows(uid: string, count: number, dedupHashVersion: number, idPrefix: string) {
  for (let i = 0; i < count; i += 1) {
    seedVector(uid, `${idPrefix}${i}`, {
      dedupHashVersion,
      embeddingModelVersion: dedupHashVersion === 1 ? NEW_MODEL_TAG : RETIRED_MODEL_TAG,
      dedupHash: `${idPrefix}-${i}`,
    });
  }
}

export function okFromResult(result: unknown): { ok: unknown; written: unknown; chunkCount: unknown } {
  return {
    ok: Reflect.get(Object(result), "ok"),
    written: Reflect.get(Object(result), "written"),
    chunkCount: Reflect.get(Object(result), "chunkCount"),
  };
}
