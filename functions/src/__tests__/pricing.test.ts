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

import { LEGACY_KIMI_WIRE_MODEL, LEGACY_KIMI_WIRE_PRICING } from "../pricing.js";

const CATALOG_PATH = resolve(
  __dirname,
  "../../..",
  "OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/catalog.json",
);

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

function loadMoonshotModels(): CatalogModel[] {
  const catalog = JSON.parse(readFileSync(CATALOG_PATH, "utf8")) as Catalog;
  const moonshot = catalog.providers.find((provider) => provider.id === "moonshot");
  expect(moonshot).toBeDefined();
  return moonshot!.models;
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
    expect(family?.pricing).toBeDefined();
    const pricing = family!.pricing!;
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
