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
import type {
  ComputerUseBudgetStatusDoc,
  ComputerUseSessionDailyRollupDoc,
} from "./types.js";

const SOFT_CAP_USD = 1500;
const HARD_CAP_USD = 2500;

interface BudgetTunings {
  softCapUSD: number;
  hardCapUSD: number;
}

async function loadBudgetTunings(): Promise<BudgetTunings> {
  try {
    const template = await getRemoteConfig().getTemplate();
    const params = template.parameters ?? {};
    const soft = parseFloat(
      (params.computer_use_budget_soft_cap_usd?.defaultValue as { value: string } | undefined)?.value ?? "",
    );
    const hard = parseFloat(
      (params.computer_use_budget_hard_cap_usd?.defaultValue as { value: string } | undefined)?.value ?? "",
    );
    return {
      softCapUSD: Number.isFinite(soft) ? soft : SOFT_CAP_USD,
      hardCapUSD: Number.isFinite(hard) ? hard : HARD_CAP_USD,
    };
  } catch (_e) {
    return { softCapUSD: SOFT_CAP_USD, hardCapUSD: HARD_CAP_USD };
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
    const data = doc.data() as ComputerUseSessionDailyRollupDoc;
    total += data.visionModelSpendUSD ?? 0;
  }
  const elapsed = Math.max(
    1,
    Math.min(now.getUTCDate(), daysTotal),
  );
  return { monthToDateUSD: total, daysElapsed: elapsed, daysInMonth: daysTotal };
}

function envelope(level: ComputerUseBudgetStatusDoc["level"]): Omit<
  ComputerUseBudgetStatusDoc,
  "level" | "monthToDateUSD" | "projectedMonthEndUSD" | "updatedAt"
> {
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

export const evaluateComputerUseBudget = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "UTC",
    region: "us-central1",
    timeoutSeconds: 540,
  },
  async () => {
    const tunings = await loadBudgetTunings();
    const now = new Date();
    const { monthToDateUSD, daysElapsed, daysInMonth: total } = await sumMonthToDate(now);
    const projected =
      monthToDateUSD * (total / Math.max(daysElapsed, 1));
    const level = pickLevel(projected, tunings);
    const env = envelope(level);

    const doc: ComputerUseBudgetStatusDoc = {
      level,
      projectedMonthEndUSD: Math.round(projected * 100) / 100,
      monthToDateUSD: Math.round(monthToDateUSD * 100) / 100,
      ...env,
      updatedAt: Timestamp.fromDate(now),
    };
    await getFirestore()
      .doc("ops/computer_use_budget_status/state/current")
      .set(doc, { merge: true });
  },
);
