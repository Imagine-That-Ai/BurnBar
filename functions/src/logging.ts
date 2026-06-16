/**
 * Structured Cloud Functions logging with trace correlation and PII scrubbing.
 *
 * All log fields are scrubbed before emission:
 *   - Email addresses → "[email]"
 *   - IP addresses → "[ip]"
 *   - Firebase UIDs are truncated to first 8 characters (user_id_hash)
 *   - API keys and tokens are masked to "[REDACTED]"
 *   - String values > 1024 chars are truncated to prevent log injection
 */

import { randomUUID } from "node:crypto";
import { onCall, type CallableOptions, type CallableRequest } from "firebase-functions/v2/https";

import type { CallableRateLimit } from "./callables/publicRateLimit.js";

// Patterns for PII and sensitive data scrubbing
const SCRUB_PATTERNS: Array<[RegExp, string]> = [
  // Email addresses
  [/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/g, "[email]"],
  // IPv4 addresses
  [/\b(\d{1,3}\.){3}\d{1,3}\b/g, "[ip]"],
  // API keys / bearer tokens (long alphanumeric strings with known prefixes).
  // Provider token shapes covered:
  //   - Stripe live/test secret + restricted keys: sk-, sk_live_, sk_test_, rk_live_, rk_test_
  //   - Anthropic: sk-ant-
  //   - xAI (Grok): xai-
  //   - OpenAI project/service keys: sk-proj-, sk-svcacct- (subsumed by sk-)
  //   - Google API: AIza
  //   - Google OAuth refresh/access: ya29.
  //   - GitHub PATs / app tokens: ghp_, gho_, ghu_, ghs_, ghr_, github_pat_
  //   - Slack: xox[baprs]-
  //   - Google service-account / generic JWT headers: eyJ
  // The leading word boundary is intentionally dropped for prefixes that
  // contain a non-word char before alphanumerics (e.g. `sk-ant-`) so the
  // longer, more specific shapes still match inside larger strings.
  [
    /(sk-ant-|sk-proj-|sk-svcacct-|sk_live_|sk_test_|rk_live_|rk_test_|sk-|xai-|AIza|ya29\.|gh[opusr]_|github_pat_|xox[baprs]-|eyJ)[A-Za-z0-9\-_.+/]{16,}/g,
    "[REDACTED]",
  ],
  // Credit card-like numbers (16 digits, optional separators)
  [/\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b/g, "[REDACTED]"],
  // NOTE: Firebase Auth UIDs (28-char alphanumeric) are handled by key-based
  // logic in scrubFields, NOT by regex, to avoid false-positives on
  // correlation IDs, git hashes, and other 28-char tokens.
];

const MAX_FIELD_LENGTH = 1024;

// Firebase Auth UIDs embedded inside Firestore-path-shaped string VALUES.
// The key-name UID truncation in `scrubValue` only catches `uid`/`userId`/
// `user_id` KEYS; a UID inside a path or free-form string value (e.g.
// `document_path`, `sourcePath`, a `message`, or a raw `String(error)`) would
// otherwise leak the full 28-char identifier into Cloud Logging.
//
// This is a STRUCTURAL defense-in-depth control (F-RR09-002): it does not rely
// on every call site remembering to log `doc.id` instead of `doc.ref.path`.
// The first path segment after `users/` is always the owner uid in this
// codebase, and `workspaces/workspace-<uid>` embeds it after the prefix. We
// keep the first 8 chars to match the `user_id_hash` correlation convention
// used everywhere else, then append U+2026 so the value is clearly redacted.
//
// Targeted by design: it fires only on these known uid-bearing path shapes, so
// it never mangles git SHAs, trace IDs, or other long tokens (the deliberate
// reason the SCRUB_PATTERNS list avoids a blanket 28-char regex).
function truncateUidSegment(prefix: string, id: string): string {
  return `${prefix}${id.slice(0, 8)}…`;
}

/** Redact UIDs embedded inside Firestore-path-shaped string values. */
function redactUidPaths(value: string): string {
  let result = value;
  result = result.replace(/\busers\/([A-Za-z0-9_-]{9,})/g, (_m, id: string) => truncateUidSegment("users/", id));
  result = result.replace(/\bworkspace-([A-Za-z0-9_-]{9,})/g, (_m, id: string) => truncateUidSegment("workspace-", id));
  return result;
}

function isSensitiveLogKey(key: string): boolean {
  const normalized = key.toLowerCase().replace(/[^a-z0-9]/g, "");
  return (
    normalized.includes("accesstoken") ||
    normalized.includes("apikey") ||
    normalized.includes("authorization") ||
    normalized.includes("bearer") ||
    normalized.includes("cookie") ||
    normalized.includes("password") ||
    normalized.includes("privatekey") ||
    normalized.includes("secret") ||
    normalized.includes("token")
  );
}

/** Scrub a single string value for PII and sensitive data. */
function scrubString(value: string): string {
  let result = value;
  if (result.length > MAX_FIELD_LENGTH) {
    result = result.slice(0, MAX_FIELD_LENGTH) + "...[truncated]";
  }
  for (const [pattern, replacement] of SCRUB_PATTERNS) {
    result = result.replace(pattern, replacement);
  }
  // Defense-in-depth: redact UIDs embedded in path-shaped values regardless of
  // the field key, so a logged `doc.ref.path`/`sourcePath`/`message`/error
  // string cannot leak a full Firebase UID even if a call site forgets.
  result = redactUidPaths(result);
  return result;
}

type LogFieldValue = string | number | boolean | null | undefined | LogFieldValue[] | { [key: string]: LogFieldValue };

function isLogFieldRecord(value: LogFieldValue): value is { [key: string]: LogFieldValue } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function scrubValue(key: string, value: LogFieldValue): LogFieldValue {
  // Sensitive keys redact regardless of value type: a secret/token logged as a
  // number or boolean (or a stringy-coerced primitive) must never pass through
  // just because it is not a `string`. Coerce-then-redact so the allowlist below
  // governs every primitive, not only strings.
  if (isSensitiveLogKey(key) && value !== null && value !== undefined) {
    return "[REDACTED]";
  }
  if (typeof value === "string") {
    // Never log raw UIDs — always hash/truncate
    if (key === "uid" || key === "userId" || key === "user_id") {
      return value.slice(0, 8);
    }
    return scrubString(value);
  }
  if (Array.isArray(value)) {
    return value.map((item) => scrubValue(key, item));
  }
  if (isLogFieldRecord(value)) {
    return scrubFields(value);
  }
  // Coerce-and-scrub the remaining primitives (number, boolean). A number or
  // boolean cannot itself carry an email/IP/token, but stringify-then-scrub keeps
  // the model uniform (allowlist/coerce) and is defensive against a caller that
  // smuggles a secret-shaped token through a non-string primitive — scrubString
  // is a no-op for ordinary numerics, so non-sensitive numbers/booleans still
  // round-trip to their original value via the JSON number/boolean type.
  if (typeof value === "number" || typeof value === "boolean") {
    const scrubbed = scrubString(String(value));
    return scrubbed === String(value) ? value : scrubbed;
  }
  return value;
}

/** Recursively scrub all string values in a log payload. */
function scrubFields(obj: { [key: string]: LogFieldValue }): { [key: string]: LogFieldValue } {
  const scrubbed: { [key: string]: LogFieldValue } = {};
  for (const [key, value] of Object.entries(obj)) {
    scrubbed[key === "uid" ? "user_id_hash" : key] = scrubValue(key, value);
  }
  return scrubbed;
}

interface LogFields {
  event: string;
  trace_id?: string;
  session_id?: string;
  user_id_hash?: string;
  [key: string]: LogFieldValue;
}

export function logInfo(fields: LogFields): void {
  const payload = scrubFields({
    severity: "INFO",
    trace_id: fields.trace_id ?? randomUUID(),
    ...fields,
  });
  console.log(JSON.stringify(payload));
}

export function logError(fields: LogFields & { error?: string }): void {
  const payload = scrubFields({
    severity: "ERROR",
    trace_id: fields.trace_id ?? randomUUID(),
    ...fields,
  });
  console.error(JSON.stringify(payload));
}

export function logWarn(fields: LogFields): void {
  const payload = scrubFields({
    severity: "WARNING",
    trace_id: fields.trace_id ?? randomUUID(),
    ...fields,
  });
  console.warn(JSON.stringify(payload));
}

export function traceIdFromCallableRequest(request: { rawRequest?: { headers?: Record<string, unknown> } }): string {
  const headers = request.rawRequest?.headers;
  const incoming = headers?.["x-cloud-trace-context"] ?? headers?.["x-trace-id"];
  if (typeof incoming === "string" && incoming.trim().length > 0) {
    return incoming.split("/")[0]?.trim() || randomUUID();
  }
  return randomUUID();
}

export function logCallableStart(name: string, traceId: string, uid?: string): void {
  logInfo({
    event: "callable_start",
    callable: name,
    trace_id: traceId,
    user_id_hash: uid?.slice(0, 8),
  });
}

export function logCallableSuccess(name: string, traceId: string, uid?: string): void {
  logInfo({
    event: "callable_success",
    callable: name,
    trace_id: traceId,
    user_id_hash: uid?.slice(0, 8),
  });
}

export function logCallableFailure(name: string, traceId: string, error: unknown, uid?: string): void {
  logError({
    event: "callable_error",
    callable: name,
    trace_id: traceId,
    user_id_hash: uid?.slice(0, 8),
    error: String(error),
  });
}

export async function withCallableLogging<T>(
  name: string,
  request: { rawRequest?: { headers?: Record<string, unknown> } },
  uid: string | undefined,
  handler: (traceId: string) => Promise<T>,
): Promise<T> {
  const traceId = traceIdFromCallableRequest(request);
  logCallableStart(name, traceId, uid);
  try {
    const result = await handler(traceId);
    logCallableSuccess(name, traceId, uid);
    return result;
  } catch (error) {
    const { captureException, setSentryUser } = await import("./sentry.js");
    if (uid) setSentryUser(uid);
    captureException(error, {
      callable: name,
      trace_id: traceId,
      user_id_hash: uid?.slice(0, 8),
    });
    logCallableFailure(name, traceId, error, uid);
    throw error;
  }
}

/**
 * Wraps a v2 `onCall` handler with callable_start / callable_success / callable_error logs.
 * Use as the second argument to `onCall(options, wrapCallableHandler("name", handler))`.
 */
export function wrapCallableHandler<Data, R>(
  name: string,
  handler: (request: CallableRequest<Data>) => Promise<R>,
): (request: CallableRequest<Data>) => Promise<R> {
  return async (request: CallableRequest<Data>) => {
    const uid = request.auth?.uid;
    if (uid) {
      const { setSentryUser } = await import("./sentry.js");
      setSentryUser(uid);
    }
    return withCallableLogging(name, request, uid, () => handler(request));
  };
}

/**
 * Production callable factory: v2 onCall + structured logs + Sentry capture +
 * optional per-UID/App Check sliding-window rate limit.
 * Prefer for new exports; existing exports can keep onCall(..., wrapCallableHandler(...)).
 */
export function onCallProduction<Data, R>(
  name: string,
  options: CallableOptions & { rateLimit?: CallableRateLimit },
  handler: (request: CallableRequest<Data>) => Promise<R>,
) {
  const { rateLimit, ...callableOptions } = options;
  const rateLimitedHandler = rateLimit
    ? async (request: CallableRequest<Data>) => {
        // Dynamic import keeps logging.ts out of the adminRuntime/publicRateLimit
        // import cycle; checkCallableRateLimit is only loaded when a rate limit
        // is actually configured.
        const { checkCallableRateLimit } = await import("./callables/publicRateLimit.js");
        await checkCallableRateLimit(request.auth?.uid, request.app?.appId, rateLimit);
        return handler(request);
      }
    : handler;
  return onCall(callableOptions, wrapCallableHandler(name, rateLimitedHandler));
}
