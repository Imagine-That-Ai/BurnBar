/**
 * @fileoverview Hardcoded per-million-token USD pricing constants.
 *
 * The canonical pricing surface is the client-bundled model catalog
 * (`OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/catalog.json`), which is
 * not reachable from the functions runtime. Every USD rate that functions code
 * applies server-side lives here — never inline at the call site — and
 * `__tests__/pricing.test.ts` pins the Kimi rates to the catalog so a catalog
 * price change fails CI instead of silently drifting historical recomputes.
 */

/**
 * Model id substituted for legacy Kimi wire events whose `model` field carries
 * a `chatcmpl-` response id instead of a model name.
 */
export const LEGACY_KIMI_WIRE_MODEL = "kimi-for-coding";

/**
 * Era-pinned USD rates for legacy Kimi `chatcmpl-` wire events.
 *
 * These events were originally priced client-side via the bundled catalog's
 * `kimi-family` rate (provider `moonshot`); server-side recomputes must
 * reproduce that rate exactly so historical rollups stay stable. The catalog
 * entry has no `cacheCreationPerMToken`, and the Swift coster
 * (`ModelPricing.cost`) falls back to the input rate — hence
 * `cacheCreationPerMToken === inputPerMToken`.
 */
export const LEGACY_KIMI_WIRE_PRICING = {
  inputPerMToken: 0.6,
  outputPerMToken: 2.5,
  cacheCreationPerMToken: 0.6,
  cacheReadPerMToken: 0.15,
} as const;

/**
 * Per-million-token USD pricing for the hosted Intelligence Brief default
 * model (`minimax/minimax-m2` via OpenRouter). Lets us stamp
 * `estimatedCostUSD` on the audit + token-usage record so the client's
 * "what did this turn cost?" reporting works without round-tripping through
 * OpenRouter's separate cost-report endpoint. Sourced 2026-05-14 from
 * https://openrouter.ai/minimax/minimax-m2 — keep in sync when the
 * pricing page changes.
 */
export const INSIGHTS_HOSTED_DEFAULT_INPUT_PRICE_PER_MTOKEN = 0.255;
export const INSIGHTS_HOSTED_DEFAULT_OUTPUT_PRICE_PER_MTOKEN = 1.0;
