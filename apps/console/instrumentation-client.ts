/**
 * Client-side Sentry initialization for the BurnBar console.
 *
 * `instrumentation-client.ts` is the modern Next.js entry point (replaces the
 * legacy `sentry.client.config.ts`); Next runs it before hydration so browser
 * crashes — including ones before React mounts — are captured. The console ships
 * as a static export (`output: export`), so this client SDK is the primary
 * observability surface: a member's browser crash was previously invisible.
 *
 * No-op unless `NEXT_PUBLIC_SENTRY_DSN` is set (see `lib/sentry/options.ts`),
 * so local dev and no-DSN deploys stay dark.
 */
import * as Sentry from "@sentry/nextjs";
import { sharedSentryOptions } from "@/lib/sentry/options";

Sentry.init({
  ...sharedSentryOptions,

  // Browser stack traces can embed OS paths; the source is inlined here, but the
  // scrubber in `beforeSend` is the real guard. Session Replay is intentionally
  // NOT enabled — replay would capture the member's private data screens.
  integrations: [],
  replaysSessionSampleRate: 0,
  replaysOnErrorSampleRate: 0,
});

// Instrument App Router client-side navigations (modern SDK hook).
export const onRouterTransitionStart = Sentry.captureRouterTransitionStart;
