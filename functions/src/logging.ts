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

// Patterns for PII and sensitive data scrubbing
const SCRUB_PATTERNS: Array<[RegExp, string]> = [
  // Email addresses
  [/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/g, "[email]"],
  // IPv4 addresses
  [/\b(\d{1,3}\.){3}\d{1,3}\b/g, "[ip]"],
  // API keys / bearer tokens (long alphanumeric strings with known prefixes)
  // Note: Stripe sk-, Google AIza, Google OAuth ya29., JWT eyJ headers
  [/\b(sk-|AIza|ya29\.|eyJ)[A-Za-z0-9\-_.+/]{20,}/g, "[REDACTED]"],
  // Credit card-like numbers (16 digits, optional separators)
  [/\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b/g, "[REDACTED]"],
  // NOTE: Firebase Auth UIDs (28-char alphanumeric) are handled by key-based
  // logic in scrubFields, NOT by regex, to avoid false-positives on
  // correlation IDs, git hashes, and other 28-char tokens.
];

const MAX_FIELD_LENGTH = 1024;
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
  return result;
}

export type LogFieldValue =
  | string
  | number
  | boolean
  | null
  | undefined
  | LogFieldValue[]
  | { [key: string]: LogFieldValue };

function isLogFieldRecord(value: LogFieldValue): value is { [key: string]: LogFieldValue } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function scrubValue(key: string, value: LogFieldValue): LogFieldValue {
  if (typeof value === "string") {
    // Never log raw UIDs — always hash/truncate
    if (key === "uid" || key === "userId" || key === "user_id") {
      return value.slice(0, 8);
    }
    if (isSensitiveLogKey(key)) {
      return "[REDACTED]";
    }
    return scrubString(value);
  }
  if (Array.isArray(value)) {
    return value.map((item) => scrubValue(key, item));
  }
  if (isLogFieldRecord(value)) {
    return scrubFields(value);
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

export interface LogFields {
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
 * Production callable factory: v2 onCall + structured logs + Sentry capture.
 * Prefer for new exports; existing exports can keep onCall(..., wrapCallableHandler(...)).
 */
export function onCallProduction<Data, R>(
  name: string,
  options: CallableOptions,
  handler: (request: CallableRequest<Data>) => Promise<R>,
) {
  return onCall(options, wrapCallableHandler(name, handler));
}
