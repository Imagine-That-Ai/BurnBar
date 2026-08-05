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
 *
 * The in-memory Firestore double and request builders live in
 * knowledgeMemoryDedupFixture.ts, shared with knowledgeMemoryDedupFlagDay.test.ts.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  KNOWN_PLAINTEXT_SHA256,
  PLAINTEXT,
  SOURCE_PATH,
  callableRequest,
  callableRun,
  commitRequestForUser,
  firstKnowledgeRecord,
  makeApprovedChatMemory,
  manifestRecord,
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

    const slugHmac = typeof record.slugHmac === "string" ? record.slugHmac : "";
    const manifest = manifestRecord("userA", slugHmac);
    expect(manifest.sourceManifestId).toBe(record.slugHmac);
    expect(manifest.slugHmac).toBe(record.slugHmac);
    expect(manifest).not.toHaveProperty("sourceSlug");
  });

  it("configureKnowledgeSource stores sourceManifestId and returns only a response compatibility alias", async () => {
    const { configureKnowledgeSource } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(configureKnowledgeSource);
    const sourceManifestId = "ab".repeat(32);

    const result = await run(
      callableRequest("userConfig", { sourceKind: "repo_docs", sourceSlug: sourceManifestId }),
    );
    const resultSourceManifestId = Reflect.get(Object(result), "sourceManifestId");
    const resultSourceSlug = Reflect.get(Object(result), "sourceSlug");

    expect(resultSourceManifestId).toBe(sourceManifestId);
    expect(resultSourceSlug).toBe(sourceManifestId);
    const manifest = manifestRecord("userConfig", sourceManifestId);
    expect(manifest.sourceManifestId).toBe(sourceManifestId);
    expect(manifest).not.toHaveProperty("sourceSlug");
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

  it("accepts an optional path-bound Signal envelope on a knowledge vector", async () => {
    const { commitKnowledgeBatch } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(commitKnowledgeBatch);

    const req = commitRequestForUser("userSignal", Buffer.alloc(32, 0xe5));
    const vector = vectorForMutation(req);
    const vectorId = String(vector.dedupHash);
    vector.signalEnvelope = signalEnvelopeForKnowledgeVector("userSignal", vectorId);

    await run(req);
    const record = firstKnowledgeRecord("userSignal");
    expect(record.signalEnvelope).toMatchObject({
      signalEnvelopeFormatVersion: 1,
      mode: "at-rest",
      relayEncryption: "signal-hpke-identity-seal-v1",
      binding: {
        uid: "userSignal",
        collection: "cloud_search_knowledge",
        docId: vectorId,
        field: "sealedCiphertext",
      },
    });
  });

  it("rejects a polluted optional Signal envelope before any knowledge vector write", async () => {
    const { commitKnowledgeBatch } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(commitKnowledgeBatch);

    const req = commitRequestForUser("userSignalPolluted", Buffer.alloc(32, 0xe6));
    const vector = vectorForMutation(req);
    vector.signalEnvelope = signalEnvelopeForKnowledgeVector("userSignalPolluted", String(vector.dedupHash), {
      plaintext: "must never reach an Admin SDK write",
    });

    await expect(run(req)).rejects.toThrow(/invalid-envelope-shape/);
    expect([...stored.keys()].some((k) => k.startsWith("users/userSignalPolluted/cloud_search_knowledge/"))).toBe(false);
  });

  it("rejects unapproved chat_memory vectors before write", async () => {
    const { commitKnowledgeBatch } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(commitKnowledgeBatch);

    const req = commitRequestForUser("userChatQuarantine", Buffer.alloc(32, 0x51));
    const vector = makeApprovedChatMemory(req);
    vector.reviewStatus = "quarantined";
    const provenance = Object(vector.provenance);
    Reflect.set(provenance, "reviewStatus", "quarantined");
    Reflect.deleteProperty(provenance, "approvedAt");

    await expect(run(req)).rejects.toThrow(/must be explicitly approved/);
    expect([...stored.keys()].some((k) => k.startsWith("users/userChatQuarantine/cloud_search_knowledge/"))).toBe(
      false,
    );
  });

  it("stores approved chat_memory provenance without plaintext path side channels", async () => {
    const { commitKnowledgeBatch } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(commitKnowledgeBatch);

    const req = commitRequestForUser("userChatApproved", Buffer.alloc(32, 0x52));
    makeApprovedChatMemory(req);

    await run(req);
    const record = firstKnowledgeRecord("userChatApproved");
    expect(record.sourceKind).toBe("chat_memory");
    expect(record.reviewStatus).toBe("approved");
    expect(record.memoryProvenance).toMatchObject({
      schemaVersion: 1,
      sourceKind: "chat_memory",
      reviewStatus: "approved",
      sourceSlugHmac: req.data.slugHmac,
      extractorKind: "claude-cli",
      extractorPromptVersion: "pensieve-chat-memory-v1",
    });
    expect(JSON.stringify(record.memoryProvenance)).not.toContain(SOURCE_PATH);
    expect(JSON.stringify(record.memoryProvenance)).not.toContain(PLAINTEXT);
  });

  it("rejects a relocated optional Signal envelope before any knowledge vector write", async () => {
    const { commitKnowledgeBatch } = await import("../callables/knowledgeMemory.js");
    const run = callableRun(commitKnowledgeBatch);

    const req = commitRequestForUser("userSignalBad", Buffer.alloc(32, 0xf6));
    const vector = vectorForMutation(req);
    vector.signalEnvelope = signalEnvelopeForKnowledgeVector("userSignalBad", "different-doc");

    await expect(run(req)).rejects.toThrow(/binding-docid-mismatch/);
    expect([...stored.keys()].some((k) => k.startsWith("users/userSignalBad/cloud_search_knowledge/"))).toBe(false);
  });
});
