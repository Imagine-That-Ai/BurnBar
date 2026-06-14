/**
 * Unit tests for pure encrypted search-index helpers. The callable can stay thin:
 * validation happens at the callable boundary, while this proves the write planner
 * emits the low-cost posting edges used by mobile and hosted search.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  CLOUD_SEARCH_TOKEN_POSTING_BUCKET,
  buildCloudSearchPostingEdges,
  cloudSearchFallbackHashes,
  deterministicPaddingHashes,
  paddedPostingCount,
} from "../lib/callables/encryptedSearchIndex.js";

const realTokenEdges = (edges) => edges.filter((edge) => edge.data.kind === "token" && edge.data.isPadding !== true);
const paddingTokenEdges = (edges) => edges.filter((edge) => edge.data.kind === "token" && edge.data.isPadding === true);

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

test("cloud search posting planner emits exact REAL token and semantic edges", () => {
  const edges = buildCloudSearchPostingEdges({
    source: source(),
    tokenHashes: [HASH_A, HASH_B, HASH_A],
    semanticHashes: [HASH_C],
  });

  // The REAL (non-padding) token edges are exactly the deduped requested hashes,
  // in order; padding is additive and never reorders or replaces real edges.
  assert.deepEqual(realTokenEdges(edges).map((edge) => edge.edgeID), [
    `token_${HASH_A}_doc-1_0`,
    `token_${HASH_B}_doc-1_0`,
  ]);
  assert.deepEqual(edges.filter((e) => e.data.kind === "semantic").map((e) => e.edgeID), [
    `semantic_${HASH_C}_doc-1_0`,
  ]);
  const first = realTokenEdges(edges)[0];
  assert.equal(first.data.postingKey, `token_${HASH_A}`);
  assert.equal(first.data.hash, HASH_A);
  assert.equal(first.data.chunkID, "doc-1_0");
  assert.equal(first.data.documentID, "doc-1");
  assert.equal(first.data.storagePath, "users/user-1/session_logs/doc-1/body.enc");
  assert.deepEqual(first.data.sealedSnippet, sealedSnippet);
  // Real postings keep the cleartext provider facet…
  assert.equal(first.data.provider, "Codex");
});

// T-PRV-05: the on-disk token-posting count is bucketed by padding so it leaks
// only a coarse bucket, not the exact distinct-term count of a chunk.
test("T-PRV-05: token postings are padded up to the next bucket with deterministic dummies", () => {
  const edges = buildCloudSearchPostingEdges({
    source: source(),
    tokenHashes: [HASH_A, HASH_B, HASH_A], // 2 distinct
    semanticHashes: [HASH_C],
  });
  const real = realTokenEdges(edges);
  const padding = paddingTokenEdges(edges);
  assert.equal(real.length, 2);
  // Total token postings round up to the bucket boundary.
  assert.equal(real.length + padding.length, paddedPostingCount(2));
  assert.equal(real.length + padding.length, CLOUD_SEARCH_TOKEN_POSTING_BUCKET);
  // Padding postings carry NO cleartext provider facet (cannot be facet-correlated).
  for (const pad of padding) {
    assert.equal(pad.data.isPadding, true);
    assert.equal(pad.data.provider, undefined);
    assert.match(String(pad.data.hash), /^pad_/);
  }
});

// T-PRV-05: padding is deterministic — re-indexing the SAME chunk yields the same
// padding edges (no Firestore write churn), and different chunks pad differently.
test("T-PRV-05: padding hashes are deterministic per chunk and distinct across chunks", () => {
  const a1 = deterministicPaddingHashes("chunk-A", 5);
  const a2 = deterministicPaddingHashes("chunk-A", 5);
  const b = deterministicPaddingHashes("chunk-B", 5);
  assert.deepEqual(a1, a2);
  assert.notDeepEqual(a1, b);
  assert.equal(new Set(a1).size, 5);
});

test("cloud search posting planner handles legacy chunks without semantic hashes", () => {
  const edges = buildCloudSearchPostingEdges({
    source: source(),
    tokenHashes: [HASH_A],
    semanticHashes: [],
  });

  assert.equal(realTokenEdges(edges).length, 1);
  assert.equal(realTokenEdges(edges)[0].edgeID, `token_${HASH_A}_doc-1_0`);
  // 1 real token padded up to the bucket; no semantic edges.
  assert.equal(paddingTokenEdges(edges).length, CLOUD_SEARCH_TOKEN_POSTING_BUCKET - 1);
  assert.equal(edges.filter((e) => e.data.kind === "semantic").length, 0);
});

test("cloud search posting planner caps token posting edges", () => {
  const tokenHashes = Array.from({ length: 140 }, (_, index) => index.toString(16).padStart(32, "0"));
  const edges = buildCloudSearchPostingEdges({
    source: source(),
    tokenHashes,
    semanticHashes: [HASH_C],
  });

  // 96 real (capped) — already a multiple of the bucket, so no padding is added.
  assert.equal(realTokenEdges(edges).length, 96);
  assert.equal(paddingTokenEdges(edges).length, 0);
  assert.equal(edges.filter((edge) => edge.data.kind === "semantic").length, 1);
});

test("cloud search fallback keeps hashes not covered by capped postings", () => {
  assert.deepEqual(
    cloudSearchFallbackHashes([HASH_A, HASH_B, HASH_A, HASH_C], new Set([HASH_B])),
    [HASH_A, HASH_C]
  );
  assert.deepEqual(cloudSearchFallbackHashes([HASH_A], new Set([HASH_A])), []);
});
