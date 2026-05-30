/**
 * Unit tests for pure encrypted search-index helpers. The callable can stay thin:
 * validation happens at the callable boundary, while this proves the write planner
 * emits the low-cost posting edges used by mobile and hosted search.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  buildCloudSearchPostingEdges,
  cloudSearchFallbackHashes,
} from "../lib/callables/encryptedSearchIndex.js";

const HASH_A = "a".repeat(32);
const HASH_B = "b".repeat(32);
const HASH_C = "c".repeat(32);
const sealedSnippet = {
  algorithm: "AES-256-GCM",
  keyVersion: 1,
  nonce: "bm9uY2U=",
  ciphertext: "Y2lwaGVydGV4dA==",
  tag: "dGFn",
};

function source() {
  return {
    uid: "user-1",
    chunkID: "doc-1_0",
    documentID: "doc-1",
    sourceKind: "conversation",
    sourceID: "session-1",
    provider: "Codex",
    projectName: "BurnBar",
    ordinal: 0,
    bodyHash: "d".repeat(64),
    storagePath: "users/user-1/session_logs/doc-1/body.enc",
    sealedSnippet,
    indexVersion: 2,
    commitID: "e".repeat(32),
    updatedAt: "now",
  };
}

test("cloud search posting planner emits exact token and semantic edges", () => {
  const edges = buildCloudSearchPostingEdges({
    source: source(),
    tokenHashes: [HASH_A, HASH_B, HASH_A],
    semanticHashes: [HASH_C],
  });

  assert.deepEqual(edges.map((edge) => edge.edgeID), [
    `token_${HASH_A}_doc-1_0`,
    `token_${HASH_B}_doc-1_0`,
    `semantic_${HASH_C}_doc-1_0`,
  ]);
  assert.deepEqual(edges.map((edge) => edge.data.kind), ["token", "token", "semantic"]);
  assert.equal(edges[0].data.postingKey, `token_${HASH_A}`);
  assert.equal(edges[0].data.hash, HASH_A);
  assert.equal(edges[0].data.chunkID, "doc-1_0");
  assert.equal(edges[0].data.documentID, "doc-1");
  assert.equal(edges[0].data.storagePath, "users/user-1/session_logs/doc-1/body.enc");
  assert.deepEqual(edges[0].data.sealedSnippet, sealedSnippet);
});

test("cloud search posting planner handles legacy chunks without semantic hashes", () => {
  const edges = buildCloudSearchPostingEdges({
    source: source(),
    tokenHashes: [HASH_A],
    semanticHashes: [],
  });

  assert.equal(edges.length, 1);
  assert.equal(edges[0].edgeID, `token_${HASH_A}_doc-1_0`);
  assert.equal(edges[0].data.kind, "token");
});

test("cloud search posting planner caps token posting edges", () => {
  const tokenHashes = Array.from({ length: 140 }, (_, index) => index.toString(16).padStart(32, "0"));
  const edges = buildCloudSearchPostingEdges({
    source: source(),
    tokenHashes,
    semanticHashes: [HASH_C],
  });

  const tokenEdges = edges.filter((edge) => edge.data.kind === "token");
  const semanticEdges = edges.filter((edge) => edge.data.kind === "semantic");
  assert.equal(tokenEdges.length, 96);
  assert.equal(semanticEdges.length, 1);
});

test("cloud search fallback keeps hashes not covered by capped postings", () => {
  assert.deepEqual(
    cloudSearchFallbackHashes([HASH_A, HASH_B, HASH_A, HASH_C], new Set([HASH_B])),
    [HASH_A, HASH_C]
  );
  assert.deepEqual(cloudSearchFallbackHashes([HASH_A], new Set([HASH_A])), []);
});
