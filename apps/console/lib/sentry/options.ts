/**
 * Shared Sentry.init options for the BurnBar console, used by every runtime
 * (client / server / edge). Centralized so the PII posture and sampling stay
 * identical across surfaces — mirroring `functions/src/sentry.ts`.
 *
 * Init is a clean no-op when no DSN is configured (`enabled: false`), so local
 * dev, CI builds, and any deploy without `NEXT_PUBLIC_SENTRY_DSN` never emit
 * events. The DSN is only ever read from env — never hardcoded.
 */
import { beforeSend, sanitizeBreadcrumb } from "./scrub";

/**
 * Public Sentry DSN. `NEXT_PUBLIC_SENTRY_DSN` is inlined into the client bundle
 * (a DSN is a public ingest endpoint, not a secret); `SENTRY_DSN` is the
 * server/edge fallback. When unset, `enabled` is false and Sentry does nothing.
 */
export const SENTRY_DSN: string | undefined =
  process.env.NEXT_PUBLIC_SENTRY_DSN || process.env.SENTRY_DSN || undefined;

/** Deploy environment; defaults to development so prod must set it explicitly. */
export const SENTRY_ENVIRONMENT: string =
  process.env.NEXT_PUBLIC_SENTRY_ENVIRONMENT || process.env.SENTRY_ENVIRONMENT || "development";

/** Release tag, aligned with the analytics `NEXT_PUBLIC_APP_VERSION` convention. */
export const SENTRY_RELEASE = `openburnbar-console@${process.env.NEXT_PUBLIC_APP_VERSION || "console"}`;

const isProduction = SENTRY_ENVIRONMENT === "production";

/**
 * Common `Sentry.init` options for all runtimes. `enabled` gates the whole SDK
 * on DSN presence so a missing DSN is a total no-op (no network, no overhead).
 */
export const sharedSentryOptions = {
  dsn: SENTRY_DSN,
  enabled: Boolean(SENTRY_DSN),
  environment: SENTRY_ENVIRONMENT,
  release: SENTRY_RELEASE,

  // 10% of transactions in production, 100% elsewhere — matches functions.
  tracesSampleRate: isProduction ? 0.1 : 1.0,

  // Never attach cookies/headers/IP/user data by default. `beforeSend` is the
  // final egress guard for anything copied into extra/contexts/breadcrumbs.
  sendDefaultPii: false,

  // Keep the breadcrumb trail terse and scrubbed.
  maxBreadcrumbs: 30,
  beforeBreadcrumb: sanitizeBreadcrumb,
  beforeSend,

  // Only surface SDK debug logging when explicitly opted in.
  debug: process.env.NEXT_PUBLIC_SENTRY_DEBUG === "1",
} as const;
