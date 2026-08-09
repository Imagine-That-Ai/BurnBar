/**
 * @fileoverview Hardcoded per-million-token USD pricing constants.
 *
 * The canonical pricing surface is the client-bundled model catalog
 * (`OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json`), which is
 * not reachable from the functions runtime. Every USD rate that functions code
 * applies server-side lives here — never inline at the call site — and
 * `__tests__/pricing.test.ts` pins the Kimi rates to the catalog so a catalog
 * price change fails CI instead of silently drifting historical recomputes.
 */

import { calculateTokenCost, flushDomainCorePricingShadowEvidence, priceLegacyKimiUsage } from "./domainCorePricing.js";

export { flushDomainCorePricingShadowEvidence };

type TokenPricingRates = Parameters<typeof calculateTokenCost>[0];
type TokenPricingBuckets = Parameters<typeof calculateTokenCost>[1];
type LegacyKimiPricing = ReturnType<typeof priceLegacyKimiUsage>;

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

/**
 * Per-million-token USD pricing for the public BurnBench assistant default
 * model (`openai/gpt-5.6-luna-pro` via OpenRouter). Lets the `benchAssistant`
 * callable stamp `estimatedCostUSD` on its token-usage record so owner-budget
 * reporting works without round-tripping OpenRouter's separate cost-report
 * endpoint. Contract rates supplied with the BurnBench assistant brief —
 * override via the `BENCH_ASSISTANT_INPUT_PRICE_PER_MTOKEN` /
 * `BENCH_ASSISTANT_OUTPUT_PRICE_PER_MTOKEN` env knobs when the OpenRouter
 * pricing page changes.
 */
export const BENCH_ASSISTANT_DEFAULT_INPUT_PRICE_PER_MTOKEN = 0.1;
export const BENCH_ASSISTANT_DEFAULT_OUTPUT_PRICE_PER_MTOKEN = 0.6;

export function estimateTokenCost(
  rates: TokenPricingRates,
  buckets: TokenPricingBuckets,
  environment: NodeJS.ProcessEnv = process.env,
): number {
  return calculateTokenCost(rates, buckets, () => legacyTokenCost(rates, buckets), environment);
}

export function priceLegacyKimiEvent(
  provider: string,
  model: string,
  buckets: TokenPricingBuckets,
  environment: NodeJS.ProcessEnv = process.env,
): LegacyKimiPricing {
  return priceLegacyKimiUsage(
    provider,
    model,
    buckets,
    () => {
      const isLegacy = provider.toLowerCase() === "kimi" && model.startsWith("chatcmpl-");
      if (!isLegacy) return { isLegacy: false };
      const inputTokens = Math.max(buckets.inputTokens - buckets.cacheCreationTokens - buckets.cacheReadTokens, 0);
      const normalizedBuckets = { ...buckets, inputTokens };
      return {
        isLegacy: true,
        model: LEGACY_KIMI_WIRE_MODEL,
        totalTokens: inputTokens + buckets.outputTokens + buckets.cacheCreationTokens + buckets.cacheReadTokens,
        costUsd: legacyTokenCost(LEGACY_KIMI_WIRE_PRICING, normalizedBuckets),
      };
    },
    environment,
  );
}

function legacyTokenCost(rates: TokenPricingRates, buckets: TokenPricingBuckets): number {
  const cacheCreationRate = rates.cacheCreationPerMToken ?? rates.inputPerMToken;
  return (
    (buckets.inputTokens / 1_000_000) * rates.inputPerMToken +
    (buckets.outputTokens / 1_000_000) * rates.outputPerMToken +
    (buckets.cacheCreationTokens / 1_000_000) * cacheCreationRate +
    (buckets.cacheReadTokens / 1_000_000) * rates.cacheReadPerMToken
  );
}
