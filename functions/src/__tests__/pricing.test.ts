/**
 * Regression: legacy Kimi wire pricing pinned to the catalog (crosscut-013).
 *
 * `rollups.ts` reprices legacy Kimi `chatcmpl-` wire events server-side using
 * the hardcoded rates in `pricing.ts`. The canonical rate lives in the
 * client-bundled catalog (provider `moonshot`, model `kimi-family`), which the
 * functions runtime cannot read, so the constants were duplicated by hand and
 * could drift silently. This test re-derives the catalog rate the way the
 * Swift coster (`ModelPricing.cost`) does and fails on any divergence.
 *
 * If this test fails because the catalog rate moved, decide explicitly:
 * legacy events keep the era-correct rate (keep the constant, update the
 * expectation here with a dated note) or follow the catalog (update the
 * constant) — never let the two drift without a recorded decision.
 */
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import {
  LEGACY_KIMI_WIRE_MODEL,
  LEGACY_KIMI_WIRE_PRICING,
  estimateTokenCost,
  priceLegacyKimiEvent,
} from "../pricing.js";
import { calculateTokenCost, DomainCorePricingError, resolveDomainCorePricingMode } from "../domainCorePricing.js";

const CATALOG_PATH = resolve(__dirname, "../../..", "OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/catalog.json");

type Matcher = { all: string[]; any: string[]; none: string[] };
type CatalogModel = {
  id: string;
  matchers?: Matcher[];
  pricing?: {
    inputPerMToken?: number;
    outputPerMToken?: number;
    cacheCreationPerMToken?: number;
    cacheReadPerMToken?: number;
  };
};
type Catalog = { providers: { id: string; models: CatalogModel[] }[] };

// Mirrors BurnBarModelMatcher.matches in OpenBurnBarCatalog.swift.
function matches(matcher: Matcher, normalized: string): boolean {
  const containsAll = matcher.all.every((token) => normalized.includes(token));
  const containsAny = matcher.any.length === 0 || matcher.any.some((token) => normalized.includes(token));
  const containsNone = matcher.none.every((token) => !normalized.includes(token));
  return containsAll && containsAny && containsNone;
}

function isCatalog(value: unknown): value is Catalog {
  if (!value || typeof value !== "object") return false;
  const providers = Object.getOwnPropertyDescriptor(value, "providers")?.value;
  return Array.isArray(providers);
}

function loadMoonshotModels(): CatalogModel[] {
  const parsed: unknown = JSON.parse(readFileSync(CATALOG_PATH, "utf8"));
  if (!isCatalog(parsed)) throw new Error("invalid catalog fixture");
  const catalog = parsed;
  const moonshot = catalog.providers.find((provider) => provider.id === "moonshot");
  expect(moonshot).toBeDefined();
  if (!moonshot) throw new Error("moonshot provider missing from the catalog fixture");
  return moonshot.models;
}

describe("legacy kimi wire pricing", () => {
  it("routes the rewritten model id to kimi-family in the catalog", () => {
    const normalized = LEGACY_KIMI_WIRE_MODEL.toLowerCase();
    const matched = loadMoonshotModels().filter((model) =>
      (model.matchers ?? []).some((matcher) => matches(matcher, normalized)),
    );
    expect(matched.map((model) => model.id)).toEqual(["kimi-family"]);
  });

  it("matches the catalog kimi-family rate, with input-rate fallback for cache creation", () => {
    const family = loadMoonshotModels().find((model) => model.id === "kimi-family");
    const pricing = family?.pricing;
    expect(pricing).toBeDefined();
    if (!pricing) throw new Error("kimi-family pricing missing from the catalog fixture");
    expect(LEGACY_KIMI_WIRE_PRICING.inputPerMToken).toBe(pricing.inputPerMToken);
    expect(LEGACY_KIMI_WIRE_PRICING.outputPerMToken).toBe(pricing.outputPerMToken);
    expect(LEGACY_KIMI_WIRE_PRICING.cacheReadPerMToken).toBe(pricing.cacheReadPerMToken);
    // ModelPricing.cost falls back to the input rate when the catalog entry
    // carries no cacheCreationPerMToken; the constant must track that fallback.
    expect(LEGACY_KIMI_WIRE_PRICING.cacheCreationPerMToken).toBe(
      pricing.cacheCreationPerMToken ?? pricing.inputPerMToken,
    );
  });
});

type PricingFixture = {
  schema: string;
  costVectors: {
    rates: {
      inputNanoUsdPerMToken: number;
      outputNanoUsdPerMToken: number;
      cacheCreationNanoUsdPerMToken: number | null;
      cacheReadNanoUsdPerMToken: number;
    };
    buckets: {
      inputTokens: number;
      outputTokens: number;
      cacheCreationTokens: number;
      cacheReadTokens: number;
    };
    expectedCostNanoUsd: number;
  }[];
  legacyKimiVectors: {
    provider: string;
    model: string;
    buckets: {
      inputTokens: number;
      outputTokens: number;
      cacheCreationTokens: number;
      cacheReadTokens: number;
    };
    isLegacy: boolean;
    expected?: { model: string; totalTokens: number; costNanoUsd: number };
  }[];
};

function loadPricingFixture(): PricingFixture {
  return JSON.parse(
    readFileSync(resolve(__dirname, "../../..", "tests/fixtures/domain-core/pricing/v2/pricing-kat.json"), "utf8"),
  ) as PricingFixture;
}

describe("shared domain-core pricing", () => {
  const fixture = loadPricingFixture();

  it.each(["legacy", "shadow", "rust"] as const)("matches canonical vectors in %s mode", (mode) => {
    for (const vector of fixture.costVectors) {
      const actual = estimateTokenCost(
          {
            inputPerMToken: vector.rates.inputNanoUsdPerMToken / 1_000_000_000,
            outputPerMToken: vector.rates.outputNanoUsdPerMToken / 1_000_000_000,
            cacheCreationPerMToken:
              vector.rates.cacheCreationNanoUsdPerMToken === null
                ? undefined
                : vector.rates.cacheCreationNanoUsdPerMToken / 1_000_000_000,
            cacheReadPerMToken: vector.rates.cacheReadNanoUsdPerMToken / 1_000_000_000,
          },
          vector.buckets,
          { OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: mode },
        );
      expect(Math.abs(actual * 1_000_000_000 - vector.expectedCostNanoUsd)).toBeLessThanOrEqual(0.500_001);
    }
  });

  it.each(["legacy", "shadow", "rust"] as const)("matches Kimi rewrite vectors in %s mode", (mode) => {
    for (const vector of fixture.legacyKimiVectors) {
      const actual = priceLegacyKimiEvent(vector.provider, vector.model, vector.buckets, {
        OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: mode,
      });
      expect(actual.isLegacy).toBe(vector.isLegacy);
      if (vector.expected) {
        expect(actual).toEqual({
          isLegacy: true,
          model: vector.expected.model,
          totalTokens: vector.expected.totalTokens,
          costUsd: vector.expected.costNanoUsd / 1_000_000_000,
        });
      }
    }
  });

  it("does not evaluate the legacy cost closure in rust mode", () => {
    let legacyCalls = 0;
    const actual = calculateTokenCost(
      { inputPerMToken: 3, outputPerMToken: 15, cacheReadPerMToken: 0.5 },
      { inputTokens: 1_000_000, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 },
      () => {
        legacyCalls += 1;
        return -1;
      },
      { OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "rust" },
    );
    expect(actual).toBe(3);
    expect(legacyCalls).toBe(0);
  });

  it("fails unknown rollout values closed to legacy", () => {
    expect(resolveDomainCorePricingMode({ OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "surprise" })).toBe("legacy");
  });

  it.each([
    { rates: { inputPerMToken: -1, outputPerMToken: 1, cacheReadPerMToken: 0 }, inputTokens: 1 },
    { rates: { inputPerMToken: Number.NaN, outputPerMToken: 1, cacheReadPerMToken: 0 }, inputTokens: 1 },
    { rates: { inputPerMToken: 0.0000000001, outputPerMToken: 1, cacheReadPerMToken: 0 }, inputTokens: 1 },
    { rates: { inputPerMToken: 1, outputPerMToken: 1, cacheReadPerMToken: 0 }, inputTokens: Number.MAX_SAFE_INTEGER },
    { rates: { inputPerMToken: 9_007_199.25474099, outputPerMToken: 1, cacheReadPerMToken: 0 }, inputTokens: Number.MAX_SAFE_INTEGER },
  ])("rejects invalid or overflowing fixed-point input in rust mode", ({ rates, inputTokens }) => {
    let legacyCalls = 0;
    expect(() =>
      calculateTokenCost(
        rates,
        { inputTokens, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 },
        () => {
          legacyCalls += 1;
          return -1;
        },
        { OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "rust" },
      ),
    ).toThrow(DomainCorePricingError);
    expect(legacyCalls).toBe(0);
  });

  it("keeps shadow mode legacy-authoritative when fixed-point input is rejected", () => {
    expect(
      calculateTokenCost(
        { inputPerMToken: -1, outputPerMToken: 1, cacheReadPerMToken: 0 },
        { inputTokens: 1, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 },
        () => 42,
        { OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "shadow" },
      ),
    ).toBe(42);
  });
});
