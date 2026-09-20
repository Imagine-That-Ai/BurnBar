import { type IncomingMessage, type ServerResponse } from "node:http";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import {
  firstHeaderValue,
  LOCAL_CLIPROXY_KEY,
  type ProxyOptions,
} from "./proxyAuth.js";

export const MAX_PROXY_BODY_BYTES = 8 * 1024 * 1024;
export const REQUEST_TOO_LARGE_MESSAGE =
  `Request body exceeds the ${MAX_PROXY_BODY_BYTES}-byte (8 MiB) limit. This gateway does not raise that cap without a real client 413. Split the prompt, drop unused tools, or forward to BurnBar on :8317 if its daemon allows more.`;
export const DEFAULT_NON_STREAM_FETCH_TIMEOUT_MS = 120_000;
function parseTimeoutEnv(raw: string | undefined): number | undefined {
  const n = Number(raw);
  return Number.isSafeInteger(n) && n > 0 && n <= 2_147_483_647 ? n : undefined;
}
export const NON_STREAM_FETCH_TIMEOUT_MS =
  parseTimeoutEnv(process.env["OPENBURNBAR_UPSTREAM_TIMEOUT_MS"]) ?? DEFAULT_NON_STREAM_FETCH_TIMEOUT_MS;
export const DEFAULT_ANTHROPIC_VERSION = "2023-06-01";
export const PROXY_HEADERS_TIMEOUT_MS = 10_000;
export const PROXY_REQUEST_TIMEOUT_MS = 120_000;
export const PROXY_KEEP_ALIVE_TIMEOUT_MS = 5_000;
export const PROXY_SOCKET_TIMEOUT_MS = 0;
export const STREAM_IDLE_TIMEOUT_MS = 300_000;
export const MAX_PROXY_CONNECTIONS = 256;

export const PROVIDER_NOT_CONFIGURED_MESSAGE =
  "Standalone mode needs XAI_API_KEY or OPENBURNBAR_PROVIDER_BASE_URL plus OPENBURNBAR_PROVIDER_API_KEY. To forward to BurnBar instead: OPENBURNBAR_UPSTREAM=http://127.0.0.1:8317 and OPENBURNBAR_GATEWAY_TOKEN matching BurnBar's gateway token.";

export type RelayDialect = "models" | "chat" | "messages" | "responses";

export interface RequestError extends Error {
  status: number;
  code: string;
}

export interface RelayTarget {
  label: string;
  modelsUrl: string;
  chatUrl: string;
  messagesUrl: string;
  responsesUrl: string;
  credential: string;
}

function isForwardableResponseHeader(name: string): boolean {
  const key = name.toLowerCase();
  return key === "content-type" || key === "retry-after" || key === "x-request-id" || key.startsWith("x-ratelimit-");
}

export function errorDetail(error: unknown): string {
  let message = error instanceof Error ? error.message : String(error);
  if (error instanceof Error && error.cause instanceof Error && error.cause.message) {
    message = error.cause.message;
  }
  return message.replace(/\S+:\S+@/gu, "");
}

const REDIRECT_STATUS_CODES = new Set([300, 301, 302, 303, 305, 307, 308]);

export function requestError(status: number, code: string, message: string): RequestError {
  return Object.assign(new Error(message), { status, code });
}

export function sendJson(res: ServerResponse, status: number, data: unknown): void {
  const json = JSON.stringify(data);
  res.writeHead(status, {
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(json),
    "Content-Type": "application/json; charset=utf-8",
    "X-Content-Type-Options": "nosniff",
  });
  res.end(json);
}

export function sendApiError(
  res: ServerResponse,
  status: number,
  code: string,
  message: string,
  type = "invalid_request_error"
): void {
  sendJson(res, status, { error: { message, type, code } });
}

export const MAX_INFLIGHT_BODY_BYTES = 64 * 1024 * 1024; // 64 MiB global ceiling
let inflightBodyBytes = 0;

export function getInflightBodyBytes(): number {
  return inflightBodyBytes;
}

export function releaseInflightBodyBytes(bytes: number): void {
  inflightBodyBytes = Math.max(0, inflightBodyBytes - bytes);
}

export interface ReadBodyResult {
  rawBody: string;
  bytes: number;
}

export function readBody(req: IncomingMessage): Promise<ReadBodyResult> {
  const declaredLength = Number(req.headers["content-length"] ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > MAX_PROXY_BODY_BYTES) {
    throw requestError(413, "request_too_large", REQUEST_TOO_LARGE_MESSAGE);
  }
  if (
    Number.isFinite(declaredLength) &&
    declaredLength > 0 &&
    inflightBodyBytes + declaredLength > MAX_INFLIGHT_BODY_BYTES
  ) {
    throw requestError(
      503,
      "gateway_overloaded",
      "Gateway is buffering its maximum concurrent request bytes. Retry shortly."
    );
  }

  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let bytes = 0;
    let settled = false;

    const finish = (callback: () => void): void => {
      if (settled) {
        return;
      }
      settled = true;
      callback();
    };

    req.on("data", (chunk: Buffer | string) => {
      if (settled) {
        return;
      }
      const bytesChunk = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      bytes += bytesChunk.length;
      inflightBodyBytes += bytesChunk.length;
      if (inflightBodyBytes > MAX_INFLIGHT_BODY_BYTES) {
        finish(() => {
          req.resume();
          releaseInflightBodyBytes(bytes);
          reject(
            requestError(
              503,
              "gateway_overloaded",
              "Gateway is buffering its maximum concurrent request bytes. Retry shortly."
            )
          );
        });
        return;
      }
      if (bytes > MAX_PROXY_BODY_BYTES) {
        finish(() => {
          req.resume();
          releaseInflightBodyBytes(bytes);
          reject(
            requestError(413, "request_too_large", REQUEST_TOO_LARGE_MESSAGE)
          );
        });
        return;
      }
      chunks.push(bytesChunk);
    });
    req.on("end", () =>
      finish(() => resolve({ rawBody: Buffer.concat(chunks).toString("utf8"), bytes }))
    );
    req.on("aborted", () =>
      finish(() => {
        releaseInflightBodyBytes(bytes);
        reject(requestError(400, "request_aborted", "Request body was interrupted"));
      })
    );
    req.on("error", (error) =>
      finish(() => {
        releaseInflightBodyBytes(bytes);
        reject(error);
      })
    );
  });
}

export function providerEndpoint(baseUrl: string, path: string): string {
  return new URL(path, `${baseUrl.replace(/\/+$/u, "")}/`).toString();
}

export function relayTarget(options: ProxyOptions): RelayTarget | null {
  if (options.upstream) {
    const credential = options.upstreamToken ?? LOCAL_CLIPROXY_KEY;
    return {
      label: "OpenBurnBar upstream",
      modelsUrl: new URL("/v1/models", options.upstream).toString(),
      chatUrl: new URL("/v1/chat/completions", options.upstream).toString(),
      messagesUrl: new URL("/v1/messages", options.upstream).toString(),
      responsesUrl: new URL("/v1/responses", options.upstream).toString(),
      credential,
    };
  }
  if (options.provider) {
    return {
      label: `${options.provider.name} provider`,
      modelsUrl: providerEndpoint(options.provider.baseUrl, "models"),
      chatUrl: providerEndpoint(options.provider.baseUrl, "chat/completions"),
      messagesUrl: providerEndpoint(options.provider.baseUrl, "messages"),
      responsesUrl: providerEndpoint(options.provider.baseUrl, "responses"),
      credential: options.provider.apiKey,
    };
  }
  return null;
}

export function dialectNotSupportedMessage(path: string, label: string): string {
  return (
    `${label} does not serve POST ${path}. This gateway is a relay, not a translator. ` +
    "Recovery: OPENBURNBAR_UPSTREAM=http://127.0.0.1:8317 (BurnBar translates dialects) " +
    "or a dialect-capable OPENBURNBAR_PROVIDER_BASE_URL."
  );
}

function responseHeaders(headers: Headers): Record<string, string> {
  const result: Record<string, string> = {};
  headers.forEach((value, key) => {
    if (isForwardableResponseHeader(key)) {
      result[key] = value;
    }
  });
  result["Cache-Control"] = "no-store";
  result["X-Content-Type-Options"] = "nosniff";
  return result;
}

function relayRequestHeaders(
  req: IncomingMessage,
  target: RelayTarget,
  dialect: RelayDialect,
  hasBody: boolean
): Record<string, string> {
  const headers: Record<string, string> = {
    Accept: firstHeaderValue(req.headers["accept"]) ?? "*/*",
    "Accept-Encoding": "identity",
    Authorization: `Bearer ${target.credential}`,
    ...(hasBody
      ? { "Content-Type": firstHeaderValue(req.headers["content-type"]) ?? "application/json" }
      : {}),
  };
  if (dialect === "messages") {
    headers["x-api-key"] = target.credential;
    headers["anthropic-version"] =
      firstHeaderValue(req.headers["anthropic-version"]) ?? DEFAULT_ANTHROPIC_VERSION;
    const anthropicBeta = firstHeaderValue(req.headers["anthropic-beta"]);
    if (anthropicBeta) {
      headers["anthropic-beta"] = anthropicBeta;
    }
  }
  const conversationId = firstHeaderValue(req.headers["x-grok-conv-id"]);
  if (conversationId) {
    headers["x-grok-conv-id"] = conversationId;
  }
  return headers;
}

export async function relay(
  req: IncomingMessage,
  res: ServerResponse,
  target: RelayTarget,
  url: string,
  options: {
    dialect: RelayDialect;
    rawBody?: string;
    stream?: boolean;
    method?: string;
    nonStreamFetchTimeoutMs?: number;
  }
): Promise<void> {
  const controller = new AbortController();
  const abort = (): void => controller.abort();
  req.once("aborted", abort);
  res.once("close", abort);

  let nonStreamTimer: NodeJS.Timeout | undefined;
  if (!options.stream) {
    nonStreamTimer = setTimeout(() => {
      controller.abort(new Error("Non-stream request timed out"));
    }, options.nonStreamFetchTimeoutMs ?? NON_STREAM_FETCH_TIMEOUT_MS);
    nonStreamTimer.unref();
  }

  try {
    const method = options.method ?? (options.rawBody === undefined ? "GET" : "POST");
    const upstreamResponse = await fetch(url, {
      method,
      headers: relayRequestHeaders(req, target, options.dialect, options.rawBody !== undefined),
      body: options.rawBody,
      redirect: "manual",
      signal: controller.signal,
    });

    if (REDIRECT_STATUS_CODES.has(upstreamResponse.status)) {
      await upstreamResponse.body?.cancel();
      sendApiError(
        res,
        502,
        "unsafe_upstream_redirect",
        `${target.label} returned a redirect; configure its final API base URL instead`,
        "upstream_error"
      );
      return;
    }

    if (
      method === "POST" &&
      (options.dialect === "messages" || options.dialect === "responses") &&
      (upstreamResponse.status === 404 || upstreamResponse.status === 405)
    ) {
      await upstreamResponse.body?.cancel();
      sendApiError(
        res,
        502,
        "dialect_not_supported",
        dialectNotSupportedMessage(new URL(url).pathname, target.label),
        "upstream_error"
      );
      return;
    }

    res.writeHead(upstreamResponse.status, responseHeaders(upstreamResponse.headers));
    if (!upstreamResponse.body) {
      res.end();
      return;
    }

    let streamIdleTimer: NodeJS.Timeout | undefined;
    const armStreamIdle = (): void => {
      if (streamIdleTimer) {
        clearTimeout(streamIdleTimer);
      }
      streamIdleTimer = setTimeout(() => {
        controller.abort(new Error("Streaming upstream response timed out due to inactivity"));
      }, STREAM_IDLE_TIMEOUT_MS);
      streamIdleTimer.unref();
    };

    if (options.stream) {
      armStreamIdle();
    }

    const streamSource = Readable.fromWeb(
      upstreamResponse.body as import("node:stream/web").ReadableStream<Uint8Array>
    );
    if (options.stream) {
      streamSource.on("data", armStreamIdle);
    }

    try {
      await pipeline(streamSource, res);
    } finally {
      if (streamIdleTimer) {
        clearTimeout(streamIdleTimer);
      }
    }
  } catch (error) {
    if (res.headersSent || res.destroyed) {
      if (!res.destroyed) {
        res.destroy(error instanceof Error ? error : new Error(String(error)));
      }
      return;
    }
    sendApiError(
      res,
      502,
      "bad_gateway",
      `${target.label} is unavailable: ${errorDetail(error)}`,
      "upstream_error"
    );
  } finally {
    if (nonStreamTimer) {
      clearTimeout(nonStreamTimer);
    }
    req.off("aborted", abort);
    res.off("close", abort);
  }
}
