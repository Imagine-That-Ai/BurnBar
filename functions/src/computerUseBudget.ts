/**
 * @fileoverview Computer Use — hourly budget guardrail.
 *
 * `evaluateComputerUseBudget` runs hourly. It pulls month-to-date
 * vision-model spend from `users/*\/computer_use_actions/*` and
 * `ops/computer_use_session_daily_rollups/days/*`, projects month-end,
 * and writes `ops/computer_use_budget_status/state/current`.
 *
 * Levels mirror the plan's E.3:
 *   normal    — projected < $1500/mo
 *   soft_cap  — $1500 ≤ projected < $2500  (envelope tightens)
 *   hard_cap  — projected ≥ $2500           (kill switch flips)
 *
 * Operator runbook: docs/runbooks/computer-use-budget.md.
 */

import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { getRemoteConfig } from "firebase-admin/remote-config";
import type { ComputerUseBudgetStatusDoc } from "./types.js";
import { syncKillSwitchForBudgetLevel } from "./computerUseRemoteConfig.js";
import { numberField } from "./guards.js";
import { logError, logInfo, logWarn } from "./logging.js";
import { remoteConfigStringValue } from "./remoteConfigGuards.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const SOFT_CAP_USD = 1500;
const HARD_CAP_USD = 2500;

interface BudgetTunings {
  softCapUSD: number;
  hardCapUSD: number;
  /**
   * Set when the Remote Config template could not be read at all (cold start,
   * offline, permission error). The caller MUST fail closed — clamp to
   * `hard_cap` — rather than evaluate spend against the optimistic in-code
   * defaults, since a read failure means we cannot trust the live caps (or the
   * month-to-date projection) to be below the real operator-tuned ceiling.
   */
  failClosed: boolean;
}

async function loadBudgetTunings(): Promise<BudgetTunings> {
  try {
    const template = await getRemoteConfig().getTemplate();
    const params = template.parameters ?? {};
    const firstNumber = (keys: string[]): number | undefined => {
      for (const key of keys) {
        const parsed = parseFloat(remoteConfigStringValue(params[key]?.defaultValue) ?? "");
        if (Number.isFinite(parsed) && parsed > 0) return parsed;
      }
      return undefined;
    };
    const soft = firstNumber(["computer_use_budget_soft_usd", "computer_use_budget_soft_cap_usd"]);
    const hard = firstNumber(["computer_use_budget_hard_usd", "computer_use_budget_hard_cap_usd"]);
    if (soft != null && hard != null && hard <= soft) {
      // Configuration sanity — a hard cap at or below the soft cap would skip
      // the soft-cap tier entirely. Fall back to the in-code defaults (Remote
      // Config WAS readable, so this is not a fail-closed condition) but never
      // swallow it: surface the bad values so ops can correct the template.
      logWarn({
        event: "computer_use_budget_invalid_remote_config",
        hard_cap_usd: hard,
        soft_cap_usd: soft,
      });
      return { softCapUSD: SOFT_CAP_USD, hardCapUSD: HARD_CAP_USD, failClosed: false };
    }
    return {
      softCapUSD: soft ?? SOFT_CAP_USD,
      hardCapUSD: hard ?? HARD_CAP_USD,
      failClosed: false,
    };
  } catch (err) {
    // Fail closed + observable: a Remote Config read failure makes the live caps
    // unknown, so we flag `failClosed` (the caller clamps to `hard_cap`) instead
    // of silently trusting the optimistic in-code defaults — the exact fail-open
    // hole R-L3 closes. Never swallow: log via the structured logger AND capture
    // to Sentry so an RC outage degrading the kill-switch guardrail is visible.
    logError({
      event: "computer_use_budget_remote_config_unavailable",
      error: String(err),
      fail_closed: true,
    });
    const { captureException } = await import("./sentry.js");
    captureException(err, {
      scheduled_job: "evaluateComputerUseBudget",
      stage: "load_budget_tunings",
    });
    return { softCapUSD: SOFT_CAP_USD, hardCapUSD: HARD_CAP_USD, failClosed: true };
  }
}

function dayKeyUTC(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function daysInMonth(year: number, monthIndex: number): number {
  return new Date(year, monthIndex + 1, 0).getDate();
}

interface MonthSpend {
  monthToDateUSD: number;
  daysElapsed: number;
  daysInMonth: number;
}

async function sumMonthToDate(now: Date): Promise<MonthSpend> {
  const firestore = getFirestore();
  const year = now.getUTCFullYear();
  const monthIdx = now.getUTCMonth();
  const daysTotal = daysInMonth(year, monthIdx);
  const todayKey = dayKeyUTC(now);
  const startOfMonth = `${year}-${String(monthIdx + 1).padStart(2, "0")}-01`;

  const snap = await firestore
    .collection("ops/computer_use_session_daily_rollups/days")
    .where("dayKey", ">=", startOfMonth)
    .where("dayKey", "<=", todayKey)
    .get();

  let total = 0;
  for (const doc of snap.docs) {
    total += budgetedRollupVisionSpendUSD(doc.data());
  }
  const elapsed = Math.max(1, Math.min(now.getUTCDate(), daysTotal));
  return { monthToDateUSD: total, daysElapsed: elapsed, daysInMonth: daysTotal };
}

function budgetedRollupVisionSpendUSD(data: Record<string, unknown>): number {
  const hasCappedSpend = Object.prototype.hasOwnProperty.call(data, "cappedVisionModelSpendUSD");
  const cappedSpend = numberField(data, "cappedVisionModelSpendUSD");
  if (cappedSpend != null && cappedSpend >= 0) return cappedSpend;
  if (hasCappedSpend) return 0;

  const legacyActualSpend = numberField(data, "visionModelSpendUSD");
  if (legacyActualSpend != null && legacyActualSpend >= 0) return legacyActualSpend;

  return 0;
}

function envelope(
  level: ComputerUseBudgetStatusDoc["level"],
): Omit<ComputerUseBudgetStatusDoc, "level" | "monthToDateUSD" | "projectedMonthEndUSD" | "updatedAt"> {
  switch (level) {
    case "normal":
      return {
        activeActionsPerRun: 50,
        activeActionsPerDay: 200,
        activeSessionsPerDay: 4,
        perUserDailySpendCeilingUSD: 5.0,
      };
    case "soft_cap":
      return {
        activeActionsPerRun: 25,
        activeActionsPerDay: 100,
        activeSessionsPerDay: 2,
        perUserDailySpendCeilingUSD: 2.5,
      };
    case "hard_cap":
      return {
        activeActionsPerRun: 0,
        activeActionsPerDay: 0,
        activeSessionsPerDay: 0,
        perUserDailySpendCeilingUSD: 0,
      };
  }
}

function pickLevel(projected: number, tunings: BudgetTunings): ComputerUseBudgetStatusDoc["level"] {
  if (projected >= tunings.hardCapUSD) return "hard_cap";
  if (projected >= tunings.softCapUSD) return "soft_cap";
  return "normal";
}

export const __testing__ = {
  budgetedRollupVisionSpendUSD,
  pickLevel,
};

/**
 * Single evaluation pass: pull month-to-date spend, project month-end, pick the
 * budget level, persist the public envelope + operator metrics, and sync the
 * Remote Config kill switch. When Remote Config could not be read the level is
 * clamped to `hard_cap` (kill-switch tier) so an RC outage can never re-open the
 * Computer Use budget. Exported for the fail-closed regression test; the
 * scheduled entry point below wraps this in Sentry capture + structured logging.
 */
export async function evaluateComputerUseBudgetOnce(
  now: Date = new Date(),
): Promise<{ level: ComputerUseBudgetStatusDoc["level"]; monthToDateUSD: number; projectedMonthEndUSD: number }> {
  const tunings = await loadBudgetTunings();
  const { monthToDateUSD, daysElapsed, daysInMonth: total } = await sumMonthToDate(now);
  const projected = monthToDateUSD * (total / Math.max(daysElapsed, 1));
  // Fail closed: an unreadable Remote Config template leaves the live caps
  // unknown, so clamp to the kill-switch tier regardless of projected spend
  // instead of trusting the optimistic in-code defaults (which would evaluate
  // `normal` and skip the gate entirely).
  const level = tunings.failClosed ? "hard_cap" : pickLevel(projected, tunings);
  const env = envelope(level);

  const publicEnvelope = {
    level,
    ...env,
    updatedAt: Timestamp.fromDate(now),
  };
  const operatorMetrics = {
    level,
    projectedMonthEndUSD: Math.round(projected * 100) / 100,
    monthToDateUSD: Math.round(monthToDateUSD * 100) / 100,
    updatedAt: Timestamp.fromDate(now),
  };

  const firestore = getFirestore();
  await firestore.doc("ops/computer_use_budget_status/state/current").set(publicEnvelope, { merge: true });
  await firestore.doc("ops/computer_use_budget_status/metrics/current").set(operatorMetrics, { merge: true });
  await syncKillSwitchForBudgetLevel(level);
  logInfo({
    event: "computer_use_budget_evaluated",
    level,
    month_to_date_usd: operatorMetrics.monthToDateUSD,
    projected_month_end_usd: operatorMetrics.projectedMonthEndUSD,
    fail_closed: tunings.failClosed,
  });
  return {
    level,
    monthToDateUSD: operatorMetrics.monthToDateUSD,
    projectedMonthEndUSD: operatorMetrics.projectedMonthEndUSD,
  };
}

export const evaluateComputerUseBudget = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "UTC",
    region: FUNCTIONS_REGION,
    timeoutSeconds: 540,
  },
  async () => {
    try {
      await evaluateComputerUseBudgetOnce(new Date());
    } catch (err) {
      // Fail loud on the safety path: the kill-switch publish
      // (syncKillSwitchForBudgetLevel) and the status writes are what keep the
      // gate honest, so a failure here must reach Sentry and rethrow to fail the
      // scheduled run for retry — never swallow it silently.
      logError({
        event: "computer_use_budget_evaluate_failed",
        error: String(err),
      });
      const { captureException } = await import("./sentry.js");
      captureException(err, { scheduled_job: "evaluateComputerUseBudget" });
      throw err;
    }
  },
);
