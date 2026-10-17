/**
 * Linq → Afar edge contract (`linq-afar-edge/1`).
 *
 * `POST /linq/afar` accepts one Standard Webhooks delivery from Linq, proves it
 * is authentic and fresh, checks it belongs to the configured Afar binding,
 * and publishes the ORIGINAL raw body to one Pub/Sub topic. The Studio Node
 * pulls that topic outbound and re-verifies everything itself; nothing here is
 * trusted by the Node beyond transport.
 *
 * This module holds the frozen wire limits, the event table and the pure
 * parsers for configuration and the signed body. It performs no I/O.
 */

/** Identifier stamped on every published message. */
export const EDGE_CONTRACT_ID = "linq-afar-edge/1";

/** Largest accepted raw body, in bytes. Also the largest Pub/Sub `data`. */
export const MAX_BODY_BYTES = 65_536;
/** Total handler budget from entry to response. */
export const HANDLER_DEADLINE_MS = 9_000;
/** Allowed distance between `webhook-timestamp` and the edge clock. */
export const FRESHNESS_WINDOW_SECONDS = 300;
/** Ceiling on concurrent in-flight requests per instance. */
export const ADMISSION_LIMIT = 4;
/** Seconds a client should wait after a 503. */
export const RETRY_AFTER_SECONDS = 5;

export const MAX_WEBHOOK_ID_BYTES = 256;
export const MAX_WEBHOOK_SIGNATURE_BYTES = 1_024;
export const MAX_ATTRIBUTES_BYTES = 1_536;
export const MAX_EVENT_ID_BYTES = 256;

/** Instance ceilings for the eventual `onRequest` export. Admission limits, not cost guarantees. */
export const EDGE_INSTANCE_LIMITS = Object.freeze({ minInstances: 0, maxInstances: 1, concurrency: ADMISSION_LIMIT });

/** The exactly five Pub/Sub attributes, in publication order. */
export const ATTRIBUTE_NAMES = Object.freeze([
  "webhook-id",
  "webhook-timestamp",
  "webhook-signature",
  "edge-contract",
  "edge-received-at",
] as const);

export type AttributeName = (typeof ATTRIBUTE_NAMES)[number];
export type EdgeAttributes = Readonly<Record<AttributeName, string>>;

export const WEBHOOK_VERSION = "2026-02-03";
export const API_VERSION = "v3";

/** Events whose scope is the Afar line that owns the chat. */
const CHAT_LINE_EVENTS = [
  "message.received",
  "message.sent",
  "message.delivered",
  "message.read",
  "message.edited",
  "chat.background_updated",
] as const;
/** Events whose scope is the line named in `data.phone_number`. */
const PHONE_NUMBER_LINE_EVENTS = ["phone_number.status_updated"] as const;
/** Events that carry no line and are scoped to the product. */
const PRODUCT_SCOPE_EVENTS = [
  "message.failed",
  "reaction.added",
  "reaction.removed",
  "chat.background_update_failed",
  "api_token.expiry_scheduled",
  "api_token.expired",
] as const;

export type EventType =
  | (typeof CHAT_LINE_EVENTS)[number]
  | (typeof PHONE_NUMBER_LINE_EVENTS)[number]
  | (typeof PRODUCT_SCOPE_EVENTS)[number];

type ScopeRule = "chat-owner-line" | "phone-number-line" | "product";

const EVENT_SCOPE_RULES: ReadonlyMap<string, ScopeRule> = new Map<string, ScopeRule>([
  ...CHAT_LINE_EVENTS.map((type): [string, ScopeRule] => [type, "chat-owner-line"]),
  ...PHONE_NUMBER_LINE_EVENTS.map((type): [string, ScopeRule] => [type, "phone-number-line"]),
  ...PRODUCT_SCOPE_EVENTS.map((type): [string, ScopeRule] => [type, "product"]),
]);

/** The frozen set of thirteen supported event types. */
export const SUPPORTED_EVENT_TYPES: readonly string[] = Object.freeze([...EVENT_SCOPE_RULES.keys()]);

const E164 = /^\+[1-9][0-9]{1,14}$/;
const TOPIC_NAME = /^projects\/[a-z][a-z0-9-]{4,28}[a-z0-9]\/topics\/[A-Za-z][A-Za-z0-9._~+%-]{2,254}$/;
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const SECRET_PREFIX = "whsec_";
const MIN_SECRET_BYTES = 24;
const MAX_SECRET_BYTES = 64;

/** Validated runtime binding. There are no defaults: an absent binding means the edge answers 503. */
export interface LinqAfarEdgeConfig {
  /** Fully qualified topic, `projects/{project}/topics/{topic}`. */
  readonly topic: string;
  /** Decoded Standard Webhooks signing key. */
  readonly signingKey: Buffer;
  /** E.164 numbers of the approved Afar lines. */
  readonly approvedLines: ReadonlySet<string>;
}

/** Returns the current binding, or null while the edge is not configured. */
export type LinqAfarEdgeConfigSource = () => LinqAfarEdgeConfig | null;

/** Production source until activation binds real configuration: always unavailable. */
export const unavailableLinqAfarEdgeConfig: LinqAfarEdgeConfigSource = () => null;

export type ConfigResult = { readonly ok: true; readonly config: LinqAfarEdgeConfig } | { readonly ok: false; readonly error: string };

export function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const proto: unknown = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}

export function utf8Bytes(text: string): number {
  return Buffer.byteLength(text, "utf8");
}

/** Strictly decode canonical padded base64; null when the text is not canonical. */
export function decodeStrictBase64(text: string): Buffer | null {
  if (text.length === 0 || !BASE64.test(text)) return null;
  const bytes = Buffer.from(text, "base64");
  return bytes.toString("base64") === text ? bytes : null;
}

/** Validate an explicit binding, for activation wiring and for tests. */
export function parseLinqAfarEdgeConfig(input: unknown): ConfigResult {
  if (!isPlainObject(input)) return { ok: false, error: "config must be an object" };
  const { topic, signingSecret, approvedLines } = input;
  if (typeof topic !== "string" || !TOPIC_NAME.test(topic)) {
    return { ok: false, error: "topic must be projects/{project}/topics/{topic}" };
  }
  if (typeof signingSecret !== "string" || !signingSecret.startsWith(SECRET_PREFIX)) {
    return { ok: false, error: "signingSecret must be a whsec_ secret" };
  }
  const signingKey = decodeStrictBase64(signingSecret.slice(SECRET_PREFIX.length));
  if (signingKey === null || signingKey.length < MIN_SECRET_BYTES || signingKey.length > MAX_SECRET_BYTES) {
    return { ok: false, error: `signingSecret must decode to ${MIN_SECRET_BYTES}-${MAX_SECRET_BYTES} bytes` };
  }
  if (!Array.isArray(approvedLines) || approvedLines.length === 0) {
    return { ok: false, error: "approvedLines must be a non-empty array" };
  }
  const lines = new Set<string>();
  for (const line of approvedLines) {
    if (typeof line !== "string" || !E164.test(line)) return { ok: false, error: "approvedLines must hold E.164 numbers" };
    if (lines.has(line)) return { ok: false, error: `approvedLines lists ${line} twice` };
    lines.add(line);
  }
  return { ok: true, config: Object.freeze({ topic, signingKey, approvedLines: lines }) };
}

/** Non-null scope key: `line:+E164` for line events, `product` otherwise. */
export type ScopeKey = `line:${string}` | "product";

export type EventResult =
  | { readonly kind: "accepted"; readonly eventId: string; readonly eventType: string; readonly scopeKey: ScopeKey }
  | { readonly kind: "malformed"; readonly reason: string }
  | { readonly kind: "unbound"; readonly reason: string };

const UTF8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

function malformed(reason: string): EventResult {
  return { kind: "malformed", reason };
}

/**
 * Parse the already-verified raw body and resolve its scope against the
 * binding. Called only after the signature and freshness checks pass.
 */
export function parseAfarEvent(rawBody: Uint8Array, config: LinqAfarEdgeConfig): EventResult {
  let text: string;
  try {
    text = UTF8.decode(rawBody);
  } catch {
    return malformed("body is not valid UTF-8");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return malformed("body is not JSON");
  }
  if (!isPlainObject(parsed)) return malformed("body must be a JSON object");

  const { event_id: eventId, event_type: eventType, webhook_version: webhookVersion, data, created_at: createdAt } = parsed;
  if (typeof eventId !== "string" || eventId.length === 0 || utf8Bytes(eventId) > MAX_EVENT_ID_BYTES) {
    return malformed("event_id must be a non-empty string of at most 256 UTF-8 bytes");
  }
  if (typeof eventType !== "string") return malformed("event_type must be a string");
  const rule = EVENT_SCOPE_RULES.get(eventType);
  if (rule === undefined) return malformed("event_type is not supported");
  if (webhookVersion !== WEBHOOK_VERSION) return malformed(`webhook_version must be ${WEBHOOK_VERSION}`);
  if (Object.hasOwn(parsed, "api_version") && parsed.api_version !== API_VERSION) {
    return malformed(`api_version must be absent or ${API_VERSION}`);
  }
  if (!isPlainObject(data)) return malformed("data must be an object");
  // The Node adapter owns created_at semantics; the edge only requires it to be present.
  if (typeof createdAt !== "string" || createdAt.length === 0) return malformed("created_at must be a non-empty string");

  if (rule === "product") return { kind: "accepted", eventId, eventType, scopeKey: "product" };

  let line: unknown;
  if (rule === "chat-owner-line") {
    const chat = data.chat;
    const owner = isPlainObject(chat) ? chat.owner_handle : undefined;
    line = isPlainObject(owner) ? owner.handle : undefined;
  } else {
    line = data.phone_number;
  }
  if (typeof line !== "string" || !E164.test(line)) {
    return malformed(rule === "chat-owner-line" ? "data.chat.owner_handle.handle must be E.164" : "data.phone_number must be E.164");
  }
  if (!config.approvedLines.has(line)) return { kind: "unbound", reason: "line is not an approved Afar line" };
  return { kind: "accepted", eventId, eventType, scopeKey: `line:${line}` };
}
