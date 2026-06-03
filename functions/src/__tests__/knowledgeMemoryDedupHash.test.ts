/**
 * B-SEC-2 — plaintext metadata side channels. Proves the `commitKnowledgeBatch`
 * write path no longer persists a cleartext, confirm-the-guess SHA-256 of the
 * chunk plaintext, nor a cleartext repo path, and that the dedup hash is
 * vault-keyed so two members storing the SAME plaintext get DIFFERENT stored
 * hashes.
 *
 * The server is zero-knowledge: it never holds the vault key, so the device
 * sends the vault-keyed `dedupHash` (HKDF-derive a per-user dedup key from the
 * vault key, then HMAC the plaintext) and `slugHmac`. This test mimics that
 * device step with two distinct per-user keys, then dumps the captured stored
 * record and asserts the two security properties.
 */
import { createHash, createHmac, hkdfSync } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));
vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
// App Check / ownership enforced via env elsewhere; no-op for the in-process call.
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));

// Real validators (requireHexDigest, boundedTrimmedString, …) — only the Cloud
// Pro entitlement gate and the Ultra-tier lookup are stubbed so the call runs
// without Firestore entitlement docs.
vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return {
    ...actual,
    assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined),
    isActiveBurnBarUltraEntitlement: () => false,
  };
});

// Minimal firebase-admin/firestore: capture the doc payloads, stub the value
// wrappers + aggregate the loop reads.
vi.mock("firebase-admin/firestore", () => ({
  Timestamp: { now: () => ({ __ts: true }) },
  FieldValue: {
    vector: (v: number[]) => ({ __vector: v }),
    increment: (n: number) => ({ __increment: n }),
  },
  AggregateField: {
    count: () => ({ __count: true }),
    sum: (f: string) => ({ __sum: f }),
  },
}));

// In-memory Firestore double. Records every `.set()` on the knowledge collection
// keyed by `users/{uid}/cloud_search_knowledge/{vectorId}` so the test can dump
// the stored record.
const stored = new Map<string, Record<string, unknown>>();

type FakeRef = {
  __path: string;
  get: () => Promise<unknown>;
  set: (data: Record<string, unknown>) => Promise<void>;
  delete: () => Promise<void>;
};

function applySet(path: string, data: Record<string, unknown>) {
  stored.set(path, { ...stored.get(path), ...data });
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
    get: async () => {
      const paths = matchingPaths().slice(0, limitN);
      const docs = paths.map((path) => docSnap(path));
      return { empty: docs.length === 0, size: docs.length, docs };
    },
  };
  return self;
}

function makeDb() {
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
    aggregate: () => ({ get: async () => ({ data: () => ({ n: 0, bytes: 0 }) }) }),
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
  };
}

vi.mock("../adminRuntime.js", () => ({ db: makeDb(), auth: {} }));

process.env.ENFORCE_APP_CHECK = "false";

// --- Device-side derivation (mirrors what PensieveKnowledgeChunker must ship) ---
const PLAINTEXT = "deploy the daemon before midnight";
const SOURCE_PATH = "/Users/alberto/Documents/Windsurf/BurnBar/docs/secret-runbook.md";
const SOURCE_SLUG = "burnbar-docs-secret-runbook";
const KNOWN_PLAINTEXT_SHA256 = createHash("sha256").update(PLAINTEXT, "utf8").digest("hex");

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

function commitRequestForUser(uid: string, vaultKey: Buffer) {
  const dedupHash = vaultKeyedHmac(vaultKey, "content", PLAINTEXT);
  const slugHmac = vaultKeyedHmac(vaultKey, "slug", SOURCE_SLUG);
  return {
    auth: { uid, token: {} },
    app: { appId: "test-app" },
    rawRequest: { headers: {} },
    data: {
      // sourceSlug is now an OPAQUE vault-keyed hex source id (the cleartext slug
      // is rejected and never stored — privacy-leak-remediation §3); it is the
      // same HMAC(slug) the client derives for the manifest doc id.
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
    },
  };
}

function callableRun(callable: unknown): (request: unknown) => Promise<unknown> {
  const run = Reflect.get(Object(callable), "run");
  if (typeof run !== "function") {
    throw new Error("Expected callable to expose run()");
  }
  return run;
}

function firstKnowledgeRecord(uid: string): Record<string, unknown> {
  const found = [...stored.entries()].find(([k]) => k.startsWith(`users/${uid}/cloud_search_knowledge/`));
  if (!found) {
    throw new Error(`Expected stored knowledge record for ${uid}`);
  }
  return found[1];
}

function vectorForMutation(req: ReturnType<typeof commitRequestForUser>): Record<string, unknown> {
  const [vector] = req.data.vectors;
  if (!vector) {
    throw new Error("Expected request vector");
  }
  return vector;
}

function hitsFromResult(result: unknown): Array<{ vectorId: string }> {
  const hits = Reflect.get(Object(result), "hits");
  if (!Array.isArray(hits)) {
    throw new Error("Expected search result hits");
  }
  return hits.flatMap((hit) => {
    const vectorId = Reflect.get(Object(hit), "vectorId");
    return typeof vectorId === "string" ? [{ vectorId }] : [];
  });
}

function purgeCounts(result: unknown): { deletedByVersion: unknown; deletedByRetiredTag: unknown; deleted: unknown } {
  return {
    deletedByVersion: Reflect.get(Object(result), "deletedByVersion"),
    deletedByRetiredTag: Reflect.get(Object(result), "deletedByRetiredTag"),
    deleted: Reflect.get(Object(result), "deleted"),
  };
}

describe("commitKnowledgeBatch — B-SEC-2 vault-keyed dedup, no plaintext side channels", () => {
  beforeEach(() => stored.clear());
  afterEach(() => vi.clearAllMocks());

  it("two users + same plaintext -> different stored dedupHash (vault-keyed)", async () => {
    const { commitKnowledgeBatch } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(commitKnowledgeBatch);

    await run(commitRequestForUser("userA", Buffer.alloc(32, 0xa1)));
    const recA = firstKnowledgeRecord("userA");

    await run(commitRequestForUser("userB", Buffer.alloc(32, 0xb2)));
    const recB = firstKnowledgeRecord("userB");

    // Same plaintext, but per-user HKDF/HMAC keys -> different stored hashes.
    expect(typeof recA.dedupHash).toBe("string");
    expect(recA.dedupHash).not.toBe(recB.dedupHash);
    // …and neither equals the cleartext SHA-256 a curious server could guess.
    expect(recA.dedupHash).not.toBe(KNOWN_PLAINTEXT_SHA256);
    expect(recB.dedupHash).not.toBe(KNOWN_PLAINTEXT_SHA256);
    // Stamped as the keyed version so old rows stay distinguishable.
    expect(recA.dedupHashVersion).toBe(1);
  });

  it("a dump of a stored record contains NO field equal to the plaintext SHA-256 and NO cleartext repo path", async () => {
    const { commitKnowledgeBatch } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(commitKnowledgeBatch);

    await run(commitRequestForUser("userA", Buffer.alloc(32, 0xa1)));
    const record = firstKnowledgeRecord("userA");

    // Dump every leaf string (incl. the doc-id vectorId) and assert none is the
    // plaintext SHA-256 and none contains the real repo path.
    const leaves: string[] = [];
    const walk = (v: unknown) => {
      if (typeof v === "string") leaves.push(v);
      else if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === "object") Object.values(v).forEach(walk);
    };
    walk(record);

    expect(leaves).not.toContain(KNOWN_PLAINTEXT_SHA256);
    for (const leaf of leaves) {
      expect(leaf).not.toContain(SOURCE_PATH);
      expect(leaf).not.toContain("/Users/");
      expect(leaf).not.toBe(KNOWN_PLAINTEXT_SHA256);
    }
    // No cleartext path/slug columns survive on the stored row.
    expect(record).not.toHaveProperty("sourcePath");
    expect(record).not.toHaveProperty("sourceSlug");
    expect(record).not.toHaveProperty("contentHash");
    // The keyed filter column IS present.
    expect(typeof record.slugHmac).toBe("string");
  });

  it("FLAG-DAY: a legacy client (cleartext contentHash, no dedupHash/slugHmac) is REJECTED", async () => {
    // privacy-leak-remediation-2026-06-02 §3 (Option A): the write path now
    // REQUIRES the vault-keyed dedupHash + slugHmac and no longer accepts the
    // cleartext SHA-256 contentHash oracle, so a not-yet-updated client fails
    // instead of writing a v0 row.
    const { commitKnowledgeBatch } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(commitKnowledgeBatch);

    const req = commitRequestForUser("userLegacy", Buffer.alloc(32, 0xc3));
    // Simulate a not-yet-updated client: drop the keyed fields, send the old
    // cleartext SHA-256 contentHash instead.
    const vector = vectorForMutation(req);
    delete vector.dedupHash;
    vector.contentHash = KNOWN_PLAINTEXT_SHA256;
    Reflect.deleteProperty(req.data, "slugHmac");

    await expect(run(req)).rejects.toThrow();
    // Nothing was persisted for this legacy caller.
    expect([...stored.keys()].some((k) => k.startsWith("users/userLegacy/cloud_search_knowledge/"))).toBe(false);
  });

  it("a v1 client that omits cloakedVector (sends a raw embedding) is REJECTED", async () => {
    const { commitKnowledgeBatch } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(commitKnowledgeBatch);

    const req = commitRequestForUser("userRawEmbed", Buffer.alloc(32, 0xd4));
    const vec = vectorForMutation(req);
    vec.embedding = vec.cloakedVector; // legacy field name
    delete vec.cloakedVector;

    await expect(run(req)).rejects.toThrow(/cloakedVector/);
    expect([...stored.keys()].some((k) => k.startsWith("users/userRawEmbed/cloud_search_knowledge/"))).toBe(false);
  });
});

// --- FLAG-DAY: dedup-v0 retirement (read floor + whole-doc purge) -------------

// The bumped production tag every live v1 vector now lands under (must stay
// byte-identical to PensieveVectorCloak.embeddingModelVersion / embed.ts).
const NEW_MODEL_TAG = "bge-small-en-v1.5-vault-dedup-v1";
// The retired tag every stranded legacy v0 / ancient row still carries.
const RETIRED_MODEL_TAG = "bge-small-en-v1.5";

function searchRequest(uid: string, modelTag: string) {
  return {
    auth: { uid, token: {} },
    app: { appId: "test-app" },
    rawRequest: { headers: {} },
    data: {
      queryVector: Array.from({ length: 384 }, (_, i) => Math.cos(i) / 9),
      embeddingModelVersion: modelTag,
      limit: 50,
    },
  };
}

/** Seed a stored knowledge vector directly (bypassing the write path). */
function seedVector(
  uid: string,
  vectorId: string,
  fields: { dedupHashVersion: number; embeddingModelVersion: string; dedupHash: string },
) {
  stored.set(`users/${uid}/cloud_search_knowledge/${vectorId}`, {
    uid,
    vectorId,
    sealedCiphertext: sealedText("ct"),
    sealedMetadata: sealedText("md"),
    sourceKind: "repo_docs",
    chunkIndex: 0,
    byteCount: 16,
    embedding: { __vector: Array.from({ length: 384 }, () => 0) },
    ...fields,
  });
}

describe("dedup-v0 flag-day — search never serves v0, purge deletes it", () => {
  beforeEach(() => stored.clear());
  afterEach(() => vi.clearAllMocks());

  it("searchKnowledge floors dedupHashVersion==1: a seeded v0 row is NOT served", async () => {
    const { searchKnowledge } = await import("../callables/knowledgeSearch.js");
    const run = callableRun(searchKnowledge);

    // A legacy v0 row whose doc id is the cleartext SHA-256 oracle, on the old tag.
    seedVector("userSearch", KNOWN_PLAINTEXT_SHA256, {
      dedupHashVersion: 0,
      embeddingModelVersion: RETIRED_MODEL_TAG,
      dedupHash: KNOWN_PLAINTEXT_SHA256,
    });
    // A fresh v1 row on the new tag.
    seedVector("userSearch", "v1doc", {
      dedupHashVersion: 1,
      embeddingModelVersion: NEW_MODEL_TAG,
      dedupHash: "aa".repeat(32),
    });

    const ids = hitsFromResult(await run(searchRequest("userSearch", NEW_MODEL_TAG))).map((h) => h.vectorId);
    // The v0 oracle row is unreachable; only the v1 row surfaces.
    expect(ids).toContain("v1doc");
    expect(ids).not.toContain(KNOWN_PLAINTEXT_SHA256);
  });

  it("searchKnowledge at the new tag never returns a v0 row even on the retired tag", async () => {
    const { searchKnowledge } = await import("../callables/knowledgeSearch.js");
    const run = callableRun(searchKnowledge);

    // Only a v0 row exists, on the retired tag. Searching the new tag returns nothing.
    seedVector("userSearch2", KNOWN_PLAINTEXT_SHA256, {
      dedupHashVersion: 0,
      embeddingModelVersion: RETIRED_MODEL_TAG,
      dedupHash: KNOWN_PLAINTEXT_SHA256,
    });
    expect(hitsFromResult(await run(searchRequest("userSearch2", NEW_MODEL_TAG)))).toHaveLength(0);
  });

  it("purgeLegacyKnowledgeVectors deletes v0 + retired-tag rows, keeps v1", async () => {
    const { purgeLegacyKnowledgeVectors } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(purgeLegacyKnowledgeVectors);
    const uid = "userPurge";

    // (a) explicit v0 row, (b) pre-versioned ancient on the retired tag (no
    // dedupHashVersion field), (c) a live v1 row that MUST survive.
    seedVector(uid, "v0doc", {
      dedupHashVersion: 0,
      embeddingModelVersion: NEW_MODEL_TAG, // even if re-tagged, v0 is deleted by version
      dedupHash: KNOWN_PLAINTEXT_SHA256,
    });
    stored.set(`users/${uid}/cloud_search_knowledge/ancientDoc`, {
      uid,
      vectorId: "ancientDoc",
      // No dedupHashVersion field — reached ONLY by the retired-tag predicate.
      embeddingModelVersion: RETIRED_MODEL_TAG,
      dedupHash: "cc".repeat(32),
    });
    seedVector(uid, "v1doc", {
      dedupHashVersion: 1,
      embeddingModelVersion: NEW_MODEL_TAG,
      dedupHash: "dd".repeat(32),
    });

    const res = await run({
      auth: { uid, token: {} },
      app: { appId: "test-app" },
      rawRequest: { headers: {} },
      data: {},
    });
    const counts = purgeCounts(res);

    // v0 (by version) + ancient (by retired tag) deleted; v1 survives.
    expect(stored.has(`users/${uid}/cloud_search_knowledge/v0doc`)).toBe(false);
    expect(stored.has(`users/${uid}/cloud_search_knowledge/ancientDoc`)).toBe(false);
    expect(stored.has(`users/${uid}/cloud_search_knowledge/v1doc`)).toBe(true);
    expect(counts.deletedByVersion).toBe(1);
    expect(counts.deletedByRetiredTag).toBe(1);
    expect(counts.deleted).toBe(2);
  });
});
