import { timingSafeEqual } from "node:crypto";

export const DEFAULT_PROXY_PORT = 8320;
export const DEFAULT_PROXY_HOST = "127.0.0.1";
export const LOCAL_CLIPROXY_KEY = "local-cliproxy";
export const PROXY_CONTROL_HEADER = "x-openburnbar-proxy-token";

export const UNAUTHORIZED_MESSAGE =
  "Incorrect API key. On loopback, send `Authorization: Bearer local-cliproxy` or `x-api-key: local-cliproxy`. Check `openburnbar proxy status`.";

export interface StandaloneProvider {
  name: string;
  baseUrl: string;
  apiKey: string;
}

export interface ProxyOptions {
  port: number;
  host: string;
  allowLocalKey: boolean;
  requireToken?: boolean;
  token?: string;
  upstream?: string;
  upstreamToken?: string;
  provider?: StandaloneProvider;
  instanceToken?: string;
  tray?: boolean;
  nonStreamFetchTimeoutMs?: number;
}

export function isLoopbackIp(ip: string | undefined): boolean {
  return ip === "127.0.0.1" || ip === "::1" || ip === "::ffff:127.0.0.1";
}

export function isLoopbackHost(hostHeader: string | undefined): boolean {
  if (!hostHeader) {
    return false;
  }
  const trimmed = hostHeader.trim();
  return /^(?:127\.0\.0\.1|localhost|\[::1\]|::1)(?::\d+)?$/iu.test(trimmed);
}

export function isAllowedOrigin(originHeader: string | undefined): boolean {
  if (!originHeader) {
    return true;
  }
  const trimmed = originHeader.trim();
  if (
    trimmed.startsWith("vscode-webview://") ||
    trimmed.startsWith("vscode-file://")
  ) {
    return true;
  }
  try {
    const parsed = new URL(trimmed);
    const host = parsed.hostname.toLowerCase();
    return (
      (parsed.protocol === "http:" || parsed.protocol === "https:") &&
      (host === "127.0.0.1" || host === "localhost" || host === "[::1]" || host === "::1")
    );
  } catch {
    return false;
  }
}

export function firstHeaderValue(value: string | string[] | undefined): string | undefined {
  if (Array.isArray(value)) {
    const found = value.find((item) => item.trim().length > 0);
    return found?.trim();
  }
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

export function safeTokenEqual(provided: string, expected: string): boolean {
  const providedBytes = Buffer.from(provided);
  const expectedBytes = Buffer.from(expected);
  return (
    providedBytes.length === expectedBytes.length &&
    timingSafeEqual(providedBytes, expectedBytes)
  );
}

function bearerToken(authorization: string | undefined): string | undefined {
  if (!authorization) {
    return undefined;
  }
  const match = /^Bearer\s+(.+)$/iu.exec(authorization);
  const provided = match?.[1]?.trim();
  return provided ? provided : undefined;
}

function matchesAcceptedToken(
  provided: string,
  options: { allowLocalKey: boolean; requireToken?: boolean; token?: string }
): boolean {
  if (options.token && safeTokenEqual(provided, options.token)) {
    return true;
  }
  if (options.requireToken) {
    return false;
  }
  return options.allowLocalKey && safeTokenEqual(provided, LOCAL_CLIPROXY_KEY);
}

export function isAuthorized(
  authorization: string | undefined,
  xApiKey: string | undefined,
  clientIp: string | undefined,
  options: { allowLocalKey: boolean; requireToken?: boolean; token?: string }
): boolean {
  if (!isLoopbackIp(clientIp)) {
    return false;
  }
  const bearer = bearerToken(authorization);
  if (bearer && matchesAcceptedToken(bearer, options)) {
    return true;
  }
  const key = xApiKey?.trim();
  return Boolean(key && matchesAcceptedToken(key, options));
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

export function isLoopbackHttpUrl(raw: string): boolean {
  try {
    const parsed = new URL(raw);
    return parsed.protocol === "http:" && parsed.hostname === "127.0.0.1";
  } catch {
    return false;
  }
}

export function containsUnsafeDisplayText(text: string): boolean {
  if (text.toLowerCase().includes("localhost")) {
    return true;
  }
  const matches = text.match(/https?:\/\/[^\s"'`<>]+/giu) ?? [];
  return matches.some((raw) => !isLoopbackHttpUrl(raw));
}

export function openaiGatewayUrl(port: number): string {
  return `http://${DEFAULT_PROXY_HOST}:${port}/v1`;
}

export function anthropicGatewayUrl(port: number): string {
  return `http://${DEFAULT_PROXY_HOST}:${port}`;
}
