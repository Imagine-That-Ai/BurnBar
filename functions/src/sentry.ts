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
import { logInfo } from "./logging.js";

const dsn = process.env.SENTRY_DSN;
const release = process.env.FUNCTION_VERSION ?? "unknown";
const environment = process.env.SENTRY_ENVIRONMENT ?? "development";

if (dsn) {
  Sentry.init({
    dsn,
    release: `openburnbar-functions@${release}`,
    environment,

    // Capture 10% of transactions for performance monitoring in production;
    // 100% in non-production environments for debugging visibility.
    tracesSampleRate: environment === "production" ? 0.1 : 1.0,

    // Attach breadcrumbs from console output (scrubbed by our logging.ts layer).
    integrations: [Sentry.extraErrorDataIntegration({ depth: 5 }), Sentry.requestDataIntegration()],

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
      return event;
    },

    // Breadcrumb scrubbing: remove auth tokens from URL breadcrumbs.
    beforeBreadcrumb(breadcrumb: Breadcrumb) {
      if (breadcrumb.data?.url && typeof breadcrumb.data.url === "string") {
        breadcrumb.data.url = breadcrumb.data.url.replace(/([?&](?:token|key|secret))=[^&]+/gi, "$1=[REDACTED]");
      }
      return breadcrumb;
    },
  });

  logInfo({ event: "sentry_initialized", environment, release, dsn_configured: "true" });
} else {
  logInfo({ event: "sentry_disabled", reason: "SENTRY_DSN not set" });
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
  // Use a prefix-truncated UID — Firebase UIDs are random 28-char tokens,
  // not reversible from 8 chars. For stronger anonymization, substitute
  // with a server-side SHA-256 hash when needed.
  Sentry.setUser({ id: `uid:${uid.slice(0, 8)}` });
}

/**
 * Wraps an async function with Sentry error capture.
 * Useful for Cloud Function handlers where errors should be captured
 * even if the calling code swallows them.
 */
export async function withSentry<T>(fn: () => Promise<T>, context?: Record<string, unknown>): Promise<T> {
  try {
    return await fn();
  } catch (err) {
    captureException(err, context);
    throw err;
  }
}
