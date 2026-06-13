import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  redactSecrets,
  parseExtractedMemories,
  prepareMemoriesForCommit,
  approvePreparedMemoryBatch,
  deleteQueuedMemoryBatch,
  runMemorySync,
  installMemoryHook,
  MIN_CONFIDENCE,
  type ExtractedMemory,
} from "./memoryHook.js";
import { createDeterministicHashingEmbedder } from "./embed.js";
import { decryptSealedText } from "./decrypt.js";
import { createHmac, hkdfSync } from "node:crypto";

const KEY = Buffer.alloc(32, 5);

/** The exact vault-keyed HMAC the shim must emit (mirrors the server fixture). */
function expectedVaultKeyedHmac(label: "content" | "slug", value: string): string {
  const dedupKey = Buffer.from(hkdfSync("sha256", KEY, Buffer.alloc(0), `pensieve-dedup:${label}`, 32));
  return createHmac("sha256", dedupKey).update(value, "utf8").digest("hex");
}
process.env.OPENBURNBAR_ALLOW_INSECURE_VAULT_KEY_SOURCE = "true";
process.env.OPENBURNBAR_CLOUD_VAULT_KEY_BASE64 = KEY.toString("base64");

test("redactSecrets strips common secret shapes", () => {
  const dirty = "use sk-ABCDEFGHIJKLMNOPQRSTUVWX and AKIAIOSFODNN7EXAMPLE and password: hunter2 and Bearer abcdefghijklmnopqrstuvwx";
  const { text, redactions } = redactSecrets(dirty);
  assert.ok(!text.includes("sk-ABCDEFGHIJKLMNOPQRSTUVWX"));
  assert.ok(!text.includes("AKIAIOSFODNN7EXAMPLE"));
  assert.ok(!text.includes("hunter2"));
  assert.ok(redactions >= 3);
});

test("parseExtractedMemories handles a raw JSON array", () => {
  const mems = parseExtractedMemories('[{"title":"T","text":"body","category":"fact","confidence":0.9}]');
  assert.equal(mems.length, 1);
  assert.equal(mems[0].text, "body");
});

test("parseExtractedMemories unwraps the `claude -p --output-format json` envelope", () => {
  const inner = '[{"title":"T","text":"decision body","category":"decision","confidence":0.8}]';
  const wrapped = JSON.stringify({ type: "result", result: inner });
  const mems = parseExtractedMemories(wrapped);
  assert.equal(mems.length, 1);
  assert.equal(mems[0].category, "decision");
});

test("parseExtractedMemories strips a markdown code fence", () => {
  const mems = parseExtractedMemories('```json\n[{"title":"T","text":"x","category":"fact","confidence":1}]\n```');
  assert.equal(mems.length, 1);
});

test("parseExtractedMemories returns [] for garbage", () => {
  assert.deepEqual(parseExtractedMemories("not json at all"), []);
  assert.deepEqual(parseExtractedMemories("{}"), []);
});

test("prepareMemoriesForCommit redacts, filters confidence, dedups, embeds+cloaks+seals", async () => {
  const embedder = createDeterministicHashingEmbedder();
  const memories: ExtractedMemory[] = [
    { title: "Rotate key", text: "rotate the vault key monthly", category: "gotcha", confidence: 0.9 },
    { title: "dup", text: "rotate the vault key monthly", category: "gotcha", confidence: 0.95 }, // duplicate text
    { title: "low", text: "ephemeral chatter", category: "fact", confidence: 0.2 }, // below threshold
    { title: "secret", text: "api_key: sk-SHOULDNOTLEAK0000000000", category: "fact", confidence: 0.9 },
  ];
  const prepared = await prepareMemoriesForCommit(memories, "chat-memory", { embedder, vaultKey: KEY });

  // dup collapsed, low-confidence dropped -> 2 remain (the rotate memory + the redacted secret memory)
  assert.equal(prepared.length, 2);
  const rotate = prepared[0];
  assert.equal(rotate.cloakedVector.length, 384);
  assert.equal(rotate.sourceKind, "chat_memory");
  assert.equal(rotate.reviewStatus, "quarantined");
  assert.equal(rotate.provenance.schemaVersion, 1);
  assert.equal(rotate.provenance.sourceKind, "chat_memory");
  assert.equal(rotate.provenance.sourceSlugHmac, rotate.slugHmac);
  assert.match(rotate.provenance.sourceTranscriptHash, /^[a-f0-9]{64}$/);
  assert.match(rotate.provenance.extractorPromptHash, /^[a-f0-9]{64}$/);
  assert.match(rotate.provenance.extractorOutputHash, /^[a-f0-9]{64}$/);
  assert.equal(decryptSealedText(rotate.sealedCiphertext), "rotate the vault key monthly");
  const meta = JSON.parse(decryptSealedText(rotate.sealedMetadata) ?? "{}");
  assert.equal(meta.sourceKind, "chat_memory");
  assert.equal(meta.category, "gotcha");
  assert.equal(meta.reviewStatus, "quarantined");
  assert.equal(meta.provenance.sourceSlugHmac, rotate.slugHmac);

  // §3: every vector carries the VAULT-KEYED dedupHash + slugHmac (not a cleartext
  // SHA-256/path). dedupHash == HKDF/HMAC of the cleaned plaintext, and is reused
  // as the vectorId; slugHmac == HKDF/HMAC of the sourceSlug.
  assert.equal(rotate.dedupHash, expectedVaultKeyedHmac("content", "rotate the vault key monthly"));
  assert.equal(rotate.vectorId, rotate.dedupHash);
  assert.equal(rotate.slugHmac, expectedVaultKeyedHmac("slug", "chat-memory"));
  // The cleartext side channels are GONE.
  assert.ok(!Object.prototype.hasOwnProperty.call(rotate, "contentHash"));
  assert.ok(!Object.prototype.hasOwnProperty.call(rotate, "sourcePath"));

  // The secret memory's ciphertext must not contain the raw key.
  const secretPlain = decryptSealedText(prepared[1].sealedCiphertext) ?? "";
  assert.ok(!secretPlain.includes("sk-SHOULDNOTLEAK0000000000"));
});

test("approvePreparedMemoryBatch explicitly promotes quarantined memories", async () => {
  const embedder = createDeterministicHashingEmbedder();
  const prepared = await prepareMemoriesForCommit(
    [{ title: "T", text: "durable memory", category: "fact", confidence: 0.9 }],
    "chat-memory",
    { embedder, vaultKey: KEY },
  );
  const batch = { sourceSlug: "chat-memory", embeddingModelVersion: embedder.modelVersion, vectors: prepared };

  const approved = approvePreparedMemoryBatch(batch, "2026-06-13T00:00:00.000Z");

  assert.equal(approved.vectors[0].reviewStatus, "approved");
  assert.equal(approved.vectors[0].provenance.reviewStatus, "approved");
  assert.equal(approved.vectors[0].provenance.approvedAt, "2026-06-13T00:00:00.000Z");
});

test("prepareMemoriesForCommit honours the isDuplicate predicate (namespace dedup)", async () => {
  const embedder = createDeterministicHashingEmbedder();
  const memories: ExtractedMemory[] = [{ title: "T", text: "already stored memory", category: "fact", confidence: 0.9 }];
  const prepared = await prepareMemoriesForCommit(memories, "chat-memory", { embedder, vaultKey: KEY }, async () => true);
  assert.equal(prepared.length, 0, "a memory already in the namespace is skipped");
});

test("runMemorySync wires extractor -> prepare -> commit with injected IO", async () => {
  const captured: unknown[] = [];
  const batch = await runMemorySync({
    transcript: "session transcript text",
    sourceSlug: "chat-memory",
    runExtractor: () => '[{"title":"Decision","text":"we chose Firestore vectors","category":"decision","confidence":0.9}]',
    loadEmbedder: async () => createDeterministicHashingEmbedder(),
    vaultKey: () => KEY,
    commit: (b) => captured.push(b),
  });
  assert.equal(batch.vectors.length, 1);
  assert.equal(batch.embeddingModelVersion, "hashing-bow-v1");
  assert.equal(captured.length, 1, "commit sink received the batch");
  assert.equal(decryptSealedText(batch.vectors[0].sealedCiphertext), "we chose Firestore vectors");
  assert.equal(batch.vectors[0].reviewStatus, "quarantined");
  assert.equal(batch.vectors[0].provenance.extractorKind, "claude-cli");
  assert.match(batch.vectors[0].provenance.sourceTranscriptHash, /^[a-f0-9]{64}$/);
});

test("runMemorySync throws without a vault key and never commits", async () => {
  let committed = false;
  await assert.rejects(
    () =>
      runMemorySync({
        transcript: "x",
        runExtractor: () => "[]",
        loadEmbedder: async () => createDeterministicHashingEmbedder(),
        vaultKey: () => undefined,
        commit: () => {
          committed = true;
        },
      }),
    /vault key unavailable/,
  );
  assert.equal(committed, false);
});

test("MIN_CONFIDENCE gate value", () => {
  assert.equal(MIN_CONFIDENCE, 0.6);
});

test("installMemoryHook merges a SessionEnd hook idempotently", () => {
  const path = join(tmpdir(), `obb-hook-test-${KEY.toString("hex").slice(0, 8)}.json`);
  try {
    installMemoryHook({ settingsPath: path });
    installMemoryHook({ settingsPath: path }); // second call must not duplicate
    const settings = JSON.parse(readFileSync(path, "utf8"));
    const sessionEnd = settings.hooks.SessionEnd;
    assert.equal(sessionEnd.length, 1, "hook installed exactly once");
    assert.equal(sessionEnd[0].hooks[0].command, "openburnbar memory run");
  } finally {
    rmSync(path, { force: true });
  }
});

test("deleteQueuedMemoryBatch removes a queued local quarantine file", () => {
  const path = join(tmpdir(), `obb-memory-delete-${KEY.toString("hex").slice(0, 8)}.json`);
  writeFileSync(path, JSON.stringify({ ok: true }));
  assert.equal(deleteQueuedMemoryBatch(path), true);
  assert.equal(deleteQueuedMemoryBatch(path), false);
});
