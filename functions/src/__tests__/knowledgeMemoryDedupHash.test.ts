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
  });
  return {
    doc: (path: string) => docRef(path),
    collection: (path: string) => collectionRef(path),
    getAll: async (...refs: FakeRef[]) => Promise.all(refs.map((r) => r.get())),
    // Mirrors commitBatchedWrites' use of db.batch() + batch.set(ref, data).
    batch: () => ({
      set: (ref: FakeRef, data: Record<string, unknown>) => applySet(ref.__path, data),
      delete: (ref: FakeRef) => void stored.delete(ref.__path),
      commit: async () => undefined,
    }),
  };
}

vi.mock("../adminRuntime.js", () => ({ db: makeDb(), auth: {} }));

process.env.ENFORCE_APP_CHECK = "false";

type Runnable = { run: (request: unknown) => Promise<unknown> };

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
      sourceSlug: SOURCE_SLUG,
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

describe("commitKnowledgeBatch — B-SEC-2 vault-keyed dedup, no plaintext side channels", () => {
  beforeEach(() => stored.clear());
  afterEach(() => vi.clearAllMocks());

  it("two users + same plaintext -> different stored dedupHash (vault-keyed)", async () => {
    const { commitKnowledgeBatch } = await import("../callables/knowledgeMemory.js");
    const run = (commitKnowledgeBatch as unknown as Runnable).run;

    await run(commitRequestForUser("userA", Buffer.alloc(32, 0xa1)));
    const recA = [...stored.entries()].find(([k]) => k.startsWith("users/userA/cloud_search_knowledge/"))![1];

    await run(commitRequestForUser("userB", Buffer.alloc(32, 0xb2)));
    const recB = [...stored.entries()].find(([k]) => k.startsWith("users/userB/cloud_search_knowledge/"))![1];

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
    const run = (commitKnowledgeBatch as unknown as Runnable).run;

    await run(commitRequestForUser("userA", Buffer.alloc(32, 0xa1)));
    const [, record] = [...stored.entries()].find(([k]) => k.startsWith("users/userA/cloud_search_knowledge/"))!;

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
    const run = (commitKnowledgeBatch as unknown as Runnable).run;

    const req = commitRequestForUser("userLegacy", Buffer.alloc(32, 0xc3));
    // Simulate a not-yet-updated client: drop the keyed fields, send the old
    // cleartext SHA-256 contentHash instead.
    delete (req.data.vectors[0] as Record<string, unknown>).dedupHash;
    (req.data.vectors[0] as Record<string, unknown>).contentHash = KNOWN_PLAINTEXT_SHA256;
    delete (req.data as Record<string, unknown>).slugHmac;

    await expect(run(req)).rejects.toThrow();
    // Nothing was persisted for this legacy caller.
    expect([...stored.keys()].some((k) => k.startsWith("users/userLegacy/cloud_search_knowledge/"))).toBe(false);
  });

  it("a v1 client that omits cloakedVector (sends a raw embedding) is REJECTED", async () => {
    const { commitKnowledgeBatch } = await import("../callables/knowledgeMemory.js");
    const run = (commitKnowledgeBatch as unknown as Runnable).run;

    const req = commitRequestForUser("userRawEmbed", Buffer.alloc(32, 0xd4));
    const vec = req.data.vectors[0] as Record<string, unknown>;
    vec.embedding = vec.cloakedVector; // legacy field name
    delete vec.cloakedVector;

    await expect(run(req)).rejects.toThrow(/cloakedVector/);
    expect([...stored.keys()].some((k) => k.startsWith("users/userRawEmbed/cloud_search_knowledge/"))).toBe(false);
  });
});
