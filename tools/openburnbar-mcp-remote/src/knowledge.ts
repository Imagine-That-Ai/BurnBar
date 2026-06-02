/**
 * Pensieve device path for the stdio shim.
 *
 * The agent cannot produce embeddings or hold the vault key, so it calls
 * burnbar_search_knowledge with a plain `query` string. This module:
 *   1. (request)  embeds + cloaks the query ON DEVICE into the 384-dim
 *      queryVector the hosted tool expects, and pins embeddingModelVersion so
 *      index-time and query-time vectors are comparable. Query text never leaves
 *      the device.
 *   2. (tools/list) rewrites the advertised burnbar_search_knowledge schema so
 *      the agent sees a `query` string instead of a raw vector.
 *   3. (response) decrypts each sealed hit (ciphertext -> text, sealedMetadata
 *      -> metadata) with the vault key, and applies the sealed-only filters
 *      (sourcePath / section / category) that the server cannot read.
 *
 * Fail-open: if the embedder or vault key is unavailable the request is rejected
 * with a clear JSON-RPC error rather than silently returning nothing.
 */

import { cloakVector, loadDefaultEmbedder, loadVaultKeyBytes, type Embedder } from "./embed.js";
import { decryptSealedText } from "./decrypt.js";

export const KNOWLEDGE_SEARCH_TOOL = "burnbar_search_knowledge";
export const KNOWLEDGE_GET_TOOL = "burnbar_get_knowledge_document";

export class KnowledgeShimError extends Error {}

export interface KnowledgeShimDeps {
  loadEmbedder: () => Promise<Embedder>;
  vaultKey: () => Buffer | undefined;
  cloak: typeof cloakVector;
  decryptSealed: (envelope: unknown) => string | undefined;
}

const defaultDeps: KnowledgeShimDeps = {
  loadEmbedder: loadDefaultEmbedder,
  vaultKey: loadVaultKeyBytes,
  cloak: cloakVector,
  decryptSealed: decryptSealedText,
};

// Cache the loaded embedder across calls in a long-lived shim process.
let cachedEmbedder: Embedder | undefined;
async function getEmbedder(deps: KnowledgeShimDeps): Promise<Embedder> {
  if (!cachedEmbedder) cachedEmbedder = await deps.loadEmbedder();
  return cachedEmbedder;
}
/** test-only: reset the embedder cache */
export function __resetEmbedderCache(): void {
  cachedEmbedder = undefined;
}

interface KnowledgePostFilter {
  sourcePath?: string;
  section?: string;
  category?: string;
}

function isToolCall(message: unknown, toolName: string): message is { params: { name: string; arguments?: Record<string, unknown> } } {
  const m = message as { method?: unknown; params?: { name?: unknown } } | null;
  return Boolean(m && m.method === "tools/call" && m.params && m.params.name === toolName);
}

/**
 * Transform an outgoing knowledge-search request: embed + cloak `query` into
 * `queryVector`. Returns the (possibly unchanged) message plus the sealed-only
 * filters to apply to the decrypted response.
 */
export async function prepareKnowledgeRequest(
  message: unknown,
  deps: KnowledgeShimDeps = defaultDeps,
): Promise<{ message: unknown; postFilter?: KnowledgePostFilter }> {
  if (!isToolCall(message, KNOWLEDGE_SEARCH_TOOL)) return { message };
  const params = message.params;
  const args = { ...(params.arguments ?? {}) };

  // An advanced caller may already supply a vector; leave it untouched.
  if (Array.isArray(args.queryVector)) return { message };

  const query = typeof args.query === "string" ? args.query.trim() : "";
  if (!query) return { message };

  const key = deps.vaultKey();
  if (!key) {
    throw new KnowledgeShimError(
      "Pensieve vault key unavailable — run `openburnbar mcp login` to link your device vault key.",
    );
  }
  const embedder = await getEmbedder(deps);
  const [vector] = await embedder.embed([query], { isQuery: true });
  const cloaked = Array.from(deps.cloak(vector, { vaultKey: key, modelVersion: embedder.modelVersion }));

  const postFilter: KnowledgePostFilter = {
    sourcePath: typeof args.sourcePath === "string" ? args.sourcePath : undefined,
    section: typeof args.section === "string" ? args.section : undefined,
    category: typeof args.category === "string" ? args.category : undefined,
  };

  delete args.query;
  args.queryVector = cloaked;
  args.embeddingModelVersion = embedder.modelVersion;

  return {
    message: { ...(message as object), params: { ...params, arguments: args } },
    postFilter,
  };
}

/**
 * Rewrite a tools/list response so the agent sees a `query` string field for
 * burnbar_search_knowledge instead of the raw 384-dim vector it cannot produce.
 */
export function rewriteToolsListForKnowledge(json: unknown): void {
  const tools = (json as { result?: { tools?: Array<Record<string, unknown>> } })?.result?.tools;
  if (!Array.isArray(tools)) return;
  for (const tool of tools) {
    if (tool.name !== KNOWLEDGE_SEARCH_TOOL) continue;
    const schema = tool.inputSchema as { properties?: Record<string, unknown>; required?: string[] } | undefined;
    if (!schema || typeof schema !== "object") continue;
    const properties = { ...(schema.properties ?? {}) };
    delete properties.queryVector;
    delete properties.embeddingModelVersion;
    properties.query = { type: "string", maxLength: 4096, description: "Natural-language query; embedded + cloaked on device." };
    tool.inputSchema = {
      ...schema,
      properties,
      required: ["query"],
    };
    tool.description =
      "Search your private Pensieve knowledge memory by natural-language query. Embedding + decryption happen on your device.";
  }
}

function matchesPostFilter(metadata: Record<string, unknown> | undefined, filter?: KnowledgePostFilter): boolean {
  if (!filter || !metadata) return true;
  if (filter.sourcePath && metadata.source_path !== filter.sourcePath) return false;
  if (filter.section && metadata.section !== filter.section) return false;
  if (filter.category && metadata.category !== filter.category) return false;
  return true;
}

function decodeMetadata(deps: KnowledgeShimDeps, sealed: unknown): Record<string, unknown> | undefined {
  const plain = deps.decryptSealed(sealed);
  if (!plain) return undefined;
  try {
    return JSON.parse(plain) as Record<string, unknown>;
  } catch {
    return undefined;
  }
}

/**
 * Decrypt a knowledge tool result's sealed payloads in place and apply the
 * sealed-only filters. Returns the rewritten JSON string. A no-op (returns the
 * input string) for any payload that is not a knowledge result.
 */
export function decryptKnowledgeContent(text: string, postFilter?: KnowledgePostFilter, deps: KnowledgeShimDeps = defaultDeps): string {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return text;
  }
  if (!parsed || typeof parsed !== "object") return text;
  const obj = parsed as Record<string, unknown>;

  // Search results: hits[] each with ciphertext + sealedMetadata.
  if (Array.isArray(obj.hits)) {
    const hits = (obj.hits as Array<Record<string, unknown>>)
      .map((hit) => {
        if (hit.ciphertext === undefined && hit.sealedMetadata === undefined) return hit; // not a knowledge hit
        const metadata = decodeMetadata(deps, hit.sealedMetadata);
        return {
          ...hit,
          text: deps.decryptSealed(hit.ciphertext),
          metadata,
          ciphertext: undefined,
          sealedMetadata: undefined,
        };
      })
      .filter((hit) => matchesPostFilter((hit as { metadata?: Record<string, unknown> }).metadata, postFilter));
    return JSON.stringify({ ...obj, hits });
  }

  // Single document fetch: sealedCiphertext + sealedMetadata.
  if (obj.sealedCiphertext !== undefined || obj.sealedMetadata !== undefined) {
    return JSON.stringify({
      ...obj,
      text: deps.decryptSealed(obj.sealedCiphertext),
      metadata: decodeMetadata(deps, obj.sealedMetadata),
      sealedCiphertext: undefined,
      sealedMetadata: undefined,
    });
  }
  return text;
}
