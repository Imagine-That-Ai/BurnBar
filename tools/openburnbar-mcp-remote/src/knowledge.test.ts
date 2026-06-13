import assert from "node:assert/strict";
import test from "node:test";

import {
  prepareKnowledgeRequest,
  decryptKnowledgeContent,
  rewriteToolsListForKnowledge,
  KnowledgeShimError,
  __resetEmbedderCache,
  type KnowledgeShimDeps,
} from "./knowledge.js";
import { cloakVector, createDeterministicHashingEmbedder } from "./embed.js";

const VAULT = Buffer.alloc(32, 7);

interface ToolListEntry {
  name: string;
  inputSchema: {
    properties: Record<string, unknown>;
    required?: string[];
  };
}

function depsWith(over: Partial<KnowledgeShimDeps> = {}): KnowledgeShimDeps {
  return {
    loadEmbedder: async () => createDeterministicHashingEmbedder(),
    vaultKey: () => VAULT,
    cloak: cloakVector,
    decryptSealed: (env) => (typeof env === "string" ? env.replace(/^sealed:/u, "") : undefined),
    ...over,
  };
}

function toolCall(name: string, args: Record<string, unknown>) {
  return { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } };
}

test("prepareKnowledgeRequest embeds + cloaks the query into a 384-dim queryVector on device", async () => {
  __resetEmbedderCache();
  const { message, postFilter } = await prepareKnowledgeRequest(
    toolCall("burnbar_search_knowledge", { query: "how to rotate the vault key", section: "security" }),
    depsWith(),
  );
  const args = (message as ReturnType<typeof toolCall>).params.arguments;
  assert.equal(args.query, undefined, "raw query text must be stripped before it leaves the device");
  assert.ok(Array.isArray(args.queryVector) && args.queryVector.length === 384);
  assert.equal(args.embeddingModelVersion, "hashing-bow-v1");
  assert.equal(postFilter?.section, "security");
});

test("prepareKnowledgeRequest throws when the vault key is missing", async () => {
  __resetEmbedderCache();
  await assert.rejects(
    () => prepareKnowledgeRequest(toolCall("burnbar_search_knowledge", { query: "x" }), depsWith({ vaultKey: () => undefined })),
    KnowledgeShimError,
  );
});

test("prepareKnowledgeRequest passes through non-knowledge calls and pre-vectorized calls", async () => {
  __resetEmbedderCache();
  const other = toolCall("burnbar_search_conversations", { query: "hi" });
  assert.equal((await prepareKnowledgeRequest(other, depsWith())).message, other);

  const preVec = toolCall("burnbar_search_knowledge", { queryVector: Array(384).fill(0) });
  assert.equal((await prepareKnowledgeRequest(preVec, depsWith())).message, preVec);
});

test("rewriteToolsListForKnowledge swaps the vector field for a query string", () => {
  const json = {
    result: {
      tools: [
        { name: "burnbar_search_conversations", inputSchema: { properties: { query: {} } } },
        {
          name: "burnbar_search_knowledge",
          inputSchema: { properties: { queryVector: {}, embeddingModelVersion: {}, limit: {} }, required: ["queryVector"] },
        },
      ],
    },
  };
  rewriteToolsListForKnowledge(json);
  const tools = json.result.tools as ToolListEntry[];
  const k = tools.find((tool) => tool.name === "burnbar_search_knowledge");
  assert.ok(k);
  assert.equal(k.inputSchema.properties.queryVector, undefined);
  assert.equal(k.inputSchema.properties.embeddingModelVersion, undefined);
  assert.ok(k.inputSchema.properties.query);
  assert.deepEqual(k.inputSchema.required, ["query"]);
  // unrelated tool untouched
  const c = tools.find((tool) => tool.name === "burnbar_search_conversations");
  assert.ok(c);
  assert.ok(c.inputSchema.properties.query);
});

test("decryptKnowledgeContent decrypts hits and applies the sealed-only filter", () => {
  const deps = depsWith();
  const payload = JSON.stringify({
    hits: [
      { vectorId: "a", ciphertext: "sealed:alpha text", sealedMetadata: `sealed:${JSON.stringify({ source_path: "a.md", section: "security" })}`, score: 0.9 },
      { vectorId: "b", ciphertext: "sealed:beta text", sealedMetadata: `sealed:${JSON.stringify({ source_path: "b.md", section: "other" })}`, score: 0.8 },
    ],
  });
  const out = JSON.parse(decryptKnowledgeContent(payload, { section: "security" }, deps));
  assert.equal(out.hits.length, 1, "only the section=security hit survives the on-device filter");
  assert.equal(out.hits[0].text, "alpha text");
  assert.equal(out.hits[0].metadata.source_path, "a.md");
  assert.equal(out.hits[0].ciphertext, undefined);
  assert.equal(out.hits[0].sealedMetadata, undefined);
});

test("decryptKnowledgeContent decrypts a single document fetch", () => {
  const deps = depsWith();
  const payload = JSON.stringify({
    resourceUri: "burnbar://knowledge/a",
    sealedCiphertext: "sealed:the chunk body",
    sealedMetadata: `sealed:${JSON.stringify({ source_path: "a.md" })}`,
    decryptMode: "local_decrypt_shim",
  });
  const out = JSON.parse(decryptKnowledgeContent(payload, undefined, deps));
  assert.equal(out.text, "the chunk body");
  assert.equal(out.metadata.source_path, "a.md");
  assert.equal(out.sealedCiphertext, undefined);
});

test("decryptKnowledgeContent is a no-op on non-knowledge payloads", () => {
  const deps = depsWith();
  const conv = JSON.stringify({ hits: [{ id: "x", title: "already decrypted" }] });
  assert.equal(decryptKnowledgeContent(conv, undefined, deps), conv);
  assert.equal(decryptKnowledgeContent("not json", undefined, deps), "not json");
});
