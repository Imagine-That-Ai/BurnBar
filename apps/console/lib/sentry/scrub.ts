/**
 * Sentry PII/secret scrubber for the BurnBar console (app.burnbar.ai).
 *
 * The console is a private *member* surface — a client crash report must never
 * carry credentials, auth tokens, emails, local paths, or request bodies out of
 * the member's browser. This mirrors the discipline already shipped on the six
 * server surfaces (see `functions/src/sentry.ts` and
 * `extensions/openburnbar/src/telemetry/sentry.ts`): `sendDefaultPii: false`,
 * a `beforeSend` sanitizer, breadcrumb URL redaction, and a one-way-hashed UID.
 *
 * Kept framework-agnostic and side-effect free so the same scrubber is shared by
 * the client, server, and edge Sentry init files.
 */
import type { ErrorEvent, EventHint, Breadcrumb } from "@sentry/nextjs";

const REDACTED = "[REDACTED]";

// Keys whose *presence* means the value is sensitive — redact wholesale.
const SENSITIVE_KEY_PATTERN =
  /(?:authorization|cookie|set-cookie|token|secret|password|passphrase|api[-_]?key|credential|private[-_]?key|session|dsn)/i;
// Request-body-shaped keys: never egress raw request/response payloads.
const REQUEST_BODY_KEY_PATTERN = /^(?:body|rawBody|requestBody|requestData|data|payload)$/i;

// Value-level patterns (mirrors functions/src/sentry.ts).
const AUTH_HEADER_VALUE_PATTERN = /\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi;
const SECRET_TOKEN_VALUE_PATTERN =
  /\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|(?:sk|rk)_(?:live|test)_[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{16,}|AIza[0-9A-Za-z_-]{20,})\b/g;
const STRUCTURED_SECRET_ASSIGNMENT_PATTERN =
  /(["']?)\b(access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|apikey|secret|password|credential|dsn)\b\1(\s*[:=]\s*)(["'])(?:\\.|[^\\])*?\4/gi;
const SECRET_ASSIGNMENT_PATTERN =
  /(\b(?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|apikey|secret|password|credential|dsn)\b\s*[:=]\s*)([^\s"'`,;|)]+)/gi;
const EMAIL_PATTERN = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi;
// Browsers surface OS paths in stack frames / File System Access API errors.
const LOCAL_PATH_PATTERN =
  /(?<![\w.-])(?:\/Users|\/home|\/private\/var|\/var\/folders|\/tmp|\/private\/tmp|[A-Za-z]:\\Users)\/?[^\s"'`<>|)]{2,}/g;
const URL_USERINFO_PATTERN = /\b([a-z][a-z0-9+.-]*:\/\/)([^/\s:@]+(?::[^@\s/]+)?@)/gi;

const SENSITIVE_QUERY_KEYS = new Set([
  "token",
  "key",
  "secret",
  "password",
  "code",
  "credential",
  "access_token",
  "refresh_token",
  "id_token",
  "api_key",
  "apikey",
  "dsn",
]);
const SENSITIVE_QUERY_KEY_PATTERN = /(^|[_-])(token|key|secret|password|code|credential|dsn)($|[_-])|api[_-]?key/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSensitiveQueryKey(key: string): boolean {
  let normalized = key.toLowerCase();
  try {
    normalized = decodeURIComponent(key.replace(/\+/g, " ")).toLowerCase();
  } catch {
    // Fall back to the raw key when percent-decoding is malformed.
  }
  return SENSITIVE_QUERY_KEYS.has(normalized) || SENSITIVE_QUERY_KEY_PATTERN.test(normalized);
}

function redactURLSecrets(value: string): string {
  return value.replace(/([?&])([^=&#\s]+)=([^&#\s]+)/g, (match, separator: string, key: string) =>
    isSensitiveQueryKey(key) ? `${separator}${key}=${REDACTED}` : match,
  );
}

function redactSensitiveText(value: string): string {
  return redactURLSecrets(value.replace(URL_USERINFO_PATTERN, `$1${REDACTED}@`))
    .replace(AUTH_HEADER_VALUE_PATTERN, `$1 ${REDACTED}`)
    .replace(SECRET_TOKEN_VALUE_PATTERN, REDACTED)
    .replace(
      STRUCTURED_SECRET_ASSIGNMENT_PATTERN,
      (_match, keyQuote: string, key: string, separator: string, valueQuote: string) =>
        `${keyQuote}${key}${keyQuote}${separator}${valueQuote}${REDACTED}${valueQuote}`,
    )
    .replace(SECRET_ASSIGNMENT_PATTERN, `$1${REDACTED}`)
    .replace(EMAIL_PATTERN, "[REDACTED-EMAIL]")
    .replace(LOCAL_PATH_PATTERN, "[REDACTED-PATH]");
}

function sanitizeValue(value: unknown, depth = 0): unknown {
  if (depth > 8) {
    return "[MaxDepth]";
  }
  if (Array.isArray(value)) {
    return value.map((entry) => sanitizeValue(entry, depth + 1));
  }
  if (!isRecord(value)) {
    return typeof value === "string" ? redactSensitiveText(value) : value;
  }

  const sanitized: Record<string, unknown> = {};
  for (const [key, child] of Object.entries(value)) {
    if (SENSITIVE_KEY_PATTERN.test(key) || REQUEST_BODY_KEY_PATTERN.test(key)) {
      sanitized[key] = REDACTED;
    } else {
      sanitized[key] = sanitizeValue(child, depth + 1);
    }
  }
  return sanitized;
}

function sanitizeHeaders(headers: Record<string, unknown>): Record<string, string> {
  const sanitized: Record<string, string> = {};
  for (const [key, value] of Object.entries(headers ?? {})) {
    sanitized[key] = SENSITIVE_KEY_PATTERN.test(key) ? REDACTED : redactSensitiveText(String(value));
  }
  return sanitized;
}

function scrubRequest(request: NonNullable<ErrorEvent["request"]>): void {
  if (typeof request.url === "string") {
    request.url = redactURLSecrets(request.url);
  }
  delete request.data;
  delete request.cookies;
  delete request.env;
  delete request.query_string;
  if (request.headers && isRecord(request.headers)) {
    request.headers = sanitizeHeaders(request.headers);
  }
}

/**
 * Final egress guard for a Sentry error event. Strips request bodies/cookies,
 * redacts secret/PII-shaped keys and values across extra/contexts/breadcrumbs,
 * and redacts secrets from breadcrumb URLs. Safe to call on every event.
 */
export function sanitizeSentryEvent(event: ErrorEvent): ErrorEvent {
  if (event.request) {
    scrubRequest(event.request);
  }
  if (event.extra) {
    const sanitized = sanitizeValue(event.extra);
    if (isRecord(sanitized)) event.extra = sanitized;
  }
  if (event.contexts) {
    for (const key of Object.keys(event.contexts)) {
      if (SENSITIVE_KEY_PATTERN.test(key) || REQUEST_BODY_KEY_PATTERN.test(key)) {
        delete event.contexts[key];
        continue;
      }
      const sanitized = sanitizeValue(event.contexts[key]);
      if (isRecord(sanitized)) {
        event.contexts[key] = sanitized;
      } else {
        delete event.contexts[key];
      }
    }
  }
  if (event.breadcrumbs) {
    event.breadcrumbs = event.breadcrumbs.map((breadcrumb) => sanitizeBreadcrumb(breadcrumb));
  }
  return event;
}

/** Breadcrumb scrubber: redact secrets from URLs and any copied data fields. */
export function sanitizeBreadcrumb(breadcrumb: Breadcrumb): Breadcrumb {
  if (breadcrumb.data && isRecord(breadcrumb.data)) {
    if (typeof breadcrumb.data.url === "string") {
      breadcrumb.data.url = redactURLSecrets(breadcrumb.data.url);
    }
    const sanitized = sanitizeValue(breadcrumb.data);
    if (isRecord(sanitized)) breadcrumb.data = sanitized as typeof breadcrumb.data;
  }
  if (typeof breadcrumb.message === "string") {
    breadcrumb.message = redactSensitiveText(breadcrumb.message);
  }
  return breadcrumb;
}

/**
 * `beforeSend` hook shared by every runtime. Drops expected noise (rate limits,
 * ResizeObserver churn) and then runs the sanitizer as the final guard.
 */
export function beforeSend(event: ErrorEvent, _hint?: EventHint): ErrorEvent | null {
  const message = typeof event.message === "string" ? event.message : "";
  // ResizeObserver loop warnings are benign browser noise, not actionable bugs.
  if (message.includes("ResizeObserver loop")) {
    return null;
  }
  // Rate-limit errors are expected under load (mirrors functions/src/sentry.ts).
  if (message.includes("rate limit") || message.includes("RESOURCE_EXHAUSTED")) {
    return null;
  }
  return sanitizeSentryEvent(event);
}

// Re-export helpers for unit tests / any direct callers.
export const __testing = { redactSensitiveText, redactURLSecrets, sanitizeValue };
