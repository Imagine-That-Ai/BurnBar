/**
 * Edge-runtime Sentry initialization for the BurnBar console.
 *
 * Loaded only when Next.js runs code in the edge runtime (middleware / edge
 * routes). The console currently ships none, but this keeps the SDK wired if any
 * edge code is added later. No-op unless a DSN is configured.
 */
import * as Sentry from "@sentry/nextjs";
import { sharedSentryOptions } from "@/lib/sentry/options";

Sentry.init({
  ...sharedSentryOptions,
});
