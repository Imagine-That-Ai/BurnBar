import assert from "node:assert/strict";
import test from "node:test";

import {
  createInMemoryKnowledgeVectorStore,
  cosineSimilarity,
  type KnowledgeVectorRecord,
} from "./knowledgeVector.js";

function rec(over: Partial<KnowledgeVectorRecord> & { vectorId: string; embedding: number[] }): KnowledgeVectorRecord {
  return {
    embeddingModelVersion: "hashing-bow-v1",
    ciphertext: "Y2lwaGVy",
    sealedMetadata: "bWV0YQ==",
    sourceKind: "notes",
    sourceSlug: "default",
    contentHash: "h",
    updatedAt: "2026-06-02T00:00:00.000Z",
    ...over,
  };
}

test("search returns hits ranked by cosine similarity", async () => {
  const store = createInMemoryKnowledgeVectorStore();
  await store.upsert("uidA", [
    rec({ vectorId: "v-far", embedding: [0, 1, 0] }),
    rec({ vectorId: "v-near", embedding: [1, 0, 0] }),
    rec({ vectorId: "v-mid", embedding: [0.7, 0.7, 0] }),
  ]);
  const { hits } = await store.search("uidA", [1, 0, 0], {}, 10);
  assert.deepEqual(hits.map((h) => h.vectorId), ["v-near", "v-mid", "v-far"]);
  assert.ok(hits[0].score > hits[1].score && hits[1].score > hits[2].score);
});

test("search is strictly isolated per namespace (cross-tenant leakage is impossible)", async () => {
  const store = createInMemoryKnowledgeVectorStore();
  await store.upsert("uidA", [rec({ vectorId: "a1", embedding: [1, 0, 0] })]);
  await store.upsert("uidB", [rec({ vectorId: "b1", embedding: [1, 0, 0] })]);

  const a = await store.search("uidA", [1, 0, 0], {}, 10);
  const b = await store.search("uidB", [1, 0, 0], {}, 10);
  assert.deepEqual(a.hits.map((h) => h.vectorId), ["a1"]);
  assert.deepEqual(b.hits.map((h) => h.vectorId), ["b1"]);

  // A query for a namespace with no data returns empty, never another tenant's rows.
  const empty = await store.search("uidC", [1, 0, 0], {}, 10);
  assert.deepEqual(empty.hits, []);
});

test("search honours plaintext filters (sourceKind, sourceSlug, modelVersion)", async () => {
  const store = createInMemoryKnowledgeVectorStore();
  await store.upsert("uidA", [
    rec({ vectorId: "notes1", embedding: [1, 0, 0], sourceKind: "notes", sourceSlug: "journal" }),
    rec({ vectorId: "docs1", embedding: [1, 0, 0], sourceKind: "repo_docs", sourceSlug: "repoX" }),
    rec({ vectorId: "chat1", embedding: [1, 0, 0], sourceKind: "chat_memory", sourceSlug: "sessions", embeddingModelVersion: "other" }),
  ]);
  assert.deepEqual(
    (await store.search("uidA", [1, 0, 0], { sourceKind: "repo_docs" }, 10)).hits.map((h) => h.vectorId),
    ["docs1"],
  );
  assert.deepEqual(
    (await store.search("uidA", [1, 0, 0], { sourceSlug: "journal" }, 10)).hits.map((h) => h.vectorId),
    ["notes1"],
  );
  assert.deepEqual(
    (await store.search("uidA", [1, 0, 0], { embeddingModelVersion: "hashing-bow-v1" }, 10)).hits.map((h) => h.vectorId).sort(),
    ["docs1", "notes1"],
  );
});

test("limit caps the number of hits", async () => {
  const store = createInMemoryKnowledgeVectorStore();
  await store.upsert("uidA", [
    rec({ vectorId: "v1", embedding: [1, 0, 0] }),
    rec({ vectorId: "v2", embedding: [0.9, 0.1, 0] }),
    rec({ vectorId: "v3", embedding: [0.8, 0.2, 0] }),
  ]);
  const { hits } = await store.search("uidA", [1, 0, 0], {}, 2);
  assert.equal(hits.length, 2);
});

test("upsert is idempotent on (namespace, vectorId)", async () => {
  const store = createInMemoryKnowledgeVectorStore();
  await store.upsert("uidA", [rec({ vectorId: "v1", embedding: [1, 0, 0], contentHash: "old" })]);
  await store.upsert("uidA", [rec({ vectorId: "v1", embedding: [0, 1, 0], contentHash: "new" })]);
  assert.equal(await store.count("uidA"), 1);
  const { hits } = await store.search("uidA", [0, 1, 0], {}, 10);
  assert.equal(hits[0].vectorId, "v1");
  assert.ok(hits[0].score > 0.99, "updated embedding should be returned");
});

test("getById returns only within the namespace", async () => {
  const store = createInMemoryKnowledgeVectorStore();
  await store.upsert("uidA", [rec({ vectorId: "v1", embedding: [1, 0, 0] })]);
  assert.equal((await store.getById("uidA", "v1"))?.vectorId, "v1");
  assert.equal(await store.getById("uidB", "v1"), undefined);
});

test("deleteBySlug and purge scope to the namespace", async () => {
  const store = createInMemoryKnowledgeVectorStore();
  await store.upsert("uidA", [
    rec({ vectorId: "v1", embedding: [1, 0, 0], sourceSlug: "repoX" }),
    rec({ vectorId: "v2", embedding: [1, 0, 0], sourceSlug: "repoY" }),
  ]);
  await store.upsert("uidB", [rec({ vectorId: "v3", embedding: [1, 0, 0], sourceSlug: "repoX" })]);

  assert.deepEqual(await store.deleteBySlug("uidA", "repoX"), { deleted: 1 });
  assert.equal(await store.count("uidA"), 1);
  assert.equal(await store.count("uidB"), 1, "deleting uidA's repoX must not touch uidB's repoX");

  await store.purge("uidA");
  assert.equal(await store.count("uidA"), 0);
  assert.equal(await store.count("uidB"), 1);
});

test("cosineSimilarity edge cases", () => {
  assert.equal(cosineSimilarity([0, 0], [1, 1]), 0, "zero vector -> 0, not NaN");
  assert.ok(Math.abs(cosineSimilarity([1, 0], [1, 0]) - 1) < 1e-12);
  assert.ok(Math.abs(cosineSimilarity([1, 0], [-1, 0]) + 1) < 1e-12);
});
