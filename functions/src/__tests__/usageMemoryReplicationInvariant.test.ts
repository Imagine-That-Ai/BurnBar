import { describe, expect, it } from "vitest";
import { __testing__ } from "../callables/knowledgeMemory.js";

const { SOURCE_KINDS, requireSourceKind, requireChatMemoryProvenance } = __testing__;

/**
 * U8 of the usage-memory program — the server-side half of the v1 replication
 * invariant: **usage memories are LOCAL-ONLY**. The cloaked-vector lane
 * (`users/{uid}/cloud_search_knowledge`, written only by `commitKnowledgeBatch`)
 * must structurally reject the usage source kinds (`safari_ask`,
 * `agent_session`) so no client — buggy or hostile — can replicate a usage
 * memory as a knowledge vector.
 *
 * Why: per-vector cloud forget receipts do not exist yet. Receipts exist only
 * for the vectorless `memory_facts` lane; `cloud_search_knowledge` supports
 * only source-level deletes (`deleteKnowledgeSource`). Until that gap closes,
 * a replicated usage vector would be a cloud row the member cannot provably
 * forget, so replication stays BLOCKED at the allowlist.
 *
 * The device-side half (the sealed-facts lane's candidate query is chat-only)
 * is pinned by `AgentLensTests/Active/UsageMemoryCloudSyncInvariantTests.swift`.
 * See docs/USAGE_MEMORY_DESIGN.md § The v1 replication invariant.
 */
describe("usage-memory v1 replication invariant (cloud_search_knowledge lane)", () => {
  it("SOURCE_KINDS is exactly {repo_docs, notes, chat_memory, code} — no usage kinds", () => {
    // Exact-set equality: adding safari_ask/agent_session (or any new kind)
    // to the vector lane must consciously break this test and confront the
    // forget-receipt gap documented in docs/USAGE_MEMORY_DESIGN.md.
    expect([...SOURCE_KINDS].sort()).toEqual(["chat_memory", "code", "notes", "repo_docs"]);
  });

  it("the vector-commit validator rejects every usage source kind", () => {
    // requireSourceKind is the single validation choke point for
    // commitKnowledgeBatch vectors, configureKnowledgeSource, and
    // chat-memory provenance — one rejection covers every write path.
    for (const usageKind of ["safari_ask", "agent_session"]) {
      expect(() => requireSourceKind(usageKind, "vectors[0].sourceKind")).toThrow(
        /must be one of: repo_docs, notes, chat_memory, code/,
      );
    }
    // The umbrella spelling must not sneak in either.
    expect(() => requireSourceKind("usage", "vectors[0].sourceKind")).toThrow(/must be one of/);
  });

  it("chat-memory provenance cannot smuggle a usage kind", () => {
    const provenance = {
      schemaVersion: 1,
      sourceKind: "safari_ask",
      reviewStatus: "approved",
      sourceSlugHmac: "aa".repeat(32),
      sourceTranscriptHash: "bb".repeat(32),
      extractorKind: "claude-cli",
      extractorPromptHash: "cc".repeat(32),
      extractorOutputHash: "dd".repeat(32),
      extractorPromptVersion: "pensieve-chat-memory-v1",
      createdAt: "2026-08-15T00:00:00.000Z",
      approvedAt: "2026-08-15T00:01:00.000Z",
    };
    expect(() => requireChatMemoryProvenance(provenance, "provenance", "approved")).toThrow(
      /must be one of: repo_docs, notes, chat_memory, code/,
    );
  });
});
