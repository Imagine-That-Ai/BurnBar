import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";

import { requireOptionalSearchHashes, requireTokenHashes } from "../callables/shared.js";
import {
  MAX_CLOUD_SEARCH_INDEX_CLEANUP_WRITES_PER_COMMIT,
  MAX_CLOUD_SEARCH_INDEX_WRITES_PER_COMMIT,
  MAX_SEMANTIC_POSTING_EDGES_PER_CHUNK,
  MAX_TOKEN_POSTING_EDGES_PER_CHUNK,
  assertCloudSearchIndexCleanupWriteBudget,
  assertCloudSearchIndexWriteBudget,
  buildCloudSearchPostingEdges,
} from "../callables/encryptedSearchIndex.js";

describe("encrypted search hash validation", () => {
  it("rejects plaintext-like token and semantic hash entries", () => {
    expect(() => requireTokenHashes(["private prompt"], "chunk.tokenHashes")).toThrow(/invalid hash/);
    expect(() => requireOptionalSearchHashes(["not-a-valid-hash"], "chunk.semanticHashes")).toThrow(/invalid hash/);
  });

  it("keeps the full encrypted-search hash capacity at the callable boundary", () => {
    const hashes = Array.from({ length: 1_024 }, (_, index) => index.toString(16).padStart(32, "0"));
    expect(requireTokenHashes(hashes, "chunk.tokenHashes")).toHaveLength(1_024);
  });

  it("caps posting fanout while preserving stored hash-array capacity", () => {
    const hashes = Array.from({ length: 1_024 }, (_, index) => index.toString(16).padStart(32, "0"));
    const edges = buildCloudSearchPostingEdges({
      source: {
        uid: "u1",
        chunkID: "doc_0",
        documentID: "doc",
        sourceKind: "conversation",
        sourceID: "session",
        ordinal: 0,
        bodyHash: "b".repeat(64),
        storagePath: "users/u1/session_logs/doc/bodies/body.json.aesgcm",
        sealedSnippet: { ciphertext: "sealed" },
        indexVersion: 2,
        commitID: "c".repeat(32),
        updatedAt: "now",
      },
      tokenHashes: hashes,
      semanticHashes: hashes,
    });

    expect(edges.filter((edge) => edge.data.kind === "token")).toHaveLength(MAX_TOKEN_POSTING_EDGES_PER_CHUNK);
    expect(edges.filter((edge) => edge.data.kind === "semantic")).toHaveLength(MAX_SEMANTIC_POSTING_EDGES_PER_CHUNK);
  });

  it("rejects planned cloud-search commits above the write budget", () => {
    expect(() => assertCloudSearchIndexWriteBudget(MAX_CLOUD_SEARCH_INDEX_WRITES_PER_COMMIT)).not.toThrow();
    expect(() => assertCloudSearchIndexWriteBudget(MAX_CLOUD_SEARCH_INDEX_WRITES_PER_COMMIT + 1)).toThrow(
      /cloud search index commit would write/,
    );
  });

  it("budgets stale index cleanup separately from full replacement writes", () => {
    expect(() =>
      assertCloudSearchIndexCleanupWriteBudget(MAX_CLOUD_SEARCH_INDEX_CLEANUP_WRITES_PER_COMMIT),
    ).not.toThrow();
    expect(() =>
      assertCloudSearchIndexCleanupWriteBudget(MAX_CLOUD_SEARCH_INDEX_CLEANUP_WRITES_PER_COMMIT + 1),
    ).toThrow(/cloud search index cleanup would write/);
  });

  it("keeps the callable wired to same-commit chunk binding and write-budget enforcement", () => {
    const source = readFileSync(path.join(process.cwd(), "src/callables/encryptedSearch.ts"), "utf8");

    expect(source).toContain("chunk.documentID must reference a document in the same commit");
    expect(source).toContain("assertCloudSearchIndexWriteBudget(writeCount + 1)");
    expect(source).toContain("assertCloudSearchIndexCleanupWriteBudget(cleanupWriteCount + 1)");
  });

  it("keeps callable fallback queries isolated per hash", () => {
    const source = readFileSync(path.join(process.cwd(), "src/callables/encryptedSearchQuery.ts"), "utf8");

    expect(source).toContain("SEARCH_FALLBACK_SCAN_BATCH_LIMIT");
    expect(source).toContain("startAfter(cursor)");
    expect(source).toContain('chunksRef.where(fieldName, "array-contains-any", [hash])');
  });
});
