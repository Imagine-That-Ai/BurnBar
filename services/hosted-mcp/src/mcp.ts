import { MCP_PROTOCOL_VERSION, MAX_OUTPUT_BYTES } from "./config.js";
import type { AccessTokenClaims } from "./auth.js";
import { requireScope } from "./auth.js";
import { requireActiveBurnBarPro, requireActiveRemoteMcpAccess } from "./entitlements.js";
import { enforceRateLimit } from "./rateLimits.js";
import { callTool, listMcpTools } from "./toolRegistry.js";
import { jsonRpcError, McpError } from "./errors.js";
import { truncateJson } from "./redaction.js";
import { listResources, readConversationBody, type StorageBodyDownloader } from "./resources.js";
import type { HostedMcpFirestore } from "./firestoreTypes.js";
import { isFullFirestore } from "./firestoreTypes.js";

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id?: string | number | null;
  method?: string;
  params?: Record<string, unknown>;
}

/**
 * Optional runtime seams the HTTP handler threads down. `download` lets a
 * deterministic local harness seed the sealed session body without a live
 * Cloud Storage bucket; production leaves it undefined so resources.ts uses the
 * real `getStorage()` path.
 */
export interface McpRequestDeps {
  download?: StorageBodyDownloader;
}

export async function handleMcpRequest(
  db: HostedMcpFirestore,
  claims: AccessTokenClaims,
  input: unknown,
  deps: McpRequestDeps = {}
) {
  const req = parseJsonRpcRequest(input);
  if (!req) {
    return jsonRpcError(null, -32600, "Invalid JSON-RPC request.");
  }
  try {
    const result = await dispatch(db, claims, req, deps);
    return { jsonrpc: "2.0", id: req.id ?? null, result: truncateJson(result, MAX_OUTPUT_BYTES) };
  } catch (err) {
    if (err instanceof McpError) return jsonRpcError(req.id, err.code, err.message, err.data);
    throw err;
  }
}

async function dispatch(db: HostedMcpFirestore, claims: AccessTokenClaims, req: JsonRpcRequest, deps: McpRequestDeps): Promise<unknown> {
  switch (req.method) {
    case "initialize":
      await requireMcpSessionAccess(db, claims, "metadata:standard");
      return {
        protocolVersion: MCP_PROTOCOL_VERSION,
        capabilities: { tools: {}, resources: {} },
        serverInfo: { name: "OpenBurnBar MCP", version: "0.1.0" },
        instructions: "Search encrypted OpenBurnBar session memory. Use the local shim for device-side decryption."
      };
    case "tools/list":
      await requireMcpSessionAccess(db, claims, "metadata:standard");
      return listMcpTools();
    case "tools/call": {
      const name = typeof req.params?.name === "string" ? req.params.name : "";
      const args = isRecord(req.params?.arguments)
        ? req.params.arguments
        : {};
      if (!isFullFirestore(db)) {
        throw new McpError(-32603, "Tool execution requires a full Firestore client.");
      }
      await requireMcpSessionAccess(db, claims, "metadata:standard");
      return callTool({ db, claims }, name, args);
    }
    case "resources/list":
      await requireResourceAccess(db, claims, "search:read", "metadata:standard");
      return listResources(db, claims.sub);
    case "resources/read": {
      await requireResourceAccess(db, claims, "conversation:read", "body:standard");
      const uri = typeof req.params?.uri === "string" ? req.params.uri : "";
      return readConversationBody(db, claims.sub, { resourceUri: uri }, deps.download);
    }
    default:
      throw new McpError(-32601, `Unsupported MCP method ${req.method}.`);
  }
}

function parseJsonRpcRequest(input: unknown): JsonRpcRequest | undefined {
  if (!isRecord(input) || input.jsonrpc !== "2.0" || typeof input.method !== "string") {
    return undefined;
  }
  return {
    jsonrpc: "2.0",
    id: typeof input.id === "string" || typeof input.id === "number" || input.id === null ? input.id : undefined,
    method: input.method,
    params: isRecord(input.params) ? input.params : undefined,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function requireResourceAccess(db: HostedMcpFirestore, claims: AccessTokenClaims, scope: string, rateLimitBucket: string) {
  requireScope(claims, scope);
  await requireActiveRemoteMcpAccess(claims.sub, claims.client_id, claims.scopes, db);
  await requireActiveBurnBarPro(claims.sub, db);
  await enforceRateLimit(db, claims.sub, claims.client_id, rateLimitBucket);
}

async function requireMcpSessionAccess(db: HostedMcpFirestore, claims: AccessTokenClaims, rateLimitBucket: string) {
  await requireActiveRemoteMcpAccess(claims.sub, claims.client_id, claims.scopes, db);
  await requireActiveBurnBarPro(claims.sub, db);
  await enforceRateLimit(db, claims.sub, claims.client_id, rateLimitBucket);
}
