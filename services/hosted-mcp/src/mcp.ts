import type { Firestore } from "firebase-admin/firestore";
import { MCP_PROTOCOL_VERSION, MAX_OUTPUT_BYTES } from "./config.js";
import type { AccessTokenClaims } from "./auth.js";
import { callTool, listMcpTools } from "./toolRegistry.js";
import { jsonRpcError, McpError } from "./errors.js";
import { truncateJson } from "./redaction.js";
import { listResources, readConversationBody } from "./resources.js";

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id?: string | number | null;
  method?: string;
  params?: Record<string, unknown>;
}

export async function handleMcpRequest(db: Firestore, claims: AccessTokenClaims, input: unknown) {
  const req = input as JsonRpcRequest;
  if (!req || req.jsonrpc !== "2.0" || typeof req.method !== "string") {
    return jsonRpcError(null, -32600, "Invalid JSON-RPC request.");
  }
  try {
    const result = await dispatch(db, claims, req);
    return { jsonrpc: "2.0", id: req.id ?? null, result: truncateJson(result, MAX_OUTPUT_BYTES) };
  } catch (err) {
    if (err instanceof McpError) return jsonRpcError(req.id, err.code, err.message, err.data);
    throw err;
  }
}

async function dispatch(db: Firestore, claims: AccessTokenClaims, req: JsonRpcRequest): Promise<unknown> {
  switch (req.method) {
    case "initialize":
      return {
        protocolVersion: MCP_PROTOCOL_VERSION,
        capabilities: { tools: {}, resources: {} },
        serverInfo: { name: "OpenBurnBar MCP", version: "0.1.0" },
        instructions: "Search encrypted OpenBurnBar session memory. Use the local shim for device-side decryption."
      };
    case "tools/list":
      return listMcpTools();
    case "tools/call": {
      const name = typeof req.params?.name === "string" ? req.params.name : "";
      const args = req.params?.arguments && typeof req.params.arguments === "object"
        ? req.params.arguments as Record<string, unknown>
        : {};
      return callTool({ db, claims }, name, args);
    }
    case "resources/list":
      return listResources(db, claims.sub);
    case "resources/read": {
      const uri = typeof req.params?.uri === "string" ? req.params.uri : "";
      return readConversationBody(db, claims.sub, { resourceUri: uri });
    }
    default:
      throw new McpError(-32601, `Unsupported MCP method ${req.method}.`);
  }
}
