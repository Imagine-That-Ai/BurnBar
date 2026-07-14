import { createRequire } from "node:module";

import { isRecord } from "./guards.js";
import { logWarn } from "./logging.js";

type DomainCorePricingMode = "legacy" | "shadow" | "rust";

type TokenPricingRates = {
  inputPerMToken: number;
  outputPerMToken: number;
  cacheCreationPerMToken?: number;
  cacheReadPerMToken: number;
};

type TokenPricingBuckets = {
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
};

type LegacyKimiPricing = {
  isLegacy: boolean;
  model?: string;
  totalTokens?: number;
  costUsd?: number;
};

interface DomainCorePricingModule {
  calculateTokenCostNanoUsd(rates: BigUint64Array, buckets: BigUint64Array, hasCacheCreationRate: boolean): bigint;
  domainCoreVersion(): string;
  isLegacyKimiWireEvent(provider: string, model: string): boolean;
  legacyKimiWireModel(): string;
  priceLegacyKimiWireEvent(
    inputTokens: bigint,
    outputTokens: bigint,
    cacheCreationTokens: bigint,
    cacheReadTokens: bigint,
  ): BigUint64Array;
}

export class DomainCorePricingError extends Error {
  constructor() {
    super("domain-core pricing rejected invalid or overflowing input");
    this.name = "DomainCorePricingError";
  }
}

const NANO_USD_PER_USD = 1_000_000_000;
const SHADOW_MAX_DELTA_NANO_USD = 0.500_001;

let wasmInitialized = false;
let wasmUnavailable = false;
let unavailableLogged = false;
let domainCore: DomainCorePricingModule | undefined;
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

  try {
    const encodedRates = encodeRates(rates);
    const encodedBuckets = encodeBuckets(buckets);
    const rustNanoUsd = requireDomainCore().calculateTokenCostNanoUsd(
      encodedRates.values,
      encodedBuckets,
      encodedRates.hasCacheCreationRate,
    );
    const rustUsd = nanoUsdToUsd(rustNanoUsd);
    if (mode === "rust") return rustUsd;

    const typescript = legacy();
    if (!withinShadowBound(typescript, rustNanoUsd)) {
      logWarn({ event: "domain_core.pricing.shadow_mismatch", core_version: rustVersion });
    }
    return typescript;
  } catch {
    if (mode === "shadow") {
      logWarn({ event: "domain_core.pricing.shadow_rejected", core_version: rustVersion });
      return legacy();
    }
    throw new DomainCorePricingError();
  }
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

  try {
    const core = requireDomainCore();
    let rust: LegacyKimiPricing = { isLegacy: false };
    if (core.isLegacyKimiWireEvent(provider, model)) {
      const encoded = encodeBuckets(buckets);
      const result = core.priceLegacyKimiWireEvent(encoded[0], encoded[1], encoded[2], encoded[3]);
      rust = {
        isLegacy: true,
        model: rustLegacyKimiModel,
        totalTokens: bigintToSafeNumber(result[0]),
        costUsd: nanoUsdToUsd(result[1]),
      };
    }
    if (mode === "rust") return rust;

    const typescript = legacy();
    if (!equivalentKimi(typescript, rust)) {
      logWarn({ event: "domain_core.pricing.kimi_shadow_mismatch", core_version: rustVersion });
    }
    return typescript;
  } catch {
    if (mode === "shadow") {
      logWarn({ event: "domain_core.pricing.kimi_shadow_rejected", core_version: rustVersion });
      return legacy();
    }
    throw new DomainCorePricingError();
  }
}

function initializeDomainCore(): void {
  if (wasmInitialized) return;
  if (wasmUnavailable) throw new DomainCorePricingError();
  try {
    const require = createRequire(__filename);
    const loaded: unknown = require("@openburnbar/domain-core-wasm");
    if (!isDomainCorePricingModule(loaded)) throw new DomainCorePricingError();
    domainCore = loaded;
    rustVersion = domainCore.domainCoreVersion();
    rustLegacyKimiModel = domainCore.legacyKimiWireModel();
    wasmInitialized = true;
  } catch {
    wasmUnavailable = true;
    if (!unavailableLogged) {
      unavailableLogged = true;
      logWarn({ event: "domain_core.pricing.wasm_unavailable" });
    }
    throw new DomainCorePricingError();
  }
}

function isDomainCorePricingModule(value: unknown): value is DomainCorePricingModule {
  return (
    isRecord(value) &&
    typeof value.calculateTokenCostNanoUsd === "function" &&
    typeof value.domainCoreVersion === "function" &&
    typeof value.isLegacyKimiWireEvent === "function" &&
    typeof value.legacyKimiWireModel === "function" &&
    typeof value.priceLegacyKimiWireEvent === "function"
  );
}

function requireDomainCore(): DomainCorePricingModule {
  initializeDomainCore();
  if (!domainCore) throw new DomainCorePricingError();
  return domainCore;
}

function encodeRates(rates: TokenPricingRates): { values: BigUint64Array; hasCacheCreationRate: boolean } {
  const hasCacheCreationRate = rates.cacheCreationPerMToken !== undefined;
  return {
    values: new BigUint64Array([
      encodeRate(rates.inputPerMToken),
      encodeRate(rates.outputPerMToken),
      hasCacheCreationRate ? encodeRate(rates.cacheCreationPerMToken) : 0n,
      encodeRate(rates.cacheReadPerMToken),
    ]),
    hasCacheCreationRate,
  };
}

function encodeRate(value: number | undefined): bigint {
  if (value === undefined || !Number.isFinite(value) || value < 0) throw new DomainCorePricingError();
  const nanoUsd = value * NANO_USD_PER_USD;
  if (!Number.isSafeInteger(nanoUsd)) throw new DomainCorePricingError();
  return BigInt(nanoUsd);
}

function encodeBuckets(buckets: TokenPricingBuckets): BigUint64Array {
  return new BigUint64Array([
    encodeTokenCount(buckets.inputTokens),
    encodeTokenCount(buckets.outputTokens),
    encodeTokenCount(buckets.cacheCreationTokens),
    encodeTokenCount(buckets.cacheReadTokens),
  ]);
}

function encodeTokenCount(value: number): bigint {
  if (!Number.isSafeInteger(value) || value < 0) throw new DomainCorePricingError();
  return BigInt(value);
}

function nanoUsdToUsd(value: bigint): number {
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new DomainCorePricingError();
  return Number(value) / NANO_USD_PER_USD;
}

function bigintToSafeNumber(value: bigint): number {
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) throw new DomainCorePricingError();
  return Number(value);
}

function withinShadowBound(legacyUsd: number, rustNanoUsd: bigint): boolean {
  if (!Number.isFinite(legacyUsd)) return false;
  return Math.abs(legacyUsd * NANO_USD_PER_USD - Number(rustNanoUsd)) <= SHADOW_MAX_DELTA_NANO_USD;
}

function equivalentKimi(left: LegacyKimiPricing, right: LegacyKimiPricing): boolean {
  if (left.isLegacy !== right.isLegacy || left.model !== right.model || left.totalTokens !== right.totalTokens) {
    return false;
  }
  if (left.costUsd === undefined || right.costUsd === undefined) return left.costUsd === right.costUsd;
  return Math.abs(left.costUsd - right.costUsd) * NANO_USD_PER_USD <= SHADOW_MAX_DELTA_NANO_USD;
}
