/**
 * @fileoverview Pure Cloud Pro allowance accounting helpers.
 */

export const CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION = 1;
export const CLOUD_PRO_INCLUDED_HOSTED_ACTIONS_MONTHLY = 500;
export const CLOUD_PRO_INCLUDED_RELAY_GB_MONTHLY = 50;
export const CLOUD_PRO_ACTION_TOP_UP_UNIT = 100;
export const CLOUD_PRO_RELAY_TOP_UP_UNIT_GB = 50;
export const CLOUD_PRO_MONTHLY_HOSTED_ACTION_CAP = 2000;
export const CLOUD_PRO_MONTHLY_RELAY_GB_CAP = 300;

export type CloudProAllowanceMeter = "hosted_actions" | "relay_gb";
export type CloudProTopUpKind = "agent_control_actions_100" | "floo_relay_50gb";

export interface CloudProAllowanceConfig {
  includedHostedActionsMonthly: number;
  includedRelayGBMonthly: number;
  actionTopUpUnit: number;
  relayTopUpUnitGB: number;
  monthlyHostedActionCap: number;
  monthlyRelayGBCap: number;
}

export const DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG: CloudProAllowanceConfig = Object.freeze({
  includedHostedActionsMonthly: CLOUD_PRO_INCLUDED_HOSTED_ACTIONS_MONTHLY,
  includedRelayGBMonthly: CLOUD_PRO_INCLUDED_RELAY_GB_MONTHLY,
  actionTopUpUnit: CLOUD_PRO_ACTION_TOP_UP_UNIT,
  relayTopUpUnitGB: CLOUD_PRO_RELAY_TOP_UP_UNIT_GB,
  monthlyHostedActionCap: CLOUD_PRO_MONTHLY_HOSTED_ACTION_CAP,
  monthlyRelayGBCap: CLOUD_PRO_MONTHLY_RELAY_GB_CAP,
});

export interface CloudProAllowanceSnapshot {
  includedUnits: number;
  usedUnits: number;
  topUpUnits: number;
  monthlyCap: number;
}

export interface CloudProAllowanceReservationInput extends CloudProAllowanceSnapshot {
  requestedUnits: number;
}

export interface CloudProAllowanceReservationResult {
  ok: boolean;
  reason?: "invalid_request" | "allowance_exhausted" | "monthly_cap_exceeded";
  requestedUnits: number;
  availableUnits: number;
  monthlyCapRemaining: number;
  usedAfter: number;
}

export function allowanceDocPath(uid: string, monthKey: string): string {
  return `users/${uid}/billing/allowances/months/${monthKey}`;
}

export function monthKeyForDate(date: Date): string {
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  return `${year}-${month}`;
}

function positiveInteger(raw: unknown, fallback: number): number {
  const value = typeof raw === "number" ? raw : Number(raw);
  return Number.isFinite(value) && Number.isInteger(value) && value > 0 ? value : fallback;
}

export function normalizeCloudProAllowanceConfig(
  overrides: Partial<Record<keyof CloudProAllowanceConfig, unknown>>,
): CloudProAllowanceConfig {
  const includedHostedActionsMonthly = positiveInteger(
    overrides.includedHostedActionsMonthly,
    DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG.includedHostedActionsMonthly,
  );
  const includedRelayGBMonthly = positiveInteger(
    overrides.includedRelayGBMonthly,
    DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG.includedRelayGBMonthly,
  );
  const actionTopUpUnit = positiveInteger(
    overrides.actionTopUpUnit,
    DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG.actionTopUpUnit,
  );
  const relayTopUpUnitGB = positiveInteger(
    overrides.relayTopUpUnitGB,
    DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG.relayTopUpUnitGB,
  );
  const rawHostedCap = positiveInteger(
    overrides.monthlyHostedActionCap,
    DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG.monthlyHostedActionCap,
  );
  const rawRelayCap = positiveInteger(
    overrides.monthlyRelayGBCap,
    DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG.monthlyRelayGBCap,
  );

  return {
    includedHostedActionsMonthly,
    includedRelayGBMonthly,
    actionTopUpUnit,
    relayTopUpUnitGB,
    monthlyHostedActionCap:
      rawHostedCap >= includedHostedActionsMonthly
        ? rawHostedCap
        : DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG.monthlyHostedActionCap,
    monthlyRelayGBCap:
      rawRelayCap >= includedRelayGBMonthly ? rawRelayCap : DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG.monthlyRelayGBCap,
  };
}

export function defaultsForAllowanceMeter(
  meter: CloudProAllowanceMeter,
  config: CloudProAllowanceConfig = DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG,
): CloudProAllowanceSnapshot {
  if (meter === "relay_gb") {
    return {
      includedUnits: config.includedRelayGBMonthly,
      usedUnits: 0,
      topUpUnits: 0,
      monthlyCap: config.monthlyRelayGBCap,
    };
  }
  return {
    includedUnits: config.includedHostedActionsMonthly,
    usedUnits: 0,
    topUpUnits: 0,
    monthlyCap: config.monthlyHostedActionCap,
  };
}

export function evaluateCloudProAllowanceReservation(
  input: CloudProAllowanceReservationInput,
): CloudProAllowanceReservationResult {
  if (!Number.isFinite(input.requestedUnits) || input.requestedUnits <= 0) {
    return {
      ok: false,
      reason: "invalid_request",
      requestedUnits: input.requestedUnits,
      availableUnits: 0,
      monthlyCapRemaining: 0,
      usedAfter: input.usedUnits,
    };
  }

  const availableUnits = Math.max(0, input.includedUnits + input.topUpUnits - input.usedUnits);
  const monthlyCapRemaining = Math.max(0, input.monthlyCap - input.usedUnits);
  const usedAfter = input.usedUnits + input.requestedUnits;

  if (input.requestedUnits > monthlyCapRemaining) {
    return {
      ok: false,
      reason: "monthly_cap_exceeded",
      requestedUnits: input.requestedUnits,
      availableUnits,
      monthlyCapRemaining,
      usedAfter,
    };
  }

  if (input.requestedUnits > availableUnits) {
    return {
      ok: false,
      reason: "allowance_exhausted",
      requestedUnits: input.requestedUnits,
      availableUnits,
      monthlyCapRemaining,
      usedAfter,
    };
  }

  return {
    ok: true,
    requestedUnits: input.requestedUnits,
    availableUnits,
    monthlyCapRemaining,
    usedAfter,
  };
}

export function unitsForCloudProTopUp(
  kind: CloudProTopUpKind,
  quantity = 1,
  config: CloudProAllowanceConfig = DEFAULT_CLOUD_PRO_ALLOWANCE_CONFIG,
): {
  meter: CloudProAllowanceMeter;
  units: number;
} {
  const normalizedQuantity = Number.isFinite(quantity) && quantity > 0 ? Math.floor(quantity) : 1;
  switch (kind) {
    case "agent_control_actions_100":
      return {
        meter: "hosted_actions",
        units: config.actionTopUpUnit * normalizedQuantity,
      };
    case "floo_relay_50gb":
      return {
        meter: "relay_gb",
        units: config.relayTopUpUnitGB * normalizedQuantity,
      };
  }
}
