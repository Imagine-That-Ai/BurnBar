/**
 * @fileoverview Low-level HTTP plumbing for the BurnBar Cloud Hermes Gateway —
 * request/response adapters, structured error type, content-type + id contracts,
 * and stable JSON canonicalization. Split out of hermesGateway.ts to keep every
 * gateway module under the file-length cap; re-exported from there byte-identically.
 */

import type { Request, Response } from "express";

import { recordOrUndefined } from "../guards.js";
import { isSha256Hex } from "../hermesGateway.js";
import { boundedTrimmedString } from "./shared.js";

type HttpRequest = {
  method?: string;
  path?: string;
  url?: string;
  body?: unknown;
  headers?: Record<string, unknown>;
  ip?: string;
  socket?: { remoteAddress?: string };
  query: Record<string, unknown>;
  get(name: string): string | undefined;
};

type HttpResponse = {
  status(code: number): HttpResponse;
  json(body: unknown): void;
  send(body?: unknown): void;
  set(name: string, value: string): void;
};

// Internal cross-module plumbing types (not schema/wire surface): declared
// module-private and re-exported so sibling gateway modules can import them
// without growing the hand-maintained exported-type budget.
export type { HttpRequest, HttpResponse };

export function toHermesHttpRequest(req: Request): HttpRequest {
  return {
    method: req.method,
    path: req.path,
    url: req.url,
    body: req.body,
    headers: req.headers,
    ip: req.ip,
    socket: { remoteAddress: req.socket?.remoteAddress },
    query: recordOrUndefined(req.query) ?? {},
    get: (name: string) => req.get(name),
  };
}

export function toHermesHttpResponse(res: Response): HttpResponse {
  const response: HttpResponse = {
    status(code: number): HttpResponse {
      res.status(code);
      return response;
    },
    json(body: unknown): void {
      res.json(body);
    },
    send(body?: unknown): void {
      res.send(body);
    },
    set(name: string, value: string): void {
      res.set(name, value);
    },
  };
  return response;
}

interface GatewayHttpError {
  status: number;
  error: string;
  detail?: string;
  // Extra top-level fields merged into the JSON error body by the dispatch
  // writer. Used by structured gates (e.g. the Elder Wand entitlement gate)
  // that must return machine-readable hints — `requiredTier`, `feature` —
  // alongside the canonical `error` string.
  extra?: Record<string, unknown>;
}

export function httpError(
  status: number,
  error: string,
  detail?: string,
  extra?: Record<string, unknown>,
): GatewayHttpError {
  return { status, error, detail, extra };
}

export function isGatewayHttpError(error: unknown): error is GatewayHttpError {
  const record = recordOrUndefined(error);
  return !!record && typeof record.status === "number" && typeof record.error === "string";
}

export function sendJSON(res: HttpResponse, status: number, body: Record<string, unknown>): void {
  res.status(status).json(body);
}

export function setNoStore(res: HttpResponse): void {
  res.set("Cache-Control", "no-store");
}

export function header(req: HttpRequest, name: string): string | undefined {
  const value = req.get(name);
  return typeof value === "string" ? value : undefined;
}

export function gatewayHeader(req: HttpRequest, canonicalName: string, shortName: string): string | undefined {
  return header(req, canonicalName) ?? header(req, shortName);
}

export function gatewayPath(req: HttpRequest): string {
  const path = req.path || new URL(req.url || "/", "https://api.burnbar.ai").pathname;
  return (
    path
      .replace(/^\/burnBarHermesGateway\b/, "")
      .replace(/^\/v1\/hermes-gateway\b/, "")
      .replace(/\/+$/, "") || "/"
  );
}

export function requestBody(req: HttpRequest): Record<string, unknown> {
  return recordOrUndefined(req.body) ?? {};
}

/**
 * Defense-in-depth (T-GW-02): every PoP-signed write route must declare a JSON
 * body. Rejecting any non-`application/json` content type closes
 * simple-request / form-encoded cross-origin POSTs and content-type confusion
 * before the PoP body hash is even computed. A missing content type is treated
 * as a violation — a legitimate signing client always sets it. Parameters after
 * the media type (e.g. `; charset=utf-8`) are allowed.
 */
export function assertJsonWriteContentType(req: HttpRequest): void {
  const contentType = header(req, "content-type");
  const mediaType = (contentType ?? "").split(";")[0]?.trim().toLowerCase() ?? "";
  if (mediaType !== "application/json") {
    throw httpError(415, "unsupported_media_type", "application/json required");
  }
}

/**
 * Allowlist of media types accepted on the (deprecated, gate-disabled) legacy
 * plaintext attachment write path. T-ATT-07: a deny-list silently accepts every
 * NEW dangerous type the moment a browser learns to render it (the original list
 * missed, e.g., `application/pdf` with embedded JS, `text/csv` formula injection,
 * MathML, wasm). An allowlist fails CLOSED: anything not explicitly known-inert
 * is rejected. Sealed (ciphertext) uploads never reach this — their stored type
 * is always `application/octet-stream` and they skip the check entirely.
 */
const LEGACY_ATTACHMENT_ALLOWED_MEDIA_TYPES = new Set([
  "application/octet-stream",
  "application/pdf",
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "image/heic",
  "image/heif",
  "text/plain",
  "audio/mpeg",
  "audio/mp4",
  "audio/aac",
  "audio/wav",
  "video/mp4",
  "video/quicktime",
]);

export function baseAttachmentContentType(contentType: string): string {
  return contentType.split(";")[0]?.trim().toLowerCase() ?? "";
}

export function assertSafeAttachmentContentType(contentType: string): void {
  const mediaType = baseAttachmentContentType(contentType);
  if (!mediaType || !LEGACY_ATTACHMENT_ALLOWED_MEDIA_TYPES.has(mediaType)) {
    throw httpError(400, "unsafe_content_type");
  }
}

/** Exported for tests: true when the legacy plaintext write path would accept `contentType`. */
export function legacyAttachmentContentTypeAllowed(contentType: string): boolean {
  try {
    assertSafeAttachmentContentType(contentType);
    return true;
  } catch {
    return false;
  }
}

// Canonical id length + charset for gateway HTTP identifiers. attachments/finalize
// validates `attachmentId` with this exact contract (cap 160, [A-Za-z0-9_.:-]).
export const HERMES_GATEWAY_HTTP_ID_MAX_LENGTH = 160;
const HERMES_GATEWAY_HTTP_ID_PATTERN = /^[A-Za-z0-9_.:-]+$/u;

export function requiredHttpIdentifier(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, HERMES_GATEWAY_HTTP_ID_MAX_LENGTH, true);
  if (!HERMES_GATEWAY_HTTP_ID_PATTERN.test(value)) {
    throw httpError(400, `invalid_${fieldName}`);
  }
  return value;
}

/**
 * Resolve the id a /messages or /attachments/init write should adopt for its
 * Firestore doc. When the client supplies an id we accept it ONLY if it would
 * also pass the canonical `requiredHttpIdentifier` contract used by
 * /attachments/finalize (and the /actions read path) — same ≤160 cap, same
 * charset. This makes the rules symmetric: an id init adopts is always an id
 * finalize accepts, closing the asymmetry where `safeIdentifier` (no length cap,
 * lossy charset coercion) could mint an id finalize would later reject. A
 * malformed/over-long/absent id falls back to a fresh server-minted token so the
 * happy path (no client id, the common case) is unchanged.
 */
export function adoptedGatewayDocId(rawId: unknown, generateFallback: () => string): string {
  if (typeof rawId === "string") {
    const trimmed = rawId.trim();
    if (
      trimmed.length > 0 &&
      trimmed.length <= HERMES_GATEWAY_HTTP_ID_MAX_LENGTH &&
      HERMES_GATEWAY_HTTP_ID_PATTERN.test(trimmed)
    ) {
      return trimmed;
    }
  }
  return generateFallback();
}

export function requestedAttachmentHash(raw: unknown): string | undefined {
  if (raw == null) return undefined;
  if (!isSha256Hex(raw)) {
    throw httpError(400, "invalid_sha256");
  }
  return raw.trim().toLowerCase();
}

export function stableJSONString(value: unknown): string {
  if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(stableJSONString).join(",")}]`;
  }
  const record = recordOrUndefined(value);
  if (!record) return "{}";
  return `{${Object.entries(record)
    .filter(([, item]) => item !== undefined)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, item]) => `${JSON.stringify(key)}:${stableJSONString(item)}`)
    .join(",")}}`;
}

/**
 * The Elder Wand (wire-compatible plugin id `"fusion"`) is BurnBar's
 * multi-model analysis router. A forwarded chat-completions request opts into it
 * with an OpenRouter-Fusion-shaped plugin block:
 *
 *   { "plugins": [{ "id": "fusion", "enabled": true, "analysis_models": [...],
 *                   "model": "<judge>", "max_tool_calls": 8 }] }
 *
 * This predicate mirrors `ChatCompletionsRequest.activeFusionPlugin` in the
 * Swift daemon gateway: a fusion plugin is ACTIVE when an entry's `id` is
 * `"fusion"` and `enabled` is not explicitly `false` (absent ⇒ on). It reads
 * only the unsealed top-level `plugins` routing block — never the sealed message
 * body — so the gate works on the relay write without opening any ciphertext.
 *
 * HONESTY: this functions gateway is the relay control-plane. A purely-local
 * daemon fusion run over the user's OWN provider keys is licensing-gated
 * client-side and is NOT cryptographically bypass-proof on a Mac the user
 * controls. This server gate covers the relay/hosted path — the boundary where
 * BurnBar-authorized spend actually happens — and nothing more.
 */
export function requestCarriesActiveFusionPlugin(body: Record<string, unknown>): boolean {
  const plugins = body.plugins;
  if (!Array.isArray(plugins)) return false;
  return plugins.some((entry) => {
    const plugin = recordOrUndefined(entry);
    if (!plugin || plugin.id !== "fusion") return false;
    return plugin.enabled !== false;
  });
}
