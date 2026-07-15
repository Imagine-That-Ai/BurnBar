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
import { afterEach, describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import {
  LEGACY_KIMI_WIRE_MODEL,
  LEGACY_KIMI_WIRE_PRICING,
  estimateTokenCost,
  priceLegacyKimiEvent,
} from "../pricing.js";
import {
  calculateTokenCost,
  configureDomainCorePricingShadowEvidenceSink,
  DomainCorePricingError,
  flushDomainCorePricingShadowEvidence,
  resolveDomainCorePricingMode,
} from "../domainCorePricing.js";
import { isRecord } from "../guards.js";
import type { DomainCoreBuildReceipt } from "../domainCoreBuildProfile.js";

// Core-decomposition: catalog.json moved from the Core monolith's Resources into
// OpenBurnBarKernel/Resources (git mv). Repointed after the train ← main merge.
const CATALOG_PATH = resolve(__dirname, "../../..", "OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json");

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

const LOADED_CORE_SOURCE_SHA256 = "f435ea8e6b615ced64059c1f8ceaa9629247200479dc668abdd42afa2b02f600";

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
    expected?: { model: string; totalTokens: number; costNanoUsd: number } | null;
  }[];
};

function isTokenBuckets(value: unknown): value is PricingFixture["costVectors"][number]["buckets"] {
  return (
    isRecord(value) &&
    typeof value.inputTokens === "number" &&
    typeof value.outputTokens === "number" &&
    typeof value.cacheCreationTokens === "number" &&
    typeof value.cacheReadTokens === "number"
  );
}

function isPricingRates(value: unknown): value is PricingFixture["costVectors"][number]["rates"] {
  return (
    isRecord(value) &&
    typeof value.inputNanoUsdPerMToken === "number" &&
    typeof value.outputNanoUsdPerMToken === "number" &&
    (value.cacheCreationNanoUsdPerMToken === null || typeof value.cacheCreationNanoUsdPerMToken === "number") &&
    typeof value.cacheReadNanoUsdPerMToken === "number"
  );
}

function isPricingFixture(value: unknown): value is PricingFixture {
  if (!isRecord(value) || typeof value.schema !== "string") return false;
  if (!Array.isArray(value.costVectors) || !Array.isArray(value.legacyKimiVectors)) return false;
  const validCostVectors = value.costVectors.every(
    (vector) =>
      isRecord(vector) &&
      isPricingRates(vector.rates) &&
      isTokenBuckets(vector.buckets) &&
      typeof vector.expectedCostNanoUsd === "number",
  );
  const validLegacyVectors = value.legacyKimiVectors.every((vector) => {
    if (
      !isRecord(vector) ||
      typeof vector.provider !== "string" ||
      typeof vector.model !== "string" ||
      !isTokenBuckets(vector.buckets) ||
      typeof vector.isLegacy !== "boolean"
    ) {
      return false;
    }
    if (vector.expected === undefined || vector.expected === null) return true;
    return (
      isRecord(vector.expected) &&
      typeof vector.expected.model === "string" &&
      typeof vector.expected.totalTokens === "number" &&
      typeof vector.expected.costNanoUsd === "number"
    );
  });
  return validCostVectors && validLegacyVectors;
}

function loadPricingFixture(): PricingFixture {
  const parsed: unknown = JSON.parse(
    readFileSync(resolve(__dirname, "../../..", "tests/fixtures/domain-core/pricing/v2/pricing-kat.json"), "utf8"),
  );
  if (!isPricingFixture(parsed)) throw new Error("invalid domain-core pricing fixture");
  return parsed;
}

describe("shared domain-core pricing", () => {
  const fixture = loadPricingFixture();
  const signedInternalReceipt = (): DomainCoreBuildReceipt => ({
    schemaVersion: 1,
    name: "internal",
    artifactAuthority: "signed",
    distribution: "internal",
    rolloutChannel: "internal",
    evidenceEnabled: true,
    candidateIdentity: {
      candidateCommit: "a".repeat(40),
      coreVersion: "0.1.0",
      abiVersion: 3,
      sourceSha256: LOADED_CORE_SOURCE_SHA256,
    },
    modes: {
      quota: "shadow",
      cloudVault: "shadow",
      cloudVaultRewrap: "shadow",
      cloudVaultSearch: "shadow",
      hermes: "shadow",
      pricing: "shadow",
    },
  });

  afterEach(async () => {
    configureDomainCorePricingShadowEvidenceSink(undefined);
    await flushDomainCorePricingShadowEvidence();
  });

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

  it("rejects explicit receipt injection outside the test runtime", () => {
    const original = process.env.NODE_ENV;
    process.env.NODE_ENV = "production";
    try {
      expect(() => resolveDomainCorePricingMode({}, signedInternalReceipt())).toThrow(DomainCorePricingError);
    } finally {
      process.env.NODE_ENV = original;
    }
  });

  it.each([
    { rates: { inputPerMToken: -1, outputPerMToken: 1, cacheReadPerMToken: 0 }, inputTokens: 1 },
    { rates: { inputPerMToken: Number.NaN, outputPerMToken: 1, cacheReadPerMToken: 0 }, inputTokens: 1 },
    { rates: { inputPerMToken: 0.0000000001, outputPerMToken: 1, cacheReadPerMToken: 0 }, inputTokens: 1 },
    { rates: { inputPerMToken: 1, outputPerMToken: 1, cacheReadPerMToken: 0 }, inputTokens: Number.MAX_SAFE_INTEGER },
    {
      rates: { inputPerMToken: 9_007_199.25474099, outputPerMToken: 1, cacheReadPerMToken: 0 },
      inputTokens: Number.MAX_SAFE_INTEGER,
    },
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

  it("emits one candidate-bound V3 whole-call comparison with the loaded Wasm identity", () => {
    const samples: unknown[] = [];
    configureDomainCorePricingShadowEvidenceSink((sample) => {
      samples.push(sample);
    });
    expect(
      calculateTokenCost(
        { inputPerMToken: 3, outputPerMToken: 15, cacheReadPerMToken: 0.5 },
        { inputTokens: 1_000_000, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 },
        () => 3,
        {
          OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "signed",
          OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE: "internal",
          OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION: "internal",
          OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED: "1",
          OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "shadow",
          OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE: "shadow",
          OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE: "shadow",
          OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE: "shadow",
          OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE: "shadow",
          OPENBURNBAR_DOMAIN_CORE_HERMES_MODE: "shadow",
          OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL: "internal",
        },
        signedInternalReceipt(),
      ),
    ).toBe(3);
    expect(samples).toHaveLength(1);
    expect(samples[0]).toMatchObject({
      schemaVersion: 3,
      domain: "pricing",
      slice: "token-cost",
      consumer: "functions",
      operation: "calculate_token_cost",
      candidateCommit: "a".repeat(40),
      expectedCoreVersion: "0.1.0",
      expectedCoreAbiVersion: 3,
      expectedCoreSourceSha256: LOADED_CORE_SOURCE_SHA256,
      loadedCoreVersion: "0.1.0",
      loadedCoreAbiVersion: 3,
      loadedCoreSourceSha256: LOADED_CORE_SOURCE_SHA256,
      outcome: "match",
      mismatchCategory: null,
    });
    expect(samples[0]).not.toHaveProperty("coreVersion");
  });

  it("classifies a different loaded Wasm tuple as loaded_identity_mismatch", () => {
    const samples: unknown[] = [];
    configureDomainCorePricingShadowEvidenceSink((sample) => {
      samples.push(sample);
    });
    const receipt = signedInternalReceipt();
    if (!receipt.candidateIdentity) throw new Error("signed test receipt is missing candidate identity");
    receipt.candidateIdentity.sourceSha256 = "c".repeat(64);

    calculateTokenCost(
      { inputPerMToken: 3, outputPerMToken: 15, cacheReadPerMToken: 0.5 },
      { inputTokens: 1_000_000, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 },
      () => 3,
      {
        OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "signed",
        OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE: "internal",
        OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION: "internal",
        OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED: "1",
        OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "shadow",
        OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE: "shadow",
        OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE: "shadow",
        OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE: "shadow",
        OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE: "shadow",
        OPENBURNBAR_DOMAIN_CORE_HERMES_MODE: "shadow",
        OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL: "internal",
      },
      receipt,
    );

    expect(samples).toHaveLength(1);
    expect(samples[0]).toMatchObject({
      schemaVersion: 3,
      expectedCoreSourceSha256: "c".repeat(64),
      loadedCoreVersion: "0.1.0",
      loadedCoreAbiVersion: 3,
      loadedCoreSourceSha256: LOADED_CORE_SOURCE_SHA256,
      outcome: "mismatch",
      mismatchCategory: "loaded_identity_mismatch",
    });
  });

  it("drains async evidence added while a flush is already in progress", async () => {
    const releases: (() => void)[] = [];
    const persisted: string[] = [];
    configureDomainCorePricingShadowEvidenceSink(async (sample) => {
      await new Promise<void>((resolve) => releases.push(resolve));
      persisted.push(sample.operation);
    });
    const environment = {
      OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "signed",
      OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE: "internal",
      OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION: "internal",
      OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED: "1",
      OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "shadow",
      OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE: "shadow",
      OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE: "shadow",
      OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE: "shadow",
      OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE: "shadow",
      OPENBURNBAR_DOMAIN_CORE_HERMES_MODE: "shadow",
      OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL: "internal",
    };
    const calculate = () =>
      calculateTokenCost(
        { inputPerMToken: 3, outputPerMToken: 15, cacheReadPerMToken: 0.5 },
        { inputTokens: 1_000_000, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 },
        () => 3,
        environment,
        signedInternalReceipt(),
      );

    calculate();
    let flushed = false;
    const drain = flushDomainCorePricingShadowEvidence().then(() => {
      flushed = true;
    });
    calculate();
    expect(releases).toHaveLength(2);

    releases[0]();
    await Promise.resolve();
    await Promise.resolve();
    expect(flushed).toBe(false);

    releases[1]();
    await drain;
    expect(flushed).toBe(true);
    expect(persisted).toEqual(["calculate_token_cost", "calculate_token_cost"]);
  });

  it("contains async evidence sink failures without rejecting the flush", async () => {
    configureDomainCorePricingShadowEvidenceSink(async () => {
      throw new Error("sink unavailable");
    });
    calculateTokenCost(
      { inputPerMToken: 3, outputPerMToken: 15, cacheReadPerMToken: 0.5 },
      { inputTokens: 1_000_000, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 },
      () => 3,
      {
        OPENBURNBAR_DOMAIN_CORE_BUILD_AUTHORITY: "signed",
        OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE: "internal",
        OPENBURNBAR_DOMAIN_CORE_DISTRIBUTION: "internal",
        OPENBURNBAR_DOMAIN_CORE_EVIDENCE_ENABLED: "1",
        OPENBURNBAR_DOMAIN_CORE_PRICING_MODE: "shadow",
        OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE: "shadow",
        OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE: "shadow",
        OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE: "shadow",
        OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE: "shadow",
        OPENBURNBAR_DOMAIN_CORE_HERMES_MODE: "shadow",
        OPENBURNBAR_DOMAIN_CORE_ROLLOUT_CHANNEL: "internal",
      },
      signedInternalReceipt(),
    );

    await expect(flushDomainCorePricingShadowEvidence()).resolves.toBeUndefined();
  });
});
