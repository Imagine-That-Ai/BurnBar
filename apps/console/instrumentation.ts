/**
 * Next.js instrumentation hook — the server/edge entry point for Sentry.
 *
 * `register()` runs once when a Next.js runtime boots and loads the matching
 * Sentry config. `onRequestError` forwards server-side render / route errors to
 * Sentry (nested React Server Component errors that never reach the client).
 * Both are no-ops unless a DSN is configured.
 */
import * as Sentry from "@sentry/nextjs";

export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    await import("./sentry.server.config");
  }
  if (process.env.NEXT_RUNTIME === "edge") {
    await import("./sentry.edge.config");
  }
}

export const onRequestError = Sentry.captureRequestError;
