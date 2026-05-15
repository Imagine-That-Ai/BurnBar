import type { Firestore } from "firebase-admin/firestore";
import type { AccessTokenClaims } from "./auth.js";
import { requireScope } from "./auth.js";
import { requireActiveBurnBarPro } from "./entitlements.js";
import { enforceRateLimit } from "./rateLimits.js";
import { listFacets, listIndexStatus, searchConversations } from "./search.js";
import { listResources, readConversationBody, recentUsage } from "./resources.js";

export type CostClass = "metadata" | "standard" | "body";

export interface ToolContext {
  db: Firestore;
  claims: AccessTokenClaims;
}

export interface RegisteredTool {
  name: string;
  description: string;
  requiredScopes: string[];
  costClass: CostClass;
  rateLimitBucket: string;
  inputSchema: Record<string, unknown>;
  handler(ctx: ToolContext, args: Record<string, unknown>): Promise<unknown>;
}

function schema(properties: Record<string, unknown>, required: string[] = []) {
  return { type: "object", properties, required, additionalProperties: false };
}

export const tools: RegisteredTool[] = [
  {
    name: "burnbar_search_conversations",
    description: "Search encrypted OpenBurnBar hosted session memory. Sealed results require the local shim for decrypted previews.",
    requiredScopes: ["search:read"],
    costClass: "standard",
    rateLimitBucket: "search:standard",
    inputSchema: schema({
      query: { type: "string", maxLength: 512 },
      tokenHashes: { type: "array", items: { type: "string" }, maxItems: 10 },
      semanticHashes: { type: "array", items: { type: "string" }, maxItems: 12 },
      provider: { type: "string", maxLength: 80 },
      model: { type: "string", maxLength: 120 },
      projectName: { type: "string", maxLength: 512 },
      harness: { type: "string", maxLength: 80 },
      from: { type: "string" },
      to: { type: "string" },
      limit: { type: "integer", minimum: 1, maximum: 50 },
      cursor: { type: "string" },
      includeBodyPreview: { type: "boolean" }
    }),
    handler: async ({ db, claims }, args) => searchConversations(db, claims.sub, args)
  },
  {
    name: "burnbar_get_conversation_body",
    description: "Fetch one encrypted session body page for a resource returned by search.",
    requiredScopes: ["conversation:read"],
    costClass: "body",
    rateLimitBucket: "body:standard",
    inputSchema: schema({
      resourceUri: { type: "string", pattern: "^burnbar://conversation/" },
      maxChars: { type: "integer", minimum: 1024, maximum: 96000 },
      cursor: { type: "string" }
    }, ["resourceUri"]),
    handler: async ({ db, claims }, args) => readConversationBody(db, claims.sub, args)
  },
  {
    name: "burnbar_list_search_index_status",
    description: "Return encrypted search index freshness, counts, active commits, and stale-state warnings.",
    requiredScopes: ["index:status"],
    costClass: "metadata",
    rateLimitBucket: "metadata:standard",
    inputSchema: schema({}),
    handler: async ({ db, claims }) => listIndexStatus(db, claims.sub)
  },
  {
    name: "burnbar_list_search_facets",
    description: "List bounded provider/model/project/harness facets for narrowing hosted search.",
    requiredScopes: ["search:read"],
    costClass: "metadata",
    rateLimitBucket: "metadata:standard",
    inputSchema: schema({ kind: { type: "string", enum: ["provider", "model", "project", "harness"] } }, ["kind"]),
    handler: async ({ db, claims }, args) => listFacets(db, claims.sub, String(args.kind ?? "provider"))
  },
  {
    name: "burnbar_recent_usage",
    description: "Read recent provider/model usage metadata without provider credentials.",
    requiredScopes: ["usage:read"],
    costClass: "metadata",
    rateLimitBucket: "metadata:standard",
    inputSchema: schema({}),
    handler: async ({ db, claims }) => recentUsage(db, claims.sub)
  },
  {
    name: "burnbar_resolve_capabilities",
    description: "Describe the current user's hosted MCP availability, decrypt mode, scopes, and limits.",
    requiredScopes: ["index:status"],
    costClass: "metadata",
    rateLimitBucket: "metadata:standard",
    inputSchema: schema({}),
    handler: async ({ db, claims }) => ({
      subscription: await requireActiveBurnBarPro(claims.sub, db),
      hostedMcpAvailable: true,
      decryptMode: claims.grant_mode,
      supportedTools: tools.map((tool) => tool.name),
      maxLimits: { searchResults: 50, tokenHashes: 10, semanticHashes: 12, bodyPageChars: 96_000 },
      compatibilityNotes: "Use openburnbar-mcp-remote for stdio-only clients and local decryption."
    })
  }
];

export function listMcpTools() {
  return {
    tools: tools.map((tool) => ({
      name: tool.name,
      description: tool.description,
      inputSchema: tool.inputSchema
    }))
  };
}

export async function callTool(ctx: ToolContext, name: string, args: Record<string, unknown>) {
  const tool = tools.find((candidate) => candidate.name === name);
  if (!tool) {
    return { content: [{ type: "text", text: `Unknown OpenBurnBar MCP tool: ${name}` }], isError: true };
  }
  for (const scope of tool.requiredScopes) requireScope(ctx.claims, scope);
  await requireActiveBurnBarPro(ctx.claims.sub, ctx.db);
  await enforceRateLimit(ctx.db, ctx.claims.sub, ctx.claims.client_id, tool.rateLimitBucket);
  const result = await tool.handler(ctx, args);
  return { content: [{ type: "text", text: JSON.stringify(result) }] };
}
