/**
 * @fileoverview Shared runtime options for OpenBurnBar Cloud Functions v2.
 *
 * `FUNCTIONS_REGION` is the single source of truth for the deployment region.
 * Every `onCall`/`onRequest`/`onDocument*`/`onSchedule` option object and the
 * global `setGlobalOptions({ region })` call in `adminRuntime.ts` reference this
 * constant — never a raw `"us-central1"` literal. A CI guard
 * (`scripts/ci/check-region-literals.mjs`) fails the build on any new raw region
 * literal under `functions/src`.
 *
 * Single-region is the documented, accepted GA decision; the flip-triggers and
 * rationale live in `docs/ARCHITECTURE/region-strategy.md`.
 */

import { defineInt } from "firebase-functions/params";

/**
 * The Cloud Functions deployment region. Defaults to `us-central1` and is
 * overridable via the `FUNCTIONS_REGION` environment variable so emulator/CI
 * and any future region flip stay a one-line change.
 */
export const FUNCTIONS_REGION: string = process.env.FUNCTIONS_REGION ?? "us-central1";

/** Pub/Sub topic configured in Google Play Console for billing RTDN delivery. */
export const GOOGLE_PLAY_RTDN_TOPIC: string = process.env.GOOGLE_PLAY_RTDN_TOPIC ?? "play-billing-notifications";

/**
 * Cold-start mitigation for hot revenue/control paths (A4).
 *
 * Spread `HOT_PATH_OPTIONS` into the option object of a curated allowlist of
 * functions where a first-request cold start would time out a webhook or stall
 * a purchase/connect flow at launch: the Stripe webhook, App Store server
 * notifications, the App Store purchase-binding callable, provider-connect,
 * the CLI-link entry point, and the Hermes gateway.
 *
 * `minInstances` keeps at least one warm instance pinned so these endpoints
 * never pay full cold start on the first request. Firebase deployment
 * parameters resolve `HOT_MIN_INSTANCES` before the function options are
 * finalized; raw `process.env` is intentionally not used because `.env`
 * deployment files are loaded after module discovery. The parameter defaults
 * to `1`; staging sets it to `0`. `concurrency: 40` lets each warm instance
 * absorb bursts without immediately scaling out.
 *
 * Cost tradeoff: each pinned instance bills for idle CPU/memory 24/7. With the
 * current 6-function allowlist that is ~6 always-on instances at the default.
 * Scheduled rollups deliberately stay at `minInstances 0`. See the cold-start
 * SLO note in `docs/runbooks/slos.md`.
 */
const HOT_MIN_INSTANCES = defineInt("HOT_MIN_INSTANCES", {
  default: 1,
  description: "Warm instances for latency-sensitive revenue and control Functions.",
});

export const HOT_PATH_OPTIONS = {
  minInstances: HOT_MIN_INSTANCES,
  concurrency: 40,
} as const;
