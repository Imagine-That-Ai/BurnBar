import http, { type IncomingMessage, type ServerResponse } from "node:http";
import { randomUUID } from "node:crypto";
import { allowedOrigins, MAX_REQUEST_BYTES, MCP_PROTOCOL_VERSION } from "./config.js";
import { verifyBearerToken } from "./auth.js";
import { firestore } from "./entitlements.js";
import { HttpError, jsonRpcError } from "./errors.js";
import { handleMcpRequest } from "./mcp.js";
import { authorizationServerMetadata, protectedResourceMetadata } from "./oauthMetadata.js";
import { logError, logInfo, logWarn } from "./logging.js";
import { writeAuditEvent } from "./audit.js";

function sendJson(res: ServerResponse, status: number, value: unknown, headers: Record<string, string> = {}): void {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", ...headers });
  res.end(JSON.stringify(value));
}

async function readBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buf.length;
    if (size > MAX_REQUEST_BYTES) throw new HttpError(413, "MCP request body is too large.", "request_too_large");
    chunks.push(buf);
  }
  if (chunks.length === 0) throw new HttpError(400, "Missing JSON-RPC request body.", "missing_body");
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function validateOrigin(req: IncomingMessage): void {
  const origin = req.headers.origin;
  if (!origin) return;
  if (!allowedOrigins().has(origin)) throw new HttpError(403, "Invalid MCP Origin header.", "invalid_origin");
}

function validateProtocol(req: IncomingMessage): void {
  const version = req.headers["mcp-protocol-version"];
  if (!version) return;
  if (version !== MCP_PROTOCOL_VERSION) throw new HttpError(400, "Unsupported MCP protocol version.", "unsupported_protocol_version");
}

async function route(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? "/", "http://localhost");
  if (url.pathname === "/healthz") {
    sendJson(res, 200, { ok: true });
    return;
  }
  if (url.pathname === "/readyz") {
    sendJson(res, 200, { ok: true, service: "openburnbar-hosted-mcp" });
    return;
  }
  if (url.pathname === "/.well-known/oauth-protected-resource") {
    sendJson(res, 200, protectedResourceMetadata());
    return;
  }
  if (url.pathname === "/.well-known/oauth-authorization-server") {
    sendJson(res, 200, authorizationServerMetadata());
    return;
  }
  if (url.pathname !== "/mcp") {
    sendJson(res, 404, { error: "not_found" });
    return;
  }
  validateOrigin(req);
  validateProtocol(req);
  if (req.method === "GET") {
    res.writeHead(405, { allow: "POST, DELETE" });
    res.end();
    return;
  }
  if (req.method === "DELETE") {
    res.writeHead(202);
    res.end();
    return;
  }
  if (req.method !== "POST") {
    res.writeHead(405, { allow: "POST, DELETE" });
    res.end();
    return;
  }
  const started = Date.now();
  const claims = verifyBearerToken(req.headers.authorization);
  const db = firestore();
  const body = await readBody(req);
  const response = await handleMcpRequest(db, claims, body);
  void writeAuditEvent(db, claims, {
    kind: "mcp_request",
    toolName: typeof (body as { params?: { name?: unknown } }).params?.name === "string" ? String((body as { params: { name: unknown } }).params.name) : undefined,
    latencyMs: Date.now() - started,
    ip: req.socket.remoteAddress,
    userAgent: req.headers["user-agent"]
  }).catch((err) => logWarn("remote_mcp_audit_write_failed", { error: err instanceof Error ? err.message : String(err) }));
  sendJson(res, 200, response, {
    "MCP-Protocol-Version": MCP_PROTOCOL_VERSION,
    "MCP-Session-Id": randomUUID()
  });
}

export function createServer() {
  return http.createServer((req, res) => {
    route(req, res).catch((err) => {
      if (err instanceof HttpError) {
        const headers: Record<string, string> = err.status === 401
          ? { "WWW-Authenticate": 'Bearer resource_metadata="https://mcp.burnbar.ai/.well-known/oauth-protected-resource"' }
          : {};
        sendJson(res, err.status, jsonRpcError(null, -32000, err.message, { code: err.code }), headers);
        return;
      }
      logError("hosted_mcp_unhandled_error", { error: err instanceof Error ? err.message : String(err) });
      sendJson(res, 500, jsonRpcError(null, -32603, "Internal OpenBurnBar MCP error."));
    });
  });
}

if (process.env.NODE_ENV !== "test") {
  const port = Number(process.env.PORT ?? 8080);
  createServer().listen(port, () => logInfo("hosted_mcp_started", { port }));
}
