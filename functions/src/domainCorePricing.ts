import { createRequire } from "node:module";

import { isRecord } from "./guards.js";
import { logWarn } from "./logging.js";
import { resolveDomainCoreEvidenceChannel, resolveDomainCoreRuntimeMode } from "./domainCoreBuildProfile.js";
import { buildDomainCoreShadowSampleV2, type DomainCoreShadowSampleV2 } from "./domainCoreShadowEvidence.js";

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
type DomainCorePricingShadowEvidenceSink = (sample: DomainCoreShadowSampleV2) => unknown;

let shadowEvidenceSink: DomainCorePricingShadowEvidenceSink | undefined;
const pendingShadowEvidenceTasks = new Set<Promise<void>>();
const pendingProductionShadowSamples: DomainCoreShadowSampleV2[] = [];
const PRODUCTION_SHADOW_EVIDENCE_BATCH_SIZE = 100;
let productionShadowEvidenceFlush: Promise<void> | undefined;

export function configureDomainCorePricingShadowEvidenceSink(
  sink: ((sample: DomainCoreShadowSampleV2) => void) | undefined,
): void {
  shadowEvidenceSink = sink;
}

/** Waits for every pricing shadow-evidence write observed before the drain settles. */
export async function flushDomainCorePricingShadowEvidence(): Promise<void> {
  while (
    pendingShadowEvidenceTasks.size > 0 ||
    pendingProductionShadowSamples.length > 0 ||
    productionShadowEvidenceFlush
  ) {
    const pending = [...pendingShadowEvidenceTasks];
    if (pendingProductionShadowSamples.length > 0 || productionShadowEvidenceFlush) {
      pending.push(flushProductionShadowSamples());
    }
    await Promise.all(pending);
  }
}

export function resolveDomainCorePricingMode(environment: NodeJS.ProcessEnv = process.env): DomainCorePricingMode {
  return resolveDomainCoreRuntimeMode("pricing", environment);
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
    const rustStarted = process.hrtime.bigint();
    const rustNanoUsd = requireDomainCore().calculateTokenCostNanoUsd(
      encodedRates.values,
      encodedBuckets,
      encodedRates.hasCacheCreationRate,
    );
    const rustMicros = elapsedMicros(rustStarted);
    const rustUsd = nanoUsdToUsd(rustNanoUsd);
    if (mode === "rust") return rustUsd;

    const legacyStarted = process.hrtime.bigint();
    const typescript = legacy();
    const legacyMicros = elapsedMicros(legacyStarted);
    const equivalent = withinShadowBound(typescript, rustNanoUsd);
    if (!equivalent) {
      logWarn({ event: "domain_core.pricing.shadow_mismatch", core_version: rustVersion });
    }
    recordShadowComparison(
      "token-cost",
      "calculate_token_cost",
      equivalent,
      equivalent ? null : "result_mismatch",
      legacyMicros,
      rustMicros,
      environment,
    );
    return typescript;
  } catch {
    if (mode === "shadow") {
      logWarn({ event: "domain_core.pricing.shadow_rejected", core_version: rustVersion });
      const legacyStarted = process.hrtime.bigint();
      const value = legacy();
      recordShadowComparison(
        "token-cost",
        "calculate_token_cost",
        false,
        "native_error",
        elapsedMicros(legacyStarted),
        0,
        environment,
      );
      return value;
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
    const rustStarted = process.hrtime.bigint();
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
    const rustMicros = elapsedMicros(rustStarted);
    if (mode === "rust") return rust;

    const legacyStarted = process.hrtime.bigint();
    const typescript = legacy();
    const legacyMicros = elapsedMicros(legacyStarted);
    const equivalent = equivalentKimi(typescript, rust);
    if (!equivalent) {
      logWarn({ event: "domain_core.pricing.kimi_shadow_mismatch", core_version: rustVersion });
    }
    recordShadowComparison(
      "legacy-kimi",
      "price_legacy_kimi",
      equivalent,
      equivalent ? null : "result_mismatch",
      legacyMicros,
      rustMicros,
      environment,
    );
    return typescript;
  } catch {
    if (mode === "shadow") {
      logWarn({ event: "domain_core.pricing.kimi_shadow_rejected", core_version: rustVersion });
      const legacyStarted = process.hrtime.bigint();
      const value = legacy();
      recordShadowComparison(
        "legacy-kimi",
        "price_legacy_kimi",
        false,
        "native_error",
        elapsedMicros(legacyStarted),
        0,
        environment,
      );
      return value;
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

function elapsedMicros(started: bigint): number {
  const micros = (process.hrtime.bigint() - started) / 1_000n;
  return Number(micros > 600_000_000n ? 600_000_000n : micros);
}

function recordShadowComparison(
  slice: "token-cost" | "legacy-kimi",
  operation: string,
  equivalent: boolean,
  mismatchCategory: "result_mismatch" | "native_error" | null,
  legacyMicros: number,
  rustMicros: number,
  environment: NodeJS.ProcessEnv,
): void {
  const channel = resolveDomainCoreEvidenceChannel(environment);
  if (!channel || rustVersion === "unknown") return;
  try {
    const sample = buildDomainCoreShadowSampleV2({
      domain: "pricing",
      slice,
      consumer: "functions",
      channel,
      operation,
      coreVersion: rustVersion,
      outcome: equivalent ? "match" : "mismatch",
      mismatchCategory,
      legacyMicros,
      rustMicros,
    });
    if (shadowEvidenceSink) {
      trackShadowEvidenceTask(
        Promise.resolve(shadowEvidenceSink(sample)).then(() => undefined),
        "domain_core.pricing.shadow_evidence_rejected",
      );
    } else if (environment.K_SERVICE || environment.FUNCTION_TARGET) {
      pendingProductionShadowSamples.push(sample);
    }
  } catch {
    logWarn({ event: "domain_core.pricing.shadow_evidence_rejected" });
  }
}

function trackShadowEvidenceTask(task: Promise<void>, failureEvent: string): void {
  let tracked: Promise<void>;
  tracked = task
    .catch(() => {
      logWarn({ event: failureEvent });
    })
    .finally(() => {
      pendingShadowEvidenceTasks.delete(tracked);
    });
  pendingShadowEvidenceTasks.add(tracked);
}

function flushProductionShadowSamples(): Promise<void> {
  if (!productionShadowEvidenceFlush) {
    productionShadowEvidenceFlush = persistQueuedProductionShadowSamples().finally(() => {
      productionShadowEvidenceFlush = undefined;
    });
  }
  return productionShadowEvidenceFlush;
}

async function persistQueuedProductionShadowSamples(): Promise<void> {
  let dependencies: Awaited<ReturnType<typeof loadProductionShadowDependencies>>;
  try {
    dependencies = await loadProductionShadowDependencies();
  } catch {
    const dropped = pendingProductionShadowSamples.splice(0);
    logWarn({ event: "domain_core.pricing.shadow_evidence_persist_failed", sample_count: dropped.length });
    return;
  }
  const [{ db }, { firestoreWithResilience }, { domainCoreShadowStore, persistDomainCoreShadowSamples }] = dependencies;
  const store = domainCoreShadowStore(db);
  while (pendingProductionShadowSamples.length > 0) {
    const batch = pendingProductionShadowSamples.splice(0, PRODUCTION_SHADOW_EVIDENCE_BATCH_SIZE);
    try {
      await firestoreWithResilience("persistDomainCorePricingShadowSamples", async () => {
        await persistDomainCoreShadowSamples(store, batch, Date.now());
      });
    } catch {
      logWarn({ event: "domain_core.pricing.shadow_evidence_persist_failed", sample_count: batch.length });
    }
  }
}

function loadProductionShadowDependencies() {
  return Promise.all([
    import("./adminRuntime.js"),
    import("./resilienceHelpers.js"),
    import("./domainCoreShadowEvidence.js"),
  ] as const);
}
