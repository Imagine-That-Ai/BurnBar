/**
 * @fileoverview Mercury Phase 5 — n0 hosted-relay budget guardrail.
 *
 * `evaluateMediaBudget` runs hourly. It pulls month-to-date hosted-relay
 * spend (from `ops/media_session_daily_rollups/days/*` aggregation) and
 * projects month-end. Levels per Decision 4:
 *
 *   normal     — projected < $600/mo
 *   soft_cap   — $600 ≤ projected < $1000  (envelope tightens)
 *   hard_cap   — projected ≥ $1000          (kill-switch flips)
 *
 * Writes `ops/media_budget_status/current`. Operator runbook lives at
 * `docs/runbooks/media-budget.md`.
 */

import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import type { MediaBudgetStatusDoc, MediaSessionDailyRollupDoc } from "./types.js";

const SOFT_CAP_USD = 600;
const HARD_CAP_USD = 1000;
const COST_PER_GB_USD = 0.04; // Conservative n0 hosted-relay rate; tune from invoices.

const NORMAL_ENVELOPE = {
  screenShareDailyMinutes: 120,
  screenSharePerSessionMinutes: 60,
  videoCallDailyMinutes: 240,
  videoCallPerCallMinutes: 30,
  fileTransferDailyGBIn: 5,
  fileTransferDailyGBOut: 5,
};

const SOFT_CAP_ENVELOPE = {
  screenShareDailyMinutes: 30,
  screenSharePerSessionMinutes: 30,
  videoCallDailyMinutes: 120,
  videoCallPerCallMinutes: 20,
  fileTransferDailyGBIn: 2,
  fileTransferDailyGBOut: 2,
};

const HARD_CAP_ENVELOPE = {
  screenShareDailyMinutes: 0,
  screenSharePerSessionMinutes: 0,
  videoCallDailyMinutes: 0,
  videoCallPerCallMinutes: 0,
  fileTransferDailyGBIn: 0,
  fileTransferDailyGBOut: 0,
};

function startOfMonthUTC(now: Date): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
}

function endOfMonthUTC(now: Date): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
}

export async function evaluateBudget(now: Date = new Date()): Promise<MediaBudgetStatusDoc> {
  const firestore = getFirestore();
  const monthStart = startOfMonthUTC(now);
  const monthEnd = endOfMonthUTC(now);

  const rollups = await firestore
    .collection("ops/media_session_daily_rollups/days")
    .where("date", ">=", monthStart.toISOString().slice(0, 10))
    .where("date", "<", monthEnd.toISOString().slice(0, 10))
    .get();

  let totalBytes = 0;
  for (const doc of rollups.docs) {
    const data = doc.data() as MediaSessionDailyRollupDoc;
    for (const feature of Object.keys(data.perFeature ?? {})) {
      totalBytes += data.perFeature[feature as "fileTransfer" | "screenShare" | "videoCall"]?.totalBytes ?? 0;
    }
  }

  const totalGB = totalBytes / 1_000_000_000;
  const monthToDateUSD = totalGB * COST_PER_GB_USD;

  const elapsedDays = Math.max(1, Math.ceil((now.getTime() - monthStart.getTime()) / (24 * 60 * 60 * 1000)));
  const totalDaysInMonth = Math.max(1, Math.ceil((monthEnd.getTime() - monthStart.getTime()) / (24 * 60 * 60 * 1000)));
  const projectedMonthEndUSD = (monthToDateUSD / elapsedDays) * totalDaysInMonth;

  let level: MediaBudgetStatusDoc["level"];
  let envelope: typeof NORMAL_ENVELOPE;
  if (projectedMonthEndUSD >= HARD_CAP_USD) {
    level = "hard_cap";
    envelope = HARD_CAP_ENVELOPE;
  } else if (projectedMonthEndUSD >= SOFT_CAP_USD) {
    level = "soft_cap";
    envelope = SOFT_CAP_ENVELOPE;
  } else {
    level = "normal";
    envelope = NORMAL_ENVELOPE;
  }

  const status: MediaBudgetStatusDoc = {
    level,
    projectedMonthEndUSD,
    monthToDateUSD,
    lastEvaluatedAt: Timestamp.now(),
    activeEnvelope: envelope,
    schemaVersion: 1,
  };

  await firestore.doc("ops/media_budget_status/current").set(status, { merge: true });
  return status;
}

export const evaluateMediaBudget = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "UTC",
    region: "us-central1",
  },
  async () => {
    await evaluateBudget(new Date());
  }
);
