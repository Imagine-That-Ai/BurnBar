/**
 * Sentry error tracking for OpenBurnBar Cloud Functions.
 *
 * Initializes Sentry on cold start. Import this module in adminRuntime.ts
 * (or at the top of index.ts) to ensure Sentry captures all unhandled errors.
 *
 * Required environment variables (set via Firebase config or CI secrets):
 *   SENTRY_DSN           — Sentry ingest DSN for the functions project
 *   FUNCTION_VERSION     — injected at deploy time (used as Sentry release)
 *   SENTRY_ENVIRONMENT   — "production" | "staging" | "development"
 *
 * Sentry is gracefully disabled when SENTRY_DSN is unset (e.g., local dev).
 * This prevents noisy test output and avoids sending dev errors to production.
 */

import * as Sentry from "@sentry/node";
import type { ErrorEvent, EventHint, Breadcrumb } from "@sentry/core";
import { createHash } from "node:crypto";
import { logInfo } from "./logging.js";

const dsn = process.env.SENTRY_DSN;
const release = process.env.FUNCTION_VERSION ?? "unknown";
const environment = process.env.SENTRY_ENVIRONMENT ?? "development";
const REDACTED = "[REDACTED]";
const SENSITIVE_KEY_PATTERN =
  /(?:authorization|cookie|set-cookie|token|secret|password|passphrase|api[-_]?key|credential|private[-_]?key|session|dsn)/i;
const REQUEST_BODY_KEY_PATTERN = /^(?:body|rawBody|requestBody|requestData|data|payload)$/i;
const AUTH_HEADER_VALUE_PATTERN = /\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi;
const SECRET_TOKEN_VALUE_PATTERN =
  /\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{16,}|AIza[0-9A-Za-z_-]{20,})\b/g;
const SECRET_ASSIGNMENT_PATTERN =
  /(\b(?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|apikey|secret|password|credential|dsn)\b\s*[:=]\s*)([^\s"'`,;|)]+)/gi;
const EMAIL_PATTERN = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi;
const LOCAL_PATH_PATTERN =
  /(?<![\w.-])(?:\/Users|\/home|\/private\/var|\/var\/folders|\/tmp|\/private\/tmp)\/[^\s"'`<>|)]{2,}/g;

if (dsn) {
  Sentry.init({
    dsn,
    release: `openburnbar-functions@${release}`,
    environment,

    // Capture 10% of transactions for performance monitoring in production;
    // 100% in non-production environments for debugging visibility.
    tracesSampleRate: environment === "production" ? 0.1 : 1.0,

    // Attach extra error fields but never request bodies/headers. The
    // beforeSend sanitizer below is the final guard for copied extras.
    integrations: [Sentry.extraErrorDataIntegration({ depth: 5 })],
    sendDefaultPii: false,

    // Filter events that are noise rather than actionable bugs.
    beforeSend(event: ErrorEvent, _hint: EventHint): ErrorEvent | null {
      // Drop rate-limit errors (429) — these are expected under load.
      const statusCode = typeof event.extra?.statusCode === "number" ? event.extra.statusCode : undefined;
      if (
        statusCode === 429 ||
        (typeof event.message === "string" &&
          (event.message.includes("rate limit") || event.message.includes("RESOURCE_EXHAUSTED")))
      ) {
        return null;
      }
      return sanitizeSentryEvent(event);
    },

    // Breadcrumb scrubbing: remove auth tokens from URL breadcrumbs.
    beforeBreadcrumb(breadcrumb: Breadcrumb) {
      if (breadcrumb.data?.url && typeof breadcrumb.data.url === "string") {
        breadcrumb.data.url = redactURLSecrets(breadcrumb.data.url);
      }
      return breadcrumb;
    },
  });

  logInfo({ event: "sentry_initialized", environment, release, dsn_configured: "true" });
} else {
  logInfo({ event: "sentry_disabled", reason: "SENTRY_DSN not set" });
}

/**
 * Health-surface snapshot of the Sentry configuration (H13). Lets health/probe
 * endpoints report whether crash reporting is actually enabled so a missing
 * SENTRY_DSN in production is caught by the post-deploy gate instead of going
 * dark. Carries no secret: the DSN itself is never exposed, only its presence.
 */
export function sentryStatus(): { enabled: boolean; environment: string } {
  return { enabled: Boolean(dsn), environment };
}

export function sanitizeSentryEvent(event: ErrorEvent): ErrorEvent {
  if (event.request) {
    scrubSentryRequest(event.request);
  }

  if (event.extra) {
    event.extra = sanitizeSentryExtra(event.extra);
  }
  if (event.contexts) {
    event.contexts = sanitizeSentryContexts(event.contexts);
  }
  if (event.breadcrumbs) {
    event.breadcrumbs = event.breadcrumbs.map((breadcrumb) => {
      if (breadcrumb.data) {
        breadcrumb.data = sanitizeBreadcrumbData(breadcrumb.data);
      }
      return breadcrumb;
    });
  }

  return event;
}

function scrubSentryRequest(request: NonNullable<ErrorEvent["request"]>): void {
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

function sanitizeSentryExtra(extra: NonNullable<ErrorEvent["extra"]>): ErrorEvent["extra"] {
  const sanitized = sanitizeSentryValue(extra);
  return isRecord(sanitized) ? sanitized : extra;
}

function sanitizeSentryContexts(contexts: NonNullable<ErrorEvent["contexts"]>): ErrorEvent["contexts"] {
  for (const key of Object.keys(contexts)) {
    if (SENSITIVE_KEY_PATTERN.test(key) || REQUEST_BODY_KEY_PATTERN.test(key)) {
      delete contexts[key];
      continue;
    }
    const sanitized = sanitizeSentryValue(contexts[key]);
    if (isRecord(sanitized)) {
      contexts[key] = sanitized;
    } else {
      delete contexts[key];
    }
  }
  return contexts;
}

function sanitizeBreadcrumbData(data: NonNullable<Breadcrumb["data"]>): Breadcrumb["data"] {
  const sanitized = sanitizeSentryValue(data);
  return isRecord(sanitized) ? sanitized : data;
}

function sanitizeHeaders(headers: Record<string, unknown>) {
  const sanitized: Record<string, string> = {};
  for (const [key, value] of Object.entries(headers ?? {})) {
    sanitized[key] = SENSITIVE_KEY_PATTERN.test(key) ? REDACTED : redactSensitiveText(String(value));
  }
  return sanitized;
}

function sanitizeSentryValue(value: unknown, depth = 0): unknown {
  if (depth > 8) {
    return "[MaxDepth]";
  }
  if (Array.isArray(value)) {
    return value.map((entry) => sanitizeSentryValue(entry, depth + 1));
  }
  if (!isRecord(value)) {
    return typeof value === "string" ? redactSensitiveText(value) : value;
  }

  const sanitized: Record<string, unknown> = {};
  for (const [key, child] of Object.entries(value)) {
    if (SENSITIVE_KEY_PATTERN.test(key) || REQUEST_BODY_KEY_PATTERN.test(key)) {
      sanitized[key] = REDACTED;
    } else {
      sanitized[key] = sanitizeSentryValue(child, depth + 1);
    }
  }
  return sanitized;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function redactURLSecrets(value: string): string {
  return value.replace(
    /([?&](?:token|key|secret|password|code|credential|access_token|refresh_token|id_token|api_key))=[^&#]+/gi,
    `$1=${REDACTED}`,
  );
}

function redactSensitiveText(value: string): string {
  return redactURLSecrets(value)
    .replace(AUTH_HEADER_VALUE_PATTERN, `$1 ${REDACTED}`)
    .replace(SECRET_TOKEN_VALUE_PATTERN, REDACTED)
    .replace(SECRET_ASSIGNMENT_PATTERN, `$1${REDACTED}`)
    .replace(EMAIL_PATTERN, "[REDACTED-EMAIL]")
    .replace(LOCAL_PATH_PATTERN, "[REDACTED-PATH]");
}

/**
 * Captures an exception in Sentry with additional context.
 * Safe to call even if Sentry is not initialized.
 */
export function captureException(err: unknown, context?: Record<string, unknown>): void {
  if (!dsn) return;
  Sentry.withScope((scope) => {
    if (context) {
      scope.setExtras(context);
    }
    Sentry.captureException(err);
  });
}

/**
 * Sets user context on the current Sentry scope.
 * Call this after authenticating a request to enrich error reports.
 * The UID is one-way hashed (first 8 chars of the Firebase Auth UID) to
 * avoid sending PII to Sentry. This is sufficient for grouping, not for
 * re-identification.
 */
export function setSentryUser(uid: string): void {
  if (!dsn) return;
  Sentry.setUser({ id: sentryUserIdForUID(uid) });
}

export function sentryUserIdForUID(uid: string): string {
  const digest = createHash("sha256").update(uid, "utf8").digest("hex").slice(0, 16);
  return `uid:${digest}`;
}
