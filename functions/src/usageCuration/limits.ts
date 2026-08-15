/**
 * @fileoverview Usage-memory curation meters — pure limit math + Remote Config bridge.
 *
 * BurnBar pays for the cloud memory-curation inference (OpenRouter → CoreWeave),
 * so every cloud call is metered per uid against two token lanes:
 *
 *   - `text` lane        — deepseek/deepseek-v4-flash extraction. Available to ANY
 *                          active Pro (pro | pro_max | ultra).
 *   - `multimodal` lane  — minimax/minimax-m3 with image parts. Pro Max (and
 *                          Ultra, which mirrors Pro Max) ONLY.
 *
 * Unit = input + output tokens per lane. Each lane has a monthly ceiling and a
 * daily ceiling (both RC-tunable); Ultra applies a multiplier on top of the
 * Pro Max numbers (10× monthly, 4× daily) so the public "10×" claim holds.
 *
 * Mirrors cloudProAllowanceCore.ts (pure math, frozen defaults, normalize with
 * shrink-safe fallbacks) + cloudProAllowanceRemoteConfig.ts (template read with
 * fail-open-to-defaults). The `usage_curation_enabled` kill flag rides the same
 * template read so one RC publish can stop all curation spend.
 */

import { getRemoteConfig } from "firebase-admin/remote-config";

import { errorMessage } from "../guards.js";
import { logWarn } from "../logging.js";
import { remoteConfigStringValue } from "../remoteConfigGuards.js";

export const USAGE_CURATION_SCHEMA_VERSION = 1;

export type UsageCurationLane = "text" | "multimodal";
export type UsageCurationTier = "pro" | "pro_max" | "ultra";

// Compiled-in defaults (see the usage-memory program plan's tier table).
const TEXT_PRO_MONTHLY_TOKENS = 1_000_000;
const TEXT_PRO_DAILY_TOKENS = 100_000;
const TEXT_PRO_MAX_MONTHLY_TOKENS = 5_000_000;
const TEXT_PRO_MAX_DAILY_TOKENS = 250_000;
const MULTIMODAL_PRO_MAX_MONTHLY_TOKENS = 2_000_000;
const MULTIMODAL_PRO_MAX_DAILY_TOKENS = 150_000;
const ULTRA_MONTHLY_MULTIPLIER = 10;
const ULTRA_DAILY_MULTIPLIER = 4;

export interface UsageCurationLimitsConfig {
  usageCurationEnabled: boolean;
  textProMonthlyTokens: number;
  textProDailyTokens: number;
  textProMaxMonthlyTokens: number;
  textProMaxDailyTokens: number;
  multimodalProMaxMonthlyTokens: number;
  multimodalProMaxDailyTokens: number;
  ultraMonthlyMultiplier: number;
  ultraDailyMultiplier: number;
}

export const DEFAULT_USAGE_CURATION_LIMITS_CONFIG: UsageCurationLimitsConfig = Object.freeze({
  usageCurationEnabled: true,
  textProMonthlyTokens: TEXT_PRO_MONTHLY_TOKENS,
  textProDailyTokens: TEXT_PRO_DAILY_TOKENS,
  textProMaxMonthlyTokens: TEXT_PRO_MAX_MONTHLY_TOKENS,
  textProMaxDailyTokens: TEXT_PRO_MAX_DAILY_TOKENS,
  multimodalProMaxMonthlyTokens: MULTIMODAL_PRO_MAX_MONTHLY_TOKENS,
  multimodalProMaxDailyTokens: MULTIMODAL_PRO_MAX_DAILY_TOKENS,
  ultraMonthlyMultiplier: ULTRA_MONTHLY_MULTIPLIER,
  ultraDailyMultiplier: ULTRA_DAILY_MULTIPLIER,
});

export interface UsageCurationLaneLimits {
  monthlyTokens: number;
  dailyTokens: number;
}

function positiveInteger(raw: unknown, fallback: number): number {
  const value = typeof raw === "number" ? raw : Number(raw);
  return Number.isFinite(value) && Number.isInteger(value) && value > 0 ? value : fallback;
}

function booleanFlag(raw: unknown, fallback: boolean): boolean {
  if (typeof raw === "boolean") return raw;
  if (typeof raw === "string") {
    const normalized = raw.trim().toLowerCase();
    if (normalized === "true") return true;
    if (normalized === "false") return false;
  }
  return fallback;
}

export function normalizeUsageCurationLimitsConfig(
  overrides: Partial<Record<keyof UsageCurationLimitsConfig, unknown>>,
): UsageCurationLimitsConfig {
  const d = DEFAULT_USAGE_CURATION_LIMITS_CONFIG;
  return {
    usageCurationEnabled: booleanFlag(overrides.usageCurationEnabled, d.usageCurationEnabled),
    textProMonthlyTokens: positiveInteger(overrides.textProMonthlyTokens, d.textProMonthlyTokens),
    textProDailyTokens: positiveInteger(overrides.textProDailyTokens, d.textProDailyTokens),
    textProMaxMonthlyTokens: positiveInteger(overrides.textProMaxMonthlyTokens, d.textProMaxMonthlyTokens),
    textProMaxDailyTokens: positiveInteger(overrides.textProMaxDailyTokens, d.textProMaxDailyTokens),
    multimodalProMaxMonthlyTokens: positiveInteger(
      overrides.multimodalProMaxMonthlyTokens,
      d.multimodalProMaxMonthlyTokens,
    ),
    multimodalProMaxDailyTokens: positiveInteger(overrides.multimodalProMaxDailyTokens, d.multimodalProMaxDailyTokens),
    ultraMonthlyMultiplier: positiveInteger(overrides.ultraMonthlyMultiplier, d.ultraMonthlyMultiplier),
    ultraDailyMultiplier: positiveInteger(overrides.ultraDailyMultiplier, d.ultraDailyMultiplier),
  };
}

/**
 * Resolve the token ceilings for one lane at one tier.
 *
 * Returns `undefined` when the tier has NO access to the lane at all
 * (multimodal is Pro Max/Ultra only) — callers must treat that as an
 * entitlement denial, not a zero-budget meter.
 */
export function usageCurationLaneLimits(
  lane: UsageCurationLane,
  tier: UsageCurationTier,
  config: UsageCurationLimitsConfig = DEFAULT_USAGE_CURATION_LIMITS_CONFIG,
): UsageCurationLaneLimits | undefined {
  if (lane === "text") {
    if (tier === "pro") {
      return { monthlyTokens: config.textProMonthlyTokens, dailyTokens: config.textProDailyTokens };
    }
    const base = { monthlyTokens: config.textProMaxMonthlyTokens, dailyTokens: config.textProMaxDailyTokens };
    return tier === "ultra" ? applyUltraMultiplier(base, config) : base;
  }
  // multimodal lane: pro has no access at any budget.
  if (tier === "pro") return undefined;
  const base = {
    monthlyTokens: config.multimodalProMaxMonthlyTokens,
    dailyTokens: config.multimodalProMaxDailyTokens,
  };
  return tier === "ultra" ? applyUltraMultiplier(base, config) : base;
}

function applyUltraMultiplier(
  base: UsageCurationLaneLimits,
  config: UsageCurationLimitsConfig,
): UsageCurationLaneLimits {
  return {
    monthlyTokens: base.monthlyTokens * config.ultraMonthlyMultiplier,
    dailyTokens: base.dailyTokens * config.ultraDailyMultiplier,
  };
}

/** UTC day key, e.g. "2026-08-15". Companion to cloudProAllowanceCore's monthKeyForDate. */
export function dayKeyForDate(date: Date): string {
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  const day = String(date.getUTCDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

/** ISO instant when the DAILY meter resets (next UTC midnight after `date`). */
export function nextDailyResetISO(date: Date): string {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() + 1)).toISOString();
}

/** ISO instant when the MONTHLY meter resets (first instant of the next UTC month). */
export function nextMonthlyResetISO(date: Date): string {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1)).toISOString();
}

export interface UsageCurationReservationEvaluation {
  ok: boolean;
  reason?: "invalid_request" | "monthly_exhausted" | "daily_exhausted";
  monthlyRemaining: number;
  dailyRemaining: number;
}

/** Pure shortfall check for one lane reservation (monthly checked before daily). */
export function evaluateUsageCurationReservation(input: {
  requestedTokens: number;
  monthlyUsed: number;
  dailyUsed: number;
  limits: UsageCurationLaneLimits;
}): UsageCurationReservationEvaluation {
  const monthlyRemaining = Math.max(0, input.limits.monthlyTokens - input.monthlyUsed);
  const dailyRemaining = Math.max(0, input.limits.dailyTokens - input.dailyUsed);
  if (
    !Number.isFinite(input.requestedTokens) ||
    !Number.isInteger(input.requestedTokens) ||
    input.requestedTokens <= 0
  ) {
    return { ok: false, reason: "invalid_request", monthlyRemaining, dailyRemaining };
  }
  if (input.requestedTokens > monthlyRemaining) {
    return { ok: false, reason: "monthly_exhausted", monthlyRemaining, dailyRemaining };
  }
  if (input.requestedTokens > dailyRemaining) {
    return { ok: false, reason: "daily_exhausted", monthlyRemaining, dailyRemaining };
  }
  return { ok: true, monthlyRemaining, dailyRemaining };
}

function integerParam(parameters: Record<string, { defaultValue?: unknown }>, key: string): number | undefined {
  const raw = remoteConfigStringValue(parameters[key]?.defaultValue);
  if (raw == null) return undefined;
  const parsed = Number(raw);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : undefined;
}

/**
 * Load the curation limits + the `usage_curation_enabled` kill flag from the
 * Remote Config template (mirrors loadCloudProAllowanceConfig). Any template
 * read failure fails open to the compiled defaults — the kill flag therefore
 * defaults to ENABLED, matching the flag's documented default of true.
 */
export async function loadUsageCurationLimitsConfig(): Promise<UsageCurationLimitsConfig> {
  try {
    const template = await getRemoteConfig().getTemplate();
    const parameters = template.parameters ?? {};
    return normalizeUsageCurationLimitsConfig({
      usageCurationEnabled: remoteConfigStringValue(parameters["usage_curation_enabled"]?.defaultValue),
      textProMonthlyTokens: integerParam(parameters, "usage_curation_text_pro_monthly_tokens"),
      textProDailyTokens: integerParam(parameters, "usage_curation_text_pro_daily_tokens"),
      textProMaxMonthlyTokens: integerParam(parameters, "usage_curation_text_pro_max_monthly_tokens"),
      textProMaxDailyTokens: integerParam(parameters, "usage_curation_text_pro_max_daily_tokens"),
      multimodalProMaxMonthlyTokens: integerParam(parameters, "usage_curation_multimodal_pro_max_monthly_tokens"),
      multimodalProMaxDailyTokens: integerParam(parameters, "usage_curation_multimodal_pro_max_daily_tokens"),
      ultraMonthlyMultiplier: integerParam(parameters, "usage_curation_ultra_monthly_multiplier"),
      ultraDailyMultiplier: integerParam(parameters, "usage_curation_ultra_daily_multiplier"),
    });
  } catch (err) {
    logWarn({
      event: "usage_curation.remote_config_unavailable",
      error: errorMessage(err),
    });
    return DEFAULT_USAGE_CURATION_LIMITS_CONFIG;
  }
}
