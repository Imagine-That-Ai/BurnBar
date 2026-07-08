/**
 * Server-runtime Sentry initialization for the BurnBar console.
 *
 * The console deploys as a static export, so there is no long-lived Node server
 * in production; this still initializes Sentry for the Node runtime used by
 * `next dev` and by server-component rendering during `next build`, keeping
 * server-side render errors observable. No-op unless a DSN is configured.
 */
import * as Sentry from "@sentry/node";
import { sharedSentryOptions } from "@/lib/sentry/options";

Sentry.init({
  ...sharedSentryOptions,
});
