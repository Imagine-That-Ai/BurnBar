/**
 * B-SEC-2 flag-day behavior for legacy dedup-v0 knowledge rows: search never
 * serves a v0 row, purge deletes v0 + retired-tag rows, and the commit cap
 * aggregate excludes legacy v0 rows so re-ingest is unblocked.
 *
 * Split from knowledgeMemoryDedupHash.test.ts (which keeps the vault-keyed
 * dedup / plaintext side-channel suite). The in-memory Firestore double and
 * request builders live in knowledgeMemoryDedupFixture.ts.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  KNOWN_PLAINTEXT_SHA256,
  NEW_MODEL_TAG,
  RETIRED_MODEL_TAG,
  callableRequest,
  callableRun,
  commitRequestForUser,
  hitsFromResult,
  okFromResult,
  purgeCounts,
  rawHitsFromResult,
  searchRequest,
  seedRows,
  seedVector,
  signalEnvelopeForKnowledgeVector,
  stored,
  vectorForMutation,
} from "./knowledgeMemoryDedupFixture.js";

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
// wrappers + aggregate the loop reads. The factories dynamically import the
// shared fixture so the hoisted mocks stay reference-safe.
vi.mock("firebase-admin/firestore", async () => {
  const { FIELD_DELETE } = await import("./knowledgeMemoryDedupFixture.js");
  return {
    Timestamp: { now: () => ({ __ts: true }) },
    FieldValue: {
      vector: (v: number[]) => ({ __vector: v }),
      increment: (n: number) => ({ __increment: n }),
      delete: () => FIELD_DELETE,
    },
    AggregateField: {
      count: () => ({ __count: true }),
      sum: (f: string) => ({ __sum: f }),
    },
  };
});

vi.mock("../adminRuntime.js", async () => {
  const { makeDb } = await import("./knowledgeMemoryDedupFixture.js");
  return { db: makeDb(), auth: {} };
});

process.env.ENFORCE_APP_CHECK = "false";

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

  it("searchKnowledge returns an optional Signal envelope alongside the legacy sealed fields", async () => {
    const { searchKnowledge } = await import("../callables/knowledgeSearch.js");
    const run = callableRun(searchKnowledge);

    seedVector("userSearchSignal", "v1-signal", {
      dedupHashVersion: 1,
      embeddingModelVersion: NEW_MODEL_TAG,
      dedupHash: "bb".repeat(32),
    });
    const seeded = stored.get("users/userSearchSignal/cloud_search_knowledge/v1-signal");
    if (!seeded) throw new Error("Expected seeded Signal row");
    seeded.signalEnvelope = signalEnvelopeForKnowledgeVector("userSearchSignal", "v1-signal");

    const hits = rawHitsFromResult(await run(searchRequest("userSearchSignal", NEW_MODEL_TAG)));
    const hit = hits.find((h) => h.vectorId === "v1-signal");
    expect(hit).toBeTruthy();
    expect(hit?.ciphertext).toBeTruthy();
    expect(hit?.sealedMetadata).toBeTruthy();
    expect(hit?.signalEnvelope).toMatchObject({
      signalEnvelopeFormatVersion: 1,
      mode: "at-rest",
      binding: {
        uid: "userSearchSignal",
        collection: "cloud_search_knowledge",
        docId: "v1-signal",
        field: "sealedCiphertext",
      },
    });
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

    const res = await run(callableRequest(uid, {}));
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

describe("commitKnowledgeBatch — cap aggregate excludes legacy v0 rows (re-ingest unblocked)", () => {
  beforeEach(() => stored.clear());
  afterEach(() => vi.clearAllMocks());

  it("a near-cap user whose usage is ALL orphaned v0 rows can still re-ingest a v1 chunk", async () => {
    const { commitKnowledgeBatch, PENSIEVE_LIMITS } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(commitKnowledgeBatch);
    const uid = "userReingest";

    seedRows(uid, PENSIEVE_LIMITS.pro.chunks, 0, "v0-");

    const res = okFromResult(await run(commitRequestForUser(uid, Buffer.alloc(32, 0xe5))));
    expect(res.ok).toBe(true);
    expect(res.written).toBe(1);
    expect(res.chunkCount).toBe(1);
    expect([...stored.keys()].some((k) => k.startsWith(`users/${uid}/cloud_search_knowledge/v0-0`))).toBe(true);
  });

  it("real v1 usage at the cap STILL blocks a new chunk (no undercount of live data)", async () => {
    const { commitKnowledgeBatch, PENSIEVE_LIMITS } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(commitKnowledgeBatch);
    const uid = "userAtCapV1";

    seedRows(uid, PENSIEVE_LIMITS.pro.chunks, 1, "v1-");

    await expect(run(commitRequestForUser(uid, Buffer.alloc(32, 0xf6)))).rejects.toThrow(/chunk limit/i);
    expect([...stored.keys()].filter((k) => k.startsWith(`users/${uid}/cloud_search_knowledge/`)).length).toBe(
      PENSIEVE_LIMITS.pro.chunks,
    );
  });

  it("same-doc legacy rewrites are charged against live chunk and byte caps", async () => {
    const { commitKnowledgeBatch, PENSIEVE_LIMITS } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(commitKnowledgeBatch);
    const request = (uid: string, fill: number, byteCount?: number) => {
      const req = commitRequestForUser(uid, Buffer.alloc(32, fill));
      if (byteCount !== undefined) vectorForMutation(req).byteCount = byteCount;
      return req;
    };
    const seedLegacy = (uid: string, req: ReturnType<typeof commitRequestForUser>, byteCount = 16) =>
      seedVector(uid, String(vectorForMutation(req).dedupHash), {
        dedupHashVersion: 0,
        embeddingModelVersion: RETIRED_MODEL_TAG,
        dedupHash: "legacy-cleartext-digest",
        byteCount,
      });

    const chunkUid = "userLegacyRewriteChunkCap";
    const chunkReq = request(chunkUid, 0xb8);
    seedRows(chunkUid, PENSIEVE_LIMITS.pro.chunks, 1, "v1-");
    seedLegacy(chunkUid, chunkReq);
    await expect(run(chunkReq)).rejects.toThrow(/chunk limit/i);

    stored.clear();
    const byteUid = "userLegacyRewriteByteCap";
    const byteReq = request(byteUid, 0xc9, 64);
    seedVector(byteUid, "live-near-byte-cap", {
      dedupHashVersion: 1,
      embeddingModelVersion: NEW_MODEL_TAG,
      dedupHash: "live-near-byte-cap",
      byteCount: PENSIEVE_LIMITS.pro.bytes - 8,
    });
    seedLegacy(byteUid, byteReq, 1024);
    await expect(run(byteReq)).rejects.toThrow(/storage limit/i);
  });
});
