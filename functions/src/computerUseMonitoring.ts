/**
 * @fileoverview Computer Use — daily session monitoring rollup.
 *
 * `rollupComputerUseDaily` runs once per day at 00:30 UTC. It reads
 * the prior day's `users/*\/computer_use_sessions/*` and
 * `users/*\/computer_use_actions/*` and writes a single denormalized
 * `ops/computer_use_session_daily_rollups/days/{YYYY-MM-DD}` doc with
 * per-tool counters, p50 / p95 / p99 approval latency, scope-violation
 * count, panic-halt count, and total vision spend.
 *
 * This document feeds the Looker Studio dashboard
 * `computer-use-budget`. It is also the input to
 * `evaluateComputerUseBudget`'s month-to-date sum.
 */

import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { numberField, stringField } from "./guards.js";
import { forEachInPages } from "./rollupPagination.js";
import type { ComputerUseSessionDailyRollupDoc } from "./types.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const MAX_ROLLUP_SESSIONS_PER_USER_PER_DAY = 4;
const MAX_ROLLUP_ACTIONS_PER_USER_PER_DAY = 200;
const MAX_ROLLUP_VISION_SPEND_USD_PER_USER_PER_DAY = 5;
const MAX_ROLLUP_VISION_SPEND_USD_PER_ACTION = 25;

function dayKeyUTC(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function percentile(sortedAscending: number[], p: number): number {
  if (sortedAscending.length === 0) return 0;
  const rank = Math.min(sortedAscending.length - 1, Math.floor(p * sortedAscending.length));
  return sortedAscending[rank];
}

function uidFromComputerUseCollectionPath(path: string, collectionId: string): string | null {
  const parts = path.split("/");
  if (parts.length === 4 && parts[0] === "users" && parts[2] === collectionId && parts[1] && parts[3]) {
    return parts[1];
  }
  return null;
}

function shouldIncludeUserScopedRollupDoc(
  path: string,
  collectionId: string,
  seenByUser: Map<string, number>,
  perUserLimit: number,
): string | null {
  const userId = uidFromComputerUseCollectionPath(path, collectionId);
  if (!userId) return null;
  const seen = seenByUser.get(userId) ?? 0;
  if (seen >= perUserLimit) return null;
  seenByUser.set(userId, seen + 1);
  return userId;
}

function sanitizedVisionSpendContribution(rawCost: number | undefined): number {
  if (typeof rawCost !== "number" || !Number.isFinite(rawCost) || rawCost <= 0) return 0;
  return Math.min(rawCost, MAX_ROLLUP_VISION_SPEND_USD_PER_ACTION);
}

function boundedVisionSpendContribution(currentUserTotal: number, rawCost: number | undefined): number {
  const sanitizedCost = sanitizedVisionSpendContribution(rawCost);
  if (sanitizedCost <= 0) return 0;
  const remaining = Math.max(0, MAX_ROLLUP_VISION_SPEND_USD_PER_USER_PER_DAY - currentUserTotal);
  return Math.min(sanitizedCost, remaining);
}

export const __testing__ = {
  boundedVisionSpendContribution,
  sanitizedVisionSpendContribution,
  uidFromComputerUseCollectionPath,
  limits: {
    maxRollupActionsPerUserPerDay: MAX_ROLLUP_ACTIONS_PER_USER_PER_DAY,
    maxRollupSessionsPerUserPerDay: MAX_ROLLUP_SESSIONS_PER_USER_PER_DAY,
    maxRollupVisionSpendUSDPerUserPerDay: MAX_ROLLUP_VISION_SPEND_USD_PER_USER_PER_DAY,
    maxRollupVisionSpendUSDPerAction: MAX_ROLLUP_VISION_SPEND_USD_PER_ACTION,
  },
};

export const rollupComputerUseDaily = onSchedule(
  {
    schedule: "30 0 * * *",
    timeZone: "UTC",
    region: FUNCTIONS_REGION,
    memory: "1GiB",
    timeoutSeconds: 540,
  },
  async () => {
    const firestore = getFirestore();
    const now = new Date();
    const yesterday = new Date(now.getTime() - 24 * 60 * 60 * 1000);
    const dayKey = dayKeyUTC(yesterday);
    const dayStart = new Date(`${dayKey}T00:00:00Z`);
    const dayEnd = new Date(dayStart.getTime() + 24 * 60 * 60 * 1000);

    const sessionQuery = firestore
      .collectionGroup("computer_use_sessions")
      .where("startedAt", ">=", Timestamp.fromDate(dayStart))
      .where("startedAt", "<", Timestamp.fromDate(dayEnd));
    const actionQuery = firestore
      .collectionGroup("computer_use_actions")
      .where("recordedAt", ">=", Timestamp.fromDate(dayStart))
      .where("recordedAt", "<", Timestamp.fromDate(dayEnd));

    // Stream both day-ranges in bounded pages so a high-volume day cannot OOM the rollup.
    const sessions: Array<{ endReason: string | undefined }> = [];
    const sessionCountsByUser = new Map<string, number>();
    await forEachInPages(sessionQuery, "startedAt", (d) => {
      const userId = shouldIncludeUserScopedRollupDoc(
        d.ref.path,
        "computer_use_sessions",
        sessionCountsByUser,
        MAX_ROLLUP_SESSIONS_PER_USER_PER_DAY,
      );
      if (!userId) return;
      const data = d.data();
      sessions.push({ endReason: stringField(data, "endReason") });
    });
    const actions: Array<{
      approvalLatencyMillis: number | undefined;
      status: string | undefined;
      denyReason: string | undefined;
      visionTokensCostUSD: number | undefined;
      cappedVisionTokensCostUSD: number | undefined;
      toolKind: string;
      approvedBy: string | undefined;
    }> = [];
    const actionCountsByUser = new Map<string, number>();
    const visionSpendByUser = new Map<string, number>();
    await forEachInPages(actionQuery, "recordedAt", (d) => {
      const userId = shouldIncludeUserScopedRollupDoc(
        d.ref.path,
        "computer_use_actions",
        actionCountsByUser,
        MAX_ROLLUP_ACTIONS_PER_USER_PER_DAY,
      );
      if (!userId) return;
      const data = d.data();
      const currentVisionSpend = visionSpendByUser.get(userId) ?? 0;
      const visionTokensCostUSD = sanitizedVisionSpendContribution(numberField(data, "visionTokensCostUSD"));
      const cappedVisionTokensCostUSD = boundedVisionSpendContribution(currentVisionSpend, visionTokensCostUSD);
      visionSpendByUser.set(userId, currentVisionSpend + cappedVisionTokensCostUSD);
      actions.push({
        approvalLatencyMillis: numberField(data, "approvalLatencyMillis"),
        status: stringField(data, "status"),
        denyReason: stringField(data, "denyReason"),
        visionTokensCostUSD,
        cappedVisionTokensCostUSD,
        toolKind: stringField(data, "toolKind") ?? "",
        approvedBy: stringField(data, "approvedBy"),
      });
    });

    const latencyMs = actions
      .map((a) => a.approvalLatencyMillis)
      .filter((v): v is number => typeof v === "number" && Number.isFinite(v))
      .sort((a, b) => a - b);

    const scopeViolations = actions.filter((a) => a.status === "denied" && a.denyReason === "scope_denied").length;
    const panicHalts = sessions.filter((s) => (s.endReason ?? "").startsWith("panic_")).length;
    const visionSpend = actions.reduce((acc, a) => acc + (a.visionTokensCostUSD ?? 0), 0);
    const cappedVisionSpend = actions.reduce((acc, a) => acc + (a.cappedVisionTokensCostUSD ?? 0), 0);

    const rollup: ComputerUseSessionDailyRollupDoc = {
      dayKey,
      sessionsStarted: sessions.length,
      sessionsCompleted: sessions.filter((s) => s.endReason === "completed").length,
      browserActionsExecuted: actions.filter((a) => a.toolKind.startsWith("browser_") && a.status === "executed")
        .length,
      browserActionsRejected: actions.filter((a) => a.toolKind.startsWith("browser_") && a.status !== "executed")
        .length,
      systemActionsExecuted: actions.filter(
        (a) =>
          (a.toolKind.startsWith("mac_input_") || a.toolKind === "mac_inspect_accessibility") &&
          a.status === "executed",
      ).length,
      systemActionsRejected: actions.filter(
        (a) =>
          (a.toolKind.startsWith("mac_input_") || a.toolKind === "mac_inspect_accessibility") &&
          a.status !== "executed",
      ).length,
      phoneControlIntents: actions.filter((a) => a.approvedBy === "phone").length,
      scopeViolations,
      panicHaltCount: panicHalts,
      approvalLatencyP50Millis: percentile(latencyMs, 0.5),
      approvalLatencyP95Millis: percentile(latencyMs, 0.95),
      approvalLatencyP99Millis: percentile(latencyMs, 0.99),
      visionModelSpendUSD: Math.round(visionSpend * 100) / 100,
      cappedVisionModelSpendUSD: Math.round(cappedVisionSpend * 100) / 100,
      updatedAt: Timestamp.fromDate(now),
    };

    await firestore.doc(`ops/computer_use_session_daily_rollups/days/${dayKey}`).set(rollup, { merge: true });
  },
);
