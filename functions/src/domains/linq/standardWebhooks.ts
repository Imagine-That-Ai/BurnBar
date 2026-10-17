/**
 * Standard Webhooks verification for the Linq → Afar edge.
 *
 * Signed content is `${webhook-id}.${webhook-timestamp}.${raw body}` and each
 * `v1,<base64>` entry in `webhook-signature` is an HMAC-SHA256 of it under the
 * shared secret. Every check here is bounded by the 64 KiB body and 1 KiB
 * header limits, and the HMAC is compared in constant time.
 */
import { createHmac, timingSafeEqual } from "node:crypto";
import {
  ATTRIBUTE_NAMES,
  EDGE_CONTRACT_ID,
  FRESHNESS_WINDOW_SECONDS,
  MAX_ATTRIBUTES_BYTES,
  MAX_WEBHOOK_ID_BYTES,
  MAX_WEBHOOK_SIGNATURE_BYTES,
  decodeStrictBase64,
  utf8Bytes,
  type EdgeAttributes,
} from "./afarEdgeContract.js";

/** Printable ASCII, no spaces or controls. */
const PRINTABLE_ASCII = /^[!-~]+$/;
/** Printable ASCII including single spaces between signature entries. */
const SIGNATURE_HEADER = /^[!-~]+(?: [!-~]+)*$/;
const TIMESTAMP = /^[0-9]{1,12}$/;
const HMAC_BYTES = 32;

export interface WebhookHeaders {
  readonly id: string;
  readonly timestamp: string;
  readonly signature: string;
}

export type HeaderResult = { readonly ok: true; readonly headers: WebhookHeaders } | { readonly ok: false; readonly reason: string };

const WEBHOOK_HEADER_NAMES = ["webhook-id", "webhook-timestamp", "webhook-signature"] as const;

/**
 * Collect each named header from Node's `rawHeaders` (name, value pairs).
 * A header sent more than once is reported as a duplicate rather than joined.
 */
export function collectSingleHeaders(
  rawHeaders: readonly string[],
  names: readonly string[],
): { readonly values: ReadonlyMap<string, string>; readonly duplicate: string | null } {
  const wanted = new Set(names);
  const values = new Map<string, string>();
  for (let index = 0; index + 1 < rawHeaders.length; index += 2) {
    const name = rawHeaders[index].toLowerCase();
    if (!wanted.has(name)) continue;
    if (values.has(name)) return { values, duplicate: name };
    values.set(name, rawHeaders[index + 1]);
  }
  return { values, duplicate: null };
}

/** Extract and bound the three Standard Webhooks headers. */
export function readWebhookHeaders(rawHeaders: readonly string[]): HeaderResult {
  const { values, duplicate } = collectSingleHeaders(rawHeaders, WEBHOOK_HEADER_NAMES);
  if (duplicate !== null) return { ok: false, reason: `${duplicate} sent more than once` };
  const id = values.get("webhook-id");
  const timestamp = values.get("webhook-timestamp");
  const signature = values.get("webhook-signature");
  if (id === undefined || timestamp === undefined || signature === undefined) {
    return { ok: false, reason: "webhook-id, webhook-timestamp and webhook-signature are required" };
  }
  if (!PRINTABLE_ASCII.test(id) || id.length > MAX_WEBHOOK_ID_BYTES) {
    return { ok: false, reason: "webhook-id must be 1-256 printable ASCII bytes" };
  }
  if (!TIMESTAMP.test(timestamp)) return { ok: false, reason: "webhook-timestamp must be 1-12 decimal digits" };
  if (!SIGNATURE_HEADER.test(signature) || signature.length > MAX_WEBHOOK_SIGNATURE_BYTES) {
    return { ok: false, reason: "webhook-signature must be 1-1024 printable ASCII bytes" };
  }
  return { ok: true, headers: { id, timestamp, signature } };
}

/** True when the provider timestamp is within ±300 s of the edge clock. */
export function isFresh(timestamp: string, nowMs: number): boolean {
  const skewSeconds = Math.abs(Math.floor(nowMs / 1000) - Number(timestamp));
  return skewSeconds <= FRESHNESS_WINDOW_SECONDS;
}

/** Constant-time check of every `v1` entry against the expected HMAC; other versions are ignored. */
export function verifySignature(headers: WebhookHeaders, rawBody: Uint8Array, signingKey: Buffer): boolean {
  const expected = createHmac("sha256", signingKey)
    .update(`${headers.id}.${headers.timestamp}.`, "utf8")
    .update(rawBody)
    .digest();
  let matched = false;
  for (const entry of headers.signature.split(" ")) {
    const comma = entry.indexOf(",");
    if (comma < 0 || entry.slice(0, comma) !== "v1") continue;
    const candidate = decodeStrictBase64(entry.slice(comma + 1));
    if (candidate === null || candidate.length !== HMAC_BYTES) continue;
    // Evaluate every entry so timing does not reveal which one matched.
    matched = timingSafeEqual(candidate, expected) || matched;
  }
  return matched;
}

/** Strict ISO-8601 UTC with milliseconds, e.g. `2026-10-17T01:20:01.000Z`. */
export function formatReceivedAt(nowMs: number): string {
  return new Date(nowMs).toISOString();
}

export type AttributesResult = { readonly ok: true; readonly attributes: EdgeAttributes } | { readonly ok: false; readonly reason: string };

/** Build the exactly five published attributes and enforce the combined size bound. */
export function buildEdgeAttributes(headers: WebhookHeaders, verifiedAtMs: number): AttributesResult {
  const attributes: EdgeAttributes = Object.freeze({
    "webhook-id": headers.id,
    "webhook-timestamp": headers.timestamp,
    "webhook-signature": headers.signature,
    "edge-contract": EDGE_CONTRACT_ID,
    "edge-received-at": formatReceivedAt(verifiedAtMs),
  });
  const total = ATTRIBUTE_NAMES.reduce((sum, name) => sum + utf8Bytes(name) + utf8Bytes(attributes[name]), 0);
  if (total > MAX_ATTRIBUTES_BYTES) return { ok: false, reason: "attributes exceed 1536 bytes" };
  return { ok: true, attributes };
}
