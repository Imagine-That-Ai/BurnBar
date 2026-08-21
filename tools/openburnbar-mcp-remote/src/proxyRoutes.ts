import { randomBytes } from "node:crypto";
import http, { type IncomingMessage, type ServerResponse } from "node:http";
import {
  firstHeaderValue,
  isAllowedOrigin,
  isAuthorized,
  isLoopbackHost,
  isLoopbackIp,
  normalizeLoopbackUpstream,
  normalizeProxyHost,
  PROXY_CONTROL_HEADER,
  safeTokenEqual,
  UNAUTHORIZED_MESSAGE,
  type ProxyOptions,
} from "./proxyAuth.js";
import { gatewayPanelHtml } from "./proxyPanel.js";
import {
  MAX_PROXY_CONNECTIONS,
  PROVIDER_NOT_CONFIGURED_MESSAGE,
  PROXY_HEADERS_TIMEOUT_MS,
  PROXY_KEEP_ALIVE_TIMEOUT_MS,
  PROXY_REQUEST_TIMEOUT_MS,
  readBody,
  releaseInflightBodyBytes,
  relay,
  relayTarget,
  requestError,
  sendApiError,
  sendJson,
  type RequestError,
} from "./proxyRelay.js";
import { attachResponsesWebSocket } from "./proxyWebsocket.js";
import {
  buildGatewayPanelPayload,
  buildProxyStatusPayload,
  isProxyConfigured,
  PROXY_SERVICE,
  proxyMode,
  type ProxyHealth,
} from "./proxyStatus.js";

const CURATED_MODELS = [
  "grok-4.6",
  "grok-composer-2.5-fast",
  "grok-4.5",
  "gpt-5.6-luna",
  "claude-opus-5",
  "claude-fable-5",
  "claude-sonnet-4-6",
  "deepseek/deepseek-v4-flash",
  "kimi/k3",
].map((id) => ({
  id,
  object: "model",
  created: 1_700_000_000,
  owned_by: "openburnbar",
}));

function curatedModelIds(): string[] {
  return CURATED_MODELS.map((model) => model.id);
}

function requestUrl(req: IncomingMessage): URL {
  try {
    return new URL(req.url ?? "/", "http://127.0.0.1");
  } catch {
    throw requestError(400, "bad_request", "Malformed request URL");
  }
}

function pathname(req: IncomingMessage): string {
  return requestUrl(req).pathname;
}

function withClientQuery(url: string, req: IncomingMessage): string {
  const search = requestUrl(req).search;
  if (!search) {
    return url;
  }
  const target = new URL(url);
  target.search = search;
  return target.toString();
}

function requireJsonContentType(req: IncomingMessage): void {
  const contentType = firstHeaderValue(req.headers["content-type"])?.toLowerCase();
  if (!contentType?.startsWith("application/json")) {
    throw requestError(415, "unsupported_media_type", "Content-Type must be application/json");
  }
}

function asObject(rawBody: string): Record<string, unknown> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    throw requestError(400, "bad_request", "Invalid JSON payload in request body");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw requestError(400, "bad_request", "Request body must be a JSON object");
  }
  return parsed as Record<string, unknown>;
}

function requireModel(body: Record<string, unknown>): void {
  if (typeof body["model"] !== "string" || body["model"].trim().length === 0) {
    throw requestError(400, "bad_request", "Request body requires a non-empty model");
  }
}

function requireStreamBoolean(body: Record<string, unknown>): void {
  if (body["stream"] !== undefined && typeof body["stream"] !== "boolean") {
    throw requestError(400, "bad_request", "stream must be a boolean when provided");
  }
}

export function validateChatBody(rawBody: string): Record<string, unknown> {
  const body = asObject(rawBody);
  requireModel(body);
  if (!Array.isArray(body["messages"]) || body["messages"].length === 0) {
    throw requestError(400, "bad_request", "Request body requires a non-empty messages array");
  }
  requireStreamBoolean(body);
  return body;
}

export function validateMessagesBody(rawBody: string): Record<string, unknown> {
  const body = asObject(rawBody);
  requireModel(body);
  if (!Array.isArray(body["messages"]) || body["messages"].length === 0) {
    throw requestError(400, "bad_request", "Request body requires a non-empty messages array");
  }
  requireStreamBoolean(body);
  return body;
}

export function validateResponsesBody(rawBody: string): Record<string, unknown> {
  const body = asObject(rawBody);
  requireModel(body);
  const input = body["input"];
  if (typeof input !== "string" && !Array.isArray(input)) {
    throw requestError(400, "bad_request", "Request body requires input as a string or array");
  }
  requireStreamBoolean(body);
  return body;
}

export function wantsStream(bodyOrRaw: Record<string, unknown> | string): boolean {
  if (typeof bodyOrRaw === "string") {
    try {
      const parsed = JSON.parse(bodyOrRaw) as { stream?: unknown };
      return parsed?.stream === true;
    } catch {
      return false;
    }
  }
  return bodyOrRaw["stream"] === true;
}

function requirePost(req: IncomingMessage, res: ServerResponse, path: string): boolean {
  if (req.method === "POST") {
    return true;
  }
  res.setHeader("Allow", "POST");
  sendApiError(res, 405, "method_not_allowed", `POST is required for ${path}`);
  return false;
}

async function relayJsonPost(
  req: IncomingMessage,
  res: ServerResponse,
  options: ProxyOptions,
  path: string,
  dialect: "chat" | "messages" | "responses",
  validate: (rawBody: string) => Record<string, unknown>
): Promise<void> {
  if (!requirePost(req, res, path)) {
    return;
  }
  requireJsonContentType(req);
  const { rawBody, bytes } = await readBody(req);
  releaseInflightBodyBytes(bytes);
  const parsed = validate(rawBody);
  const target = relayTarget(options);
  if (!target) {
    sendApiError(
      res,
      503,
      "provider_not_configured",
      PROVIDER_NOT_CONFIGURED_MESSAGE,
      "configuration_error"
    );
    return;
  }
  const url =
    dialect === "chat" ? target.chatUrl : dialect === "messages" ? target.messagesUrl : target.responsesUrl;
  await relay(req, res, target, withClientQuery(url, req), {
    dialect,
    rawBody,
    stream: wantsStream(parsed),
    nonStreamFetchTimeoutMs: options.nonStreamFetchTimeoutMs,
  });
}

export function createProxyServer(options: ProxyOptions): http.Server {
  normalizeProxyHost(options.host);
  if (options.upstream) {
    normalizeLoopbackUpstream(options.upstream);
  }
  const instanceToken = options.instanceToken ?? randomBytes(32).toString("hex");

  const server = http.createServer((req, res) => {
    void (async () => {
      if (!isLoopbackHost(firstHeaderValue(req.headers["host"]))) {
        sendApiError(
          res,
          403,
          "invalid_host_header",
          "Host header must be a loopback address (127.0.0.1, localhost, or [::1])"
        );
        return;
      }

      if (!isAllowedOrigin(firstHeaderValue(req.headers["origin"]))) {
        sendApiError(
          res,
          403,
          "cross_origin_forbidden",
          "Cross-origin requests from non-loopback origins are forbidden"
        );
        return;
      }

      if (!isLoopbackIp(req.socket.remoteAddress)) {
        sendApiError(res, 403, "forbidden", "Only loopback connections are permitted");
        return;
      }

      const requestPath = pathname(req);

      if (req.method === "GET" && (requestPath === "/gateway" || requestPath === "/")) {
        const html = gatewayPanelHtml(options.port, Boolean(options.requireToken));
        res.writeHead(200, {
          "Cache-Control": "no-store",
          "Content-Type": "text/html; charset=utf-8",
          "Content-Length": Buffer.byteLength(html),
          "X-Content-Type-Options": "nosniff",
          "X-Frame-Options": "DENY",
          "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self' http://127.0.0.1:* http://localhost:*; img-src 'self' data:; frame-ancestors 'none';",
        });
        res.end(html);
        return;
      }

      if (req.method === "GET" && requestPath === "/health") {
        const providedToken = firstHeaderValue(req.headers[PROXY_CONTROL_HEADER]);
        const mode = proxyMode(options);
        sendJson(res, 200, {
          status: "ok",
          service: PROXY_SERVICE,
          pid: process.pid,
          port: options.port,
          mode: mode.mode,
          provider: mode.provider,
          requireToken: Boolean(options.requireToken),
          instance: Boolean(providedToken && safeTokenEqual(providedToken, instanceToken)),
        } satisfies ProxyHealth);
        return;
      }

      if (
        !isAuthorized(
          firstHeaderValue(req.headers["authorization"]),
          firstHeaderValue(req.headers["x-api-key"]),
          req.socket.remoteAddress,
          options
        )
      ) {
        sendApiError(res, 401, "invalid_api_key", UNAUTHORIZED_MESSAGE);
        return;
      }

      const target = relayTarget(options);
      const configured = isProxyConfigured(options);
      const mode = proxyMode(options);

      if (requestPath === "/v1/gateway/panel") {
        if (req.method !== "GET") {
          res.setHeader("Allow", "GET");
          sendApiError(res, 405, "method_not_allowed", "GET is required for /v1/gateway/panel");
          return;
        }
        const status = buildProxyStatusPayload({
          port: options.port,
          listening: true,
          pid: process.pid,
          mode: mode.mode,
          provider: mode.provider,
          requireToken: Boolean(options.requireToken),
          configured,
        });
        sendJson(res, 200, buildGatewayPanelPayload(status, curatedModelIds()));
        return;
      }

      if (requestPath === "/v1/models") {
        if (req.method !== "GET") {
          res.setHeader("Allow", "GET");
          sendApiError(res, 405, "method_not_allowed", "GET is required for /v1/models");
          return;
        }
        if (!target) {
          sendApiError(
            res,
            503,
            "provider_not_configured",
            PROVIDER_NOT_CONFIGURED_MESSAGE,
            "configuration_error"
          );
          return;
        }
        await relay(req, res, target, withClientQuery(target.modelsUrl, req), { dialect: "models" });
        return;
      }

      if (requestPath === "/v1/chat/completions") {
        await relayJsonPost(req, res, options, "/v1/chat/completions", "chat", validateChatBody);
        return;
      }

      if (requestPath === "/v1/messages") {
        await relayJsonPost(req, res, options, "/v1/messages", "messages", validateMessagesBody);
        return;
      }

      if (requestPath === "/v1/responses") {
        await relayJsonPost(req, res, options, "/v1/responses", "responses", validateResponsesBody);
        return;
      }

      const responseIdMatch = /^\/v1\/responses\/([^/]+)$/u.exec(requestPath);
      if (responseIdMatch) {
        if (req.method !== "GET" && req.method !== "DELETE") {
          res.setHeader("Allow", "GET, DELETE");
          sendApiError(res, 405, "method_not_allowed", "GET or DELETE is required for /v1/responses/:id");
          return;
        }
        let rawId = responseIdMatch[1] ?? "";
        try {
          rawId = decodeURIComponent(rawId);
        } catch {
          sendApiError(res, 400, "bad_request", "Malformed response id encoding");
          return;
        }
        if (rawId === "." || rawId === "..") {
          sendApiError(res, 400, "bad_request", "Invalid response id");
          return;
        }
        const RESPONSE_ID = /^[A-Za-z0-9_.:-]{1,128}$/u;
        if (!RESPONSE_ID.test(rawId)) {
          sendApiError(res, 400, "bad_request", "Malformed response id");
          return;
        }
        if (!target) {
          sendApiError(
            res,
            503,
            "provider_not_configured",
            PROVIDER_NOT_CONFIGURED_MESSAGE,
            "configuration_error"
          );
          return;
        }
        await relay(req, res, target, withClientQuery(`${target.responsesUrl.replace(/\/$/u, "")}/${rawId}`, req), {
          dialect: "responses",
          method: req.method,
        });
        return;
      }

      sendApiError(res, 404, "not_found", `Not found: ${req.method ?? "GET"} ${requestPath}`);
    })().catch((error: unknown) => {
      if (res.headersSent || res.destroyed) {
        res.destroy(error instanceof Error ? error : new Error(String(error)));
        return;
      }
      const known = error as Partial<RequestError>;
      const status = known.status ?? 500;
      if (status === 413) {
        res.setHeader("Connection", "close");
      }
      const rawMessage = error instanceof Error ? error.message : String(error);
      const message = status >= 500 ? "Internal proxy error" : rawMessage;
      if (status >= 500) {
        process.stderr.write(`[OpenBurnBar Proxy Error] ${rawMessage}\n`);
      }
      sendApiError(
        res,
        status,
        known.code ?? "internal_error",
        message,
        status < 500 ? "invalid_request_error" : "server_error"
      );
    });
  });

  attachResponsesWebSocket(server, options);
  server.maxConnections = MAX_PROXY_CONNECTIONS;
  server.headersTimeout = PROXY_HEADERS_TIMEOUT_MS;
  server.requestTimeout = PROXY_REQUEST_TIMEOUT_MS;
  server.keepAliveTimeout = PROXY_KEEP_ALIVE_TIMEOUT_MS;
  server.maxHeadersCount = 100;
  server.timeout = 0;
  return server;
}

export { CURATED_MODELS };
