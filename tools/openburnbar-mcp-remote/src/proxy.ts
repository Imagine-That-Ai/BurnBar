import { execFileSync } from "node:child_process";
import { randomBytes, timingSafeEqual } from "node:crypto";
import {
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import http, { type IncomingMessage, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

export const DEFAULT_PROXY_PORT = 8320;
export const DEFAULT_PROXY_HOST = "127.0.0.1";
export const LOCAL_CLIPROXY_KEY = "local-cliproxy";
export const MAX_PROXY_BODY_BYTES = 8 * 1024 * 1024;

const PROXY_SERVICE = "openburnbar-proxy";
const PID_FILE_VERSION = 1;
const CONTROL_HEADER = "x-openburnbar-proxy-token";
const HEALTH_TIMEOUT_MS = 1_000;
const STOP_TIMEOUT_MS = 3_000;

export const PROXY_USAGE = `Usage:
  openburnbar proxy [--port <8320>] [--host <127.0.0.1>] [--allow-local-key] [--token <token>]
  openburnbar proxy status [--port <8320>]
  openburnbar proxy stop [--port <8320>]

Options:
  --port, -p <port>    Port to bind or inspect (default: 8320)
  --host <host>        Loopback host to bind (default: 127.0.0.1)
  --allow-local-key    Accept Bearer local-cliproxy on loopback (enabled by default)
  --token, -t <token>  Accept one additional Bearer token

Environment:
  XAI_API_KEY                         Standalone xAI chat-completions provider
  OPENBURNBAR_PROVIDER_BASE_URL       Standalone OpenAI-compatible provider base URL
  OPENBURNBAR_PROVIDER_API_KEY        Credential for that standalone provider
  OPENBURNBAR_UPSTREAM                Loopback OpenBurnBar-compatible gateway to forward to
  OPENBURNBAR_GATEWAY_TOKEN           Extra local token and forward-upstream token

app install puts OpenBurnBar.app on disk; proxy starts the local OpenAI gateway; npm i never starts either.
`;

export type ProxyCommand = "start" | "status" | "stop";

export interface StandaloneProvider {
  name: string;
  baseUrl: string;
  apiKey: string;
}

export interface ProxyOptions {
  port: number;
  host: string;
  allowLocalKey: boolean;
  token?: string;
  upstream?: string;
  upstreamToken?: string;
  provider?: StandaloneProvider;
  instanceToken?: string;
}

export interface ProxyCliOptions extends ProxyOptions {
  command: ProxyCommand;
}

export interface ProcessPortInfo {
  pid: number;
  command: string;
}

interface ProxyPidFile {
  version: typeof PID_FILE_VERSION;
  pid: number;
  port: number;
  host: string;
  token: string;
  startedAt: string;
}

interface ProxyHealth {
  status: "ok";
  service: typeof PROXY_SERVICE;
  pid: number;
  port: number;
  mode: "standalone" | "forward";
  provider: string | null;
  instance: boolean;
}

interface RequestError extends Error {
  status: number;
  code: string;
}

interface RelayTarget {
  label: string;
  modelsUrl: string;
  completionsUrl: string;
  authorization: string;
}

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

const HOP_BY_HOP_RESPONSE_HEADERS = new Set([
  "connection",
  "content-encoding",
  "content-length",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

const SAFE_UPSTREAM_REQUEST_HEADERS = ["x-grok-conv-id"] as const;
const REDIRECT_STATUS_CODES = new Set([300, 301, 302, 303, 305, 307, 308]);

function requestError(status: number, code: string, message: string): RequestError {
  return Object.assign(new Error(message), { status, code });
}

function strictPort(value: string): number {
  if (!/^\d{1,5}$/u.test(value)) {
    throw new Error(`error: invalid port number "${value}"`);
  }
  const port = Number(value);
  if (!Number.isInteger(port) || port <= 0 || port > 65_535) {
    throw new Error(`error: invalid port number "${value}"`);
  }
  return port;
}

function requiredOptionValue(argv: string[], index: number, option: string): string {
  const value = argv[index + 1];
  if (!value || value.startsWith("-")) {
    throw new Error(`error: ${option} requires a value`);
  }
  return value;
}

export function normalizeProxyHost(value: string): string {
  if (
    value === DEFAULT_PROXY_HOST ||
    value === "localhost" ||
    value === "::1" ||
    value === "[::1]"
  ) {
    return DEFAULT_PROXY_HOST;
  }
  throw new Error(`error: proxy host must be loopback; received "${value}"`);
}

export function normalizeLoopbackUpstream(value: string): string {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(
      `error: OPENBURNBAR_UPSTREAM must be a valid loopback HTTP URL; received "${value}"`
    );
  }
  const loopback = parsed.hostname === "127.0.0.1" || parsed.hostname === "[::1]";
  const rootPath = parsed.pathname === "" || parsed.pathname === "/";
  if (
    parsed.protocol !== "http:" ||
    !loopback ||
    parsed.username ||
    parsed.password ||
    !rootPath ||
    parsed.search ||
    parsed.hash
  ) {
    throw new Error(
      "error: OPENBURNBAR_UPSTREAM must be an origin-only http://127.0.0.1 or http://[::1] URL"
    );
  }
  return parsed.origin;
}

function normalizeProviderBaseUrl(value: string): string {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`error: OPENBURNBAR_PROVIDER_BASE_URL is invalid: "${value}"`);
  }
  const loopback = parsed.hostname === "127.0.0.1" || parsed.hostname === "[::1]";
  if (
    (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && loopback)) ||
    parsed.username ||
    parsed.password ||
    parsed.search ||
    parsed.hash
  ) {
    throw new Error(
      "error: standalone provider URL must be HTTPS, or loopback HTTP for local development"
    );
  }
  return parsed.toString().replace(/\/+$/u, "");
}

function resolveStandaloneProvider(env: NodeJS.ProcessEnv): StandaloneProvider | undefined {
  const customBaseUrl = env["OPENBURNBAR_PROVIDER_BASE_URL"]?.trim();
  const customApiKey = env["OPENBURNBAR_PROVIDER_API_KEY"]?.trim();
  if (customBaseUrl || customApiKey) {
    if (!customBaseUrl || !customApiKey) {
      throw new Error(
        "error: OPENBURNBAR_PROVIDER_BASE_URL and OPENBURNBAR_PROVIDER_API_KEY must be set together"
      );
    }
    return {
      name: "custom",
      baseUrl: normalizeProviderBaseUrl(customBaseUrl),
      apiKey: customApiKey,
    };
  }

  const xaiApiKey = env["XAI_API_KEY"]?.trim();
  if (xaiApiKey) {
    return {
      name: "xai",
      baseUrl: "https://api.x.ai/v1",
      apiKey: xaiApiKey,
    };
  }
  return undefined;
}

export function parseProxyCliOptions(
  argv: string[],
  env: NodeJS.ProcessEnv = process.env
): ProxyCliOptions {
  let command: ProxyCommand = "start";
  let port = DEFAULT_PROXY_PORT;
  let host = DEFAULT_PROXY_HOST;
  let allowLocalKey = true;
  let token = env["OPENBURNBAR_GATEWAY_TOKEN"]?.trim() || undefined;

  let index = 0;
  if (argv[0] === "status" || argv[0] === "stop") {
    command = argv[0];
    index = 1;
  }

  for (; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--port" || arg === "-p") {
      port = strictPort(requiredOptionValue(argv, index, arg));
      index += 1;
      continue;
    }
    if (arg === "--host") {
      if (command !== "start") {
        throw new Error(`error: ${command} only accepts --port`);
      }
      host = normalizeProxyHost(requiredOptionValue(argv, index, arg));
      index += 1;
      continue;
    }
    if (arg === "--allow-local-key") {
      if (command !== "start") {
        throw new Error(`error: ${command} only accepts --port`);
      }
      allowLocalKey = true;
      continue;
    }
    if (arg === "--token" || arg === "-t") {
      if (command !== "start") {
        throw new Error(`error: ${command} only accepts --port`);
      }
      token = requiredOptionValue(argv, index, arg);
      index += 1;
      continue;
    }
    throw new Error(`error: unknown proxy argument "${arg ?? ""}"`);
  }

  if (command !== "start") {
    return { command, port, host, allowLocalKey };
  }

  const upstreamValue = env["OPENBURNBAR_UPSTREAM"]?.trim();
  return {
    command,
    port,
    host,
    allowLocalKey,
    token,
    upstream: upstreamValue ? normalizeLoopbackUpstream(upstreamValue) : undefined,
    upstreamToken: env["OPENBURNBAR_GATEWAY_TOKEN"]?.trim() || undefined,
    provider: resolveStandaloneProvider(env),
  };
}

export function getProcessOnPort(port: number): ProcessPortInfo | null {
  try {
    const stdout = execFileSync(
      "lsof",
      ["-nP", `-iTCP@${DEFAULT_PROXY_HOST}:${port}`, "-sTCP:LISTEN"],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 1_500,
      }
    );
    const row = stdout.trim().split("\n")[1]?.trim().split(/\s+/u);
    const pid = Number(row?.[1]);
    if (!Number.isInteger(pid) || pid <= 0) {
      return null;
    }
    let command = row?.[0] ?? "unknown";
    try {
      const fullCommand = execFileSync("ps", ["-p", String(pid), "-o", "command="], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 1_500,
      }).trim();
      if (fullCommand) {
        command = fullCommand;
      }
    } catch {
      // The lsof command name is still useful when ps is unavailable.
    }
    return { pid, command };
  } catch {
    return null;
  }
}

export function isLoopbackIp(ip: string | undefined): boolean {
  return ip === "127.0.0.1" || ip === "::1" || ip === "::ffff:127.0.0.1";
}

function safeTokenEqual(provided: string, expected: string): boolean {
  const providedBytes = Buffer.from(provided);
  const expectedBytes = Buffer.from(expected);
  return (
    providedBytes.length === expectedBytes.length &&
    timingSafeEqual(providedBytes, expectedBytes)
  );
}

export function isAuthorized(
  authHeader: string | undefined,
  clientIp: string | undefined,
  options: { allowLocalKey: boolean; token?: string }
): boolean {
  if (!authHeader || !isLoopbackIp(clientIp)) {
    return false;
  }
  const match = /^Bearer\s+(.+)$/iu.exec(authHeader);
  const provided = match?.[1]?.trim();
  if (!provided) {
    return false;
  }
  if (options.token && safeTokenEqual(provided, options.token)) {
    return true;
  }
  return options.allowLocalKey && safeTokenEqual(provided, LOCAL_CLIPROXY_KEY);
}

function sendJson(res: ServerResponse, status: number, data: unknown): void {
  const json = JSON.stringify(data);
  res.writeHead(status, {
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(json),
    "Content-Type": "application/json; charset=utf-8",
    "X-Content-Type-Options": "nosniff",
  });
  res.end(json);
}

function sendApiError(
  res: ServerResponse,
  status: number,
  code: string,
  message: string,
  type = "invalid_request_error"
): void {
  sendJson(res, status, { error: { message, type, code } });
}

function readBody(req: IncomingMessage): Promise<string> {
  const declaredLength = Number(req.headers["content-length"] ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > MAX_PROXY_BODY_BYTES) {
    throw requestError(
      413,
      "request_too_large",
      `Request body exceeds the ${MAX_PROXY_BODY_BYTES}-byte limit`
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
      if (bytes > MAX_PROXY_BODY_BYTES) {
        finish(() => {
          req.resume();
          reject(
            requestError(
              413,
              "request_too_large",
              `Request body exceeds the ${MAX_PROXY_BODY_BYTES}-byte limit`
            )
          );
        });
        return;
      }
      chunks.push(bytesChunk);
    });
    req.on("end", () => finish(() => resolve(Buffer.concat(chunks).toString("utf8"))));
    req.on("aborted", () =>
      finish(() => reject(requestError(400, "request_aborted", "Request body was interrupted")))
    );
    req.on("error", (error) => finish(() => reject(error)));
  });
}

function validateChatBody(rawBody: string): void {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    throw requestError(400, "bad_request", "Invalid JSON payload in request body");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw requestError(400, "bad_request", "Request body must be a JSON object");
  }
  const body = parsed as Record<string, unknown>;
  if (typeof body["model"] !== "string" || body["model"].trim().length === 0) {
    throw requestError(400, "bad_request", "Request body requires a non-empty model");
  }
  if (!Array.isArray(body["messages"]) || body["messages"].length === 0) {
    throw requestError(400, "bad_request", "Request body requires a non-empty messages array");
  }
  if (body["stream"] !== undefined && typeof body["stream"] !== "boolean") {
    throw requestError(400, "bad_request", "stream must be a boolean when provided");
  }
}

function providerEndpoint(baseUrl: string, path: string): string {
  return new URL(path, `${baseUrl.replace(/\/+$/u, "")}/`).toString();
}

function relayTarget(options: ProxyOptions): RelayTarget | null {
  if (options.upstream) {
    return {
      label: "OpenBurnBar upstream",
      modelsUrl: new URL("/v1/models", options.upstream).toString(),
      completionsUrl: new URL("/v1/chat/completions", options.upstream).toString(),
      authorization: `Bearer ${options.upstreamToken ?? LOCAL_CLIPROXY_KEY}`,
    };
  }
  if (options.provider) {
    return {
      label: `${options.provider.name} provider`,
      modelsUrl: providerEndpoint(options.provider.baseUrl, "models"),
      completionsUrl: providerEndpoint(options.provider.baseUrl, "chat/completions"),
      authorization: `Bearer ${options.provider.apiKey}`,
    };
  }
  return null;
}

function responseHeaders(headers: Headers): Record<string, string> {
  const result: Record<string, string> = {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  };
  headers.forEach((value, key) => {
    if (!HOP_BY_HOP_RESPONSE_HEADERS.has(key.toLowerCase())) {
      result[key] = value;
    }
  });
  return result;
}

function relayRequestHeaders(
  req: IncomingMessage,
  authorization: string,
  hasBody: boolean
): Record<string, string> {
  const headers: Record<string, string> = {
    Accept: req.headers["accept"] ?? "*/*",
    "Accept-Encoding": "identity",
    Authorization: authorization,
    ...(hasBody
      ? { "Content-Type": req.headers["content-type"] ?? "application/json" }
      : {}),
  };
  for (const name of SAFE_UPSTREAM_REQUEST_HEADERS) {
    const value = req.headers[name];
    if (typeof value === "string" && value.length > 0) {
      headers[name] = value;
    }
  }
  return headers;
}

async function relay(
  req: IncomingMessage,
  res: ServerResponse,
  target: RelayTarget,
  url: string,
  rawBody?: string
): Promise<void> {
  const controller = new AbortController();
  const abort = (): void => controller.abort();
  req.once("aborted", abort);
  res.once("close", abort);

  try {
    const upstreamResponse = await fetch(url, {
      method: rawBody === undefined ? "GET" : "POST",
      headers: relayRequestHeaders(req, target.authorization, rawBody !== undefined),
      body: rawBody,
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

    res.writeHead(upstreamResponse.status, responseHeaders(upstreamResponse.headers));
    if (!upstreamResponse.body) {
      res.end();
      return;
    }
    await pipeline(
      Readable.fromWeb(
        upstreamResponse.body as import("node:stream/web").ReadableStream<Uint8Array>
      ),
      res
    );
  } catch (error) {
    if (controller.signal.aborted) {
      return;
    }
    if (!res.headersSent) {
      sendApiError(
        res,
        502,
        "bad_gateway",
        `${target.label} is unavailable: ${error instanceof Error ? error.message : String(error)}`,
        "upstream_error"
      );
    } else {
      res.destroy(error instanceof Error ? error : new Error(String(error)));
    }
  } finally {
    req.off("aborted", abort);
    res.off("close", abort);
  }
}

function proxyMode(options: ProxyOptions): Pick<ProxyHealth, "mode" | "provider"> {
  if (options.upstream) {
    return { mode: "forward", provider: null };
  }
  return { mode: "standalone", provider: options.provider?.name ?? null };
}

function pathname(req: IncomingMessage): string {
  try {
    return new URL(req.url ?? "/", "http://127.0.0.1").pathname;
  } catch {
    throw requestError(400, "bad_request", "Malformed request URL");
  }
}

export function createProxyServer(options: ProxyOptions): http.Server {
  normalizeProxyHost(options.host);
  if (options.upstream) {
    normalizeLoopbackUpstream(options.upstream);
  }
  const instanceToken = options.instanceToken ?? randomBytes(32).toString("hex");

  const server = http.createServer((req, res) => {
    void (async () => {
      const requestPath = pathname(req);

      if (req.method === "GET" && requestPath === "/health") {
        const providedToken = req.headers[CONTROL_HEADER];
        const tokenValue = Array.isArray(providedToken) ? providedToken[0] : providedToken;
        const mode = proxyMode(options);
        sendJson(res, 200, {
          status: "ok",
          service: PROXY_SERVICE,
          pid: process.pid,
          port: options.port,
          mode: mode.mode,
          provider: mode.provider,
          instance: Boolean(tokenValue && safeTokenEqual(tokenValue, instanceToken)),
        } satisfies ProxyHealth);
        return;
      }

      if (!isAuthorized(req.headers["authorization"], req.socket.remoteAddress, options)) {
        sendApiError(
          res,
          401,
          "invalid_api_key",
          "Incorrect API key or missing Bearer authorization header"
        );
        return;
      }

      const target = relayTarget(options);
      if (requestPath === "/v1/models") {
        if (req.method !== "GET") {
          res.setHeader("Allow", "GET");
          sendApiError(res, 405, "method_not_allowed", "GET is required for /v1/models");
          return;
        }
        if (target) {
          await relay(req, res, target, target.modelsUrl);
          return;
        }
        sendJson(res, 200, { object: "list", data: CURATED_MODELS });
        return;
      }

      if (requestPath === "/v1/chat/completions") {
        if (req.method !== "POST") {
          res.setHeader("Allow", "POST");
          sendApiError(
            res,
            405,
            "method_not_allowed",
            "POST is required for /v1/chat/completions"
          );
          return;
        }
        if (!req.headers["content-type"]?.toLowerCase().startsWith("application/json")) {
          sendApiError(res, 415, "unsupported_media_type", "Content-Type must be application/json");
          return;
        }
        const rawBody = await readBody(req);
        validateChatBody(rawBody);
        if (!target) {
          sendApiError(
            res,
            503,
            "provider_not_configured",
            "Standalone mode needs XAI_API_KEY or OPENBURNBAR_PROVIDER_BASE_URL plus OPENBURNBAR_PROVIDER_API_KEY",
            "configuration_error"
          );
          return;
        }
        await relay(req, res, target, target.completionsUrl, rawBody);
        return;
      }

      sendApiError(
        res,
        404,
        "not_found",
        `Not found: ${req.method ?? "GET"} ${requestPath}`
      );
    })().catch((error: unknown) => {
      if (res.headersSent || res.destroyed) {
        res.destroy(error instanceof Error ? error : new Error(String(error)));
        return;
      }
      const known = error as Partial<RequestError>;
      if (known.status === 413) {
        res.setHeader("Connection", "close");
      }
      sendApiError(
        res,
        known.status ?? 500,
        known.code ?? "internal_error",
        error instanceof Error ? error.message : String(error),
        known.status && known.status < 500 ? "invalid_request_error" : "server_error"
      );
    });
  });

  server.headersTimeout = 10_000;
  server.requestTimeout = 30_000;
  server.keepAliveTimeout = 5_000;
  server.maxHeadersCount = 100;
  return server;
}

export function proxyPidFilePath(port: number): string {
  const uid = typeof process.getuid === "function" ? process.getuid() : "user";
  return join(tmpdir(), `openburnbar-proxy-${uid}-${port}.json`);
}

function readPidFile(port: number): ProxyPidFile | null {
  try {
    const parsed = JSON.parse(readFileSync(proxyPidFilePath(port), "utf8")) as Partial<ProxyPidFile>;
    if (
      parsed.version !== PID_FILE_VERSION ||
      parsed.port !== port ||
      !Number.isInteger(parsed.pid) ||
      (parsed.pid ?? 0) <= 0 ||
      typeof parsed.host !== "string" ||
      typeof parsed.token !== "string" ||
      parsed.token.length < 32 ||
      typeof parsed.startedAt !== "string"
    ) {
      return null;
    }
    return parsed as ProxyPidFile;
  } catch {
    return null;
  }
}

function writePidFile(record: ProxyPidFile): void {
  const path = proxyPidFilePath(record.port);
  const temporaryPath = `${path}.${process.pid}.${randomBytes(6).toString("hex")}`;
  writeFileSync(temporaryPath, `${JSON.stringify(record)}\n`, {
    encoding: "utf8",
    flag: "wx",
    mode: 0o600,
  });
  renameSync(temporaryPath, path);
}

function removePidFile(record: ProxyPidFile): void {
  const current = readPidFile(record.port);
  if (!current || current.pid !== record.pid || !safeTokenEqual(current.token, record.token)) {
    return;
  }
  try {
    unlinkSync(proxyPidFilePath(record.port));
  } catch {
    // A concurrent cleanup may already have removed it.
  }
}

function processExists(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export async function probeProxy(
  port: number,
  pidFile: ProxyPidFile | null = readPidFile(port)
): Promise<ProxyHealth | null> {
  if (!pidFile) {
    return null;
  }
  return new Promise((resolve) => {
    const request = http.get(
      {
        host: DEFAULT_PROXY_HOST,
        port,
        path: "/health",
        headers: { [CONTROL_HEADER]: pidFile.token },
        timeout: HEALTH_TIMEOUT_MS,
      },
      (response) => {
        const chunks: Buffer[] = [];
        let bytes = 0;
        response.on("data", (chunk: Buffer) => {
          bytes += chunk.length;
          if (bytes <= 65_536) {
            chunks.push(chunk);
          }
        });
        response.on("end", () => {
          try {
            const parsed = JSON.parse(Buffer.concat(chunks).toString("utf8")) as Partial<ProxyHealth>;
            if (
              response.statusCode === 200 &&
              parsed.status === "ok" &&
              parsed.service === PROXY_SERVICE &&
              parsed.pid === pidFile.pid &&
              parsed.port === port &&
              parsed.instance === true
            ) {
              resolve(parsed as ProxyHealth);
              return;
            }
          } catch {
            // A foreign listener may return non-JSON or an unrelated JSON shape.
          }
          resolve(null);
        });
      }
    );
    request.on("error", () => resolve(null));
    request.on("timeout", () => {
      request.destroy();
      resolve(null);
    });
  });
}

export async function runProxyStatus(port = DEFAULT_PROXY_PORT): Promise<number> {
  const pidFile = readPidFile(port);
  const [health, processInfo] = await Promise.all([
    probeProxy(port, pidFile),
    Promise.resolve(getProcessOnPort(port)),
  ]);
  const owned =
    Boolean(pidFile && health) &&
    (!processInfo || processInfo.pid === pidFile?.pid) &&
    processExists(pidFile?.pid ?? -1);

  const output: Record<string, unknown> = {
    listening: owned,
    port,
    url: `http://${DEFAULT_PROXY_HOST}:${port}/v1/chat/completions`,
  };
  if (owned && pidFile && health) {
    output["pid"] = pidFile.pid;
    output["mode"] = health.mode;
    output["provider"] = health.provider;
  } else if (processInfo) {
    output["occupied"] = true;
    output["pid"] = processInfo.pid;
    output["command"] = processInfo.command;
  }
  process.stdout.write(`${JSON.stringify(output)}\n`);
  return owned ? 0 : 1;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export async function runProxyStop(port = DEFAULT_PROXY_PORT): Promise<number> {
  const pidFile = readPidFile(port);
  const processInfo = getProcessOnPort(port);
  if (!pidFile) {
    if (processInfo) {
      process.stderr.write(
        `Refusing to stop PID ${processInfo.pid} (${processInfo.command}): port ${port} is not owned by an OpenBurnBar proxy pid file.\n`
      );
      return 1;
    }
    process.stdout.write(`OpenBurnBar proxy is not running on port ${port}.\n`);
    return 0;
  }

  const health = await probeProxy(port, pidFile);
  if (
    !health ||
    !processExists(pidFile.pid) ||
    (processInfo !== null && processInfo.pid !== pidFile.pid)
  ) {
    if (!processExists(pidFile.pid)) {
      removePidFile(pidFile);
    }
    const occupied = processInfo
      ? ` PID ${processInfo.pid} (${processInfo.command}) owns the port.`
      : "";
    process.stderr.write(
      `Refusing to stop port ${port}: the listener does not match the OpenBurnBar proxy pid file.${occupied}\n`
    );
    return 1;
  }

  try {
    process.kill(pidFile.pid, "SIGTERM");
  } catch (error) {
    process.stderr.write(
      `Failed to stop OpenBurnBar proxy PID ${pidFile.pid}: ${error instanceof Error ? error.message : String(error)}\n`
    );
    return 1;
  }

  const deadline = Date.now() + STOP_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (!(await probeProxy(port, pidFile))) {
      removePidFile(pidFile);
      process.stdout.write(`OpenBurnBar proxy stopped on port ${port} (PID ${pidFile.pid}).\n`);
      return 0;
    }
    await delay(100);
  }
  process.stderr.write(
    `OpenBurnBar proxy PID ${pidFile.pid} did not stop within ${STOP_TIMEOUT_MS}ms after SIGTERM.\n`
  );
  return 1;
}

function startupMode(options: ProxyOptions): string {
  if (options.upstream) {
    return `openburnbar proxy forward :${options.port} -> ${options.upstream}`;
  }
  return `openburnbar proxy standalone :${options.port} (${options.provider?.name ?? "provider not configured"})`;
}

export async function runProxyServer(options: ProxyOptions): Promise<void> {
  const host = normalizeProxyHost(options.host);
  const instanceToken = options.instanceToken ?? randomBytes(32).toString("hex");
  const serverOptions = { ...options, host, instanceToken };
  const server = createProxyServer(serverOptions);
  const pidFile: ProxyPidFile = {
    version: PID_FILE_VERSION,
    pid: process.pid,
    port: options.port,
    host,
    token: instanceToken,
    startedAt: new Date().toISOString(),
  };

  await new Promise<void>((resolve, reject) => {
    const handleStartupError = (error: NodeJS.ErrnoException): void => {
      if (error.code === "EADDRINUSE") {
        const processInfo = getProcessOnPort(options.port);
        const holder = processInfo
          ? `PID ${processInfo.pid} (${processInfo.command})`
          : "another process";
        reject(
          Object.assign(
            new Error(
              `Port ${options.port} is already in use by ${holder}. Stop that process or pass --port; OpenBurnBar will not bind 8317.`
            ),
            { exitCode: 1 }
          )
        );
        return;
      }
      reject(error);
    };
    server.once("error", handleStartupError);
    server.listen({ port: options.port, host }, () => {
      server.off("error", handleStartupError);
      try {
        writePidFile(pidFile);
      } catch (error) {
        server.close();
        reject(
          new Error(
            `Proxy bound port ${options.port} but could not create its ownership pid file: ${error instanceof Error ? error.message : String(error)}`
          )
        );
        return;
      }
      process.stdout.write(`${startupMode(serverOptions)}\n`);
      resolve();
    });
  });

  await new Promise<void>((resolve) => {
    let shuttingDown = false;
    const shutdown = (): void => {
      if (shuttingDown) {
        return;
      }
      shuttingDown = true;
      removePidFile(pidFile);
      const forceClose = setTimeout(() => server.closeAllConnections(), 1_000);
      forceClose.unref();
      server.close(() => {
        clearTimeout(forceClose);
        resolve();
      });
    };
    process.once("SIGINT", shutdown);
    process.once("SIGTERM", shutdown);
    server.once("close", () => {
      removePidFile(pidFile);
      process.off("SIGINT", shutdown);
      process.off("SIGTERM", shutdown);
      resolve();
    });
  });
}

export async function runProxyCli(argv: string[]): Promise<number> {
  if (
    argv.length === 1 &&
    (argv[0] === "--help" || argv[0] === "-h" || argv[0] === "help")
  ) {
    process.stdout.write(PROXY_USAGE);
    return 0;
  }
  try {
    const options = parseProxyCliOptions(argv);
    if (options.command === "status") {
      return await runProxyStatus(options.port);
    }
    if (options.command === "stop") {
      return await runProxyStop(options.port);
    }
    await runProxyServer(options);
    return 0;
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    const exitCode = (error as { exitCode?: unknown }).exitCode;
    return typeof exitCode === "number" ? exitCode : 2;
  }
}
