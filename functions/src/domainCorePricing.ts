import { createRequire } from "node:module";
import type * as DomainCore from "@openburnbar/domain-core-wasm";

import { logWarn } from "./logging.js";

export type DomainCorePricingMode = "legacy" | "shadow" | "rust";

export type TokenPricingRates = {
  inputPerMToken: number;
  outputPerMToken: number;
  cacheCreationPerMToken?: number;
  cacheReadPerMToken: number;
};

export type TokenPricingBuckets = {
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
};

export type LegacyKimiPricing = {
  isLegacy: boolean;
  model?: string;
  totalTokens?: number;
  costUsd?: number;
};

let wasmInitialized = false;
let wasmUnavailable = false;
let domainCore: typeof DomainCore | undefined;
let rustVersion = "unknown";
let rustLegacyKimiModel = "";

export function resolveDomainCorePricingMode(environment: NodeJS.ProcessEnv = process.env): DomainCorePricingMode {
  const value = (environment.OPENBURNBAR_DOMAIN_CORE_PRICING_MODE ?? "").toLowerCase();
  return value === "shadow" || value === "rust" ? value : "legacy";
}

export function calculateTokenCost(
  rates: TokenPricingRates,
  buckets: TokenPricingBuckets,
  legacy: () => number,
  environment: NodeJS.ProcessEnv = process.env,
): number {
  const mode = resolveDomainCorePricingMode(environment);
  if (mode === "legacy") return legacy();

  const rust = withDomainCore(() =>
    requireDomainCore().calculateTokenCost(
      new Float64Array([
        rates.inputPerMToken,
        rates.outputPerMToken,
        rates.cacheCreationPerMToken ?? Number.NaN,
        rates.cacheReadPerMToken,
      ]),
      bucketVector(buckets),
    ),
  );
  if (rust === undefined) return legacy();
  if (mode === "rust") return rust;

  const typescript = legacy();
  if (!approximatelyEqual(typescript, rust)) {
    logWarn({ event: "domain_core.pricing.shadow_mismatch", core_version: rustVersion });
  }
  return typescript;
}

export function priceLegacyKimiUsage(
  provider: string,
  model: string,
  buckets: TokenPricingBuckets,
  legacy: () => LegacyKimiPricing,
  environment: NodeJS.ProcessEnv = process.env,
): LegacyKimiPricing {
  const mode = resolveDomainCorePricingMode(environment);
  if (mode === "legacy") return legacy();

  const rust = withDomainCore((): LegacyKimiPricing => {
    const core = requireDomainCore();
    if (!core.isLegacyKimiWireEvent(provider, model)) return { isLegacy: false };
    const result = core.priceLegacyKimiWireEvent(
      buckets.inputTokens,
      buckets.outputTokens,
      buckets.cacheCreationTokens,
      buckets.cacheReadTokens,
    );
    return {
      isLegacy: true,
      model: rustLegacyKimiModel,
      totalTokens: result[0],
      costUsd: result[1],
    };
  });
  if (rust === undefined) return legacy();
  if (mode === "rust") return rust;

  const typescript = legacy();
  if (!equivalentKimi(typescript, rust)) {
    logWarn({ event: "domain_core.pricing.kimi_shadow_mismatch", core_version: rustVersion });
  }
  return typescript;
}

function initializeDomainCore(): void {
  if (wasmInitialized) return;
  const require = createRequire(__filename);
  domainCore = require("@openburnbar/domain-core-wasm") as typeof DomainCore;
  rustVersion = domainCore.domainCoreVersion();
  rustLegacyKimiModel = domainCore.legacyKimiWireModel();
  wasmInitialized = true;
}

function requireDomainCore(): typeof DomainCore {
  if (!domainCore) throw new Error("domain core is not initialized");
  return domainCore;
}

function withDomainCore<T>(operation: () => T): T | undefined {
  if (wasmUnavailable) return undefined;
  try {
    initializeDomainCore();
    return operation();
  } catch {
    wasmUnavailable = true;
    logWarn({ event: "domain_core.pricing.wasm_unavailable" });
    return undefined;
  }
}

function bucketVector(buckets: TokenPricingBuckets): Float64Array {
  return new Float64Array([
    buckets.inputTokens,
    buckets.outputTokens,
    buckets.cacheCreationTokens,
    buckets.cacheReadTokens,
  ]);
}

function approximatelyEqual(left: number | undefined, right: number | undefined): boolean {
  if (left === undefined || right === undefined) return left === right;
  const tolerance = Math.max(1e-12, Math.abs(left) * 1e-12);
  return Math.abs(left - right) <= tolerance;
}

function equivalentKimi(left: LegacyKimiPricing, right: LegacyKimiPricing): boolean {
  return (
    left.isLegacy === right.isLegacy &&
    left.model === right.model &&
    approximatelyEqual(left.totalTokens, right.totalTokens) &&
    approximatelyEqual(left.costUsd, right.costUsd)
  );
}
