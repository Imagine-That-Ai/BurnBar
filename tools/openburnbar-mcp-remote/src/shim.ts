import { decryptSearchResultJson } from "./decrypt.js";
import { readAccessToken, readRefreshToken, writeAccessToken, writeRefreshToken } from "./oauth.js";
import {
  prepareKnowledgeRequest,
  decryptKnowledgeContent,
  rewriteToolsListForKnowledge,
  KnowledgeShimError,
} from "./knowledge.js";

export const DEFAULT_ENDPOINT = "https://mcp.burnbar.ai/mcp";
const PROTOCOL_VERSION = "2025-11-25";
const TRUSTED_HTTPS_HOSTS = new Set(["mcp.burnbar.ai"]);

function isLoopbackHost(hostname: string): boolean {
  const normalized = hostname.toLowerCase();
  return normalized === "localhost" || normalized === "127.0.0.1" || normalized === "::1" || normalized === "[::1]";
}

export function validatedMcpEndpoint(endpoint: string): URL {
  const url = new URL(endpoint);
  if (url.username || url.password) {
    throw new Error("OpenBurnBar MCP endpoint must not include URL credentials.");
  }
  if (url.protocol === "https:" && TRUSTED_HTTPS_HOSTS.has(url.hostname.toLowerCase())) {return url;}
  if (url.protocol === "https:" && process.env.OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT === "true") {return url;}
  if (url.protocol === "http:" && isLoopbackHost(url.hostname)) {return url;}
  throw new Error("OpenBurnBar MCP endpoint must be https://mcp.burnbar.ai, an explicitly allowed custom HTTPS endpoint, or loopback HTTP for local development.");
}

function isTrustedRefreshEndpoint(target: URL): boolean {
  return target.protocol === "https:" && TRUSTED_HTTPS_HOSTS.has(target.hostname.toLowerCase());
}

/**
 * Exchange the stored (expired) access token + durable refresh token for a fresh
 * 15-minute access token at the resource server's RFC 6749 token endpoint. Rotates
 * the stored refresh token. Returns the new access token, or undefined if refresh
 * is impossible (no refresh token, or the grant was revoked / expired).
 */
async function refreshAccessToken(target: URL, expiredAccessToken: string): Promise<string | undefined> {
  if (!isTrustedRefreshEndpoint(target)) {return undefined;}
  const refreshToken = readRefreshToken();
  if (!refreshToken) {return undefined;}
  const tokenUrl = new URL("/oauth/token", DEFAULT_ENDPOINT);
  let res: Response;
  try {
    res = await fetch(tokenUrl, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({
        grant_type: "refresh_token",
        refresh_token: refreshToken,
        access_token: expiredAccessToken
      })
    });
  } catch {
    return undefined;
  }
  if (!res.ok) {return undefined;}
  let payload: { access_token?: unknown; refresh_token?: unknown };
  try {
    payload = await res.json() as { access_token?: unknown; refresh_token?: unknown };
  } catch {
    return undefined;
  }
  if (typeof payload.access_token !== "string" || payload.access_token.length === 0) {return undefined;}
  writeAccessToken(payload.access_token);
  if (typeof payload.refresh_token === "string" && payload.refresh_token.length > 0) {
    writeRefreshToken(payload.refresh_token);
  }
  return payload.access_token;
}

async function postMcp(target: URL, token: string, body: string): Promise<Response> {
  return fetch(target, {
    method: "POST",
    headers: {
      "accept": "application/json, text/event-stream",
      "content-type": "application/json",
      "authorization": `Bearer ${token}`,
      "MCP-Protocol-Version": PROTOCOL_VERSION
    },
    body
  });
}

export async function forwardMcpMessage(message: unknown, endpoint = process.env.OPENBURNBAR_MCP_ENDPOINT ?? DEFAULT_ENDPOINT): Promise<unknown> {
  const target = validatedMcpEndpoint(endpoint);
  const token = readAccessToken();
  if (!token) {
    return {
      jsonrpc: "2.0",
      id: (message as { id?: unknown })?.id ?? null,
      error: {
        code: -32001,
        message: "OpenBurnBar MCP is not authenticated. Run `openburnbar mcp doctor` or connect from the OpenBurnBar app."
      }
    };
  }
  // Pensieve: embed + cloak a natural-language knowledge query on device before
  // it leaves the machine (query text never hits the network).
  let outgoing = message;
  let knowledgePostFilter;
  try {
    const prepared = await prepareKnowledgeRequest(message);
    outgoing = prepared.message;
    knowledgePostFilter = prepared.postFilter;
  } catch (err) {
    return {
      jsonrpc: "2.0",
      id: (message as { id?: unknown })?.id ?? null,
      error: {
        code: -32002,
        message: err instanceof KnowledgeShimError ? err.message : `Pensieve query preparation failed: ${err instanceof Error ? err.message : String(err)}`
      }
    };
  }
  const requestBody = JSON.stringify(outgoing);
  let activeToken = token;
  let res = await postMcp(target, activeToken, requestBody);
  // Access tokens live 15 minutes; on a 401 transparently re-mint via the refresh
  // token and retry once, so long-running agents never hard-fail on expiry.
  if (res.status === 401) {
    const refreshed = await refreshAccessToken(target, activeToken);
    if (refreshed) {
      activeToken = refreshed;
      res = await postMcp(target, activeToken, requestBody);
    }
  }
  if (res.status === 401) {
    return {
      jsonrpc: "2.0",
      id: (message as { id?: unknown })?.id ?? null,
      error: {
        code: -32001,
        message: "OpenBurnBar MCP session expired and could not be refreshed. Re-link with `openburnbar mcp login`."
      }
    };
  }
  const json = await res.json() as Record<string, unknown>;
  // Present Pensieve search as a natural-language `query` tool to the agent.
  rewriteToolsListForKnowledge(json);
  const result = json.result as { content?: Array<{ type: string; text: string }> } | undefined;
  if (result?.content) {
    result.content = result.content.map((item) => item.type === "text"
      // decryptSearchResultJson handles conversation hits; decryptKnowledgeContent
      // handles Pensieve hits/docs. Each is a no-op on the other's payload.
      ? { ...item, text: decryptKnowledgeContent(decryptSearchResultJson(item.text), knowledgePostFilter) }
      : item);
  }
  return json;
}

export async function runStdioShim(): Promise<void> {
  process.stdin.setEncoding("utf8");
  let buffer = "";
  process.stdin.on("data", (chunk) => {
    buffer += chunk;
    const lines = buffer.split(/\n/u);
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) {continue;}
      void handleLine(line);
    }
  });
}

async function handleLine(line: string): Promise<void> {
  try {
    const message = JSON.parse(line);
    if (message && typeof message === "object" && !Array.isArray(message) && !("id" in message)) {
      return;
    }
    const response = await forwardMcpMessage(message);
    process.stdout.write(`${JSON.stringify(response)}\n`);
  } catch (err) {
    process.stdout.write(JSON.stringify({
      jsonrpc: "2.0",
      id: null,
      error: { code: -32700, message: err instanceof Error ? err.message : "Invalid MCP stdio input." }
    }) + "\n");
  }
}
