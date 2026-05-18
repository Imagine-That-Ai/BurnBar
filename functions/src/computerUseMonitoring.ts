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
import type {
  ComputerUseActionDoc,
  ComputerUseSessionDailyRollupDoc,
  ComputerUseSessionDoc,
} from "./types.js";

function dayKeyUTC(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function percentile(sortedAscending: number[], p: number): number {
  if (sortedAscending.length === 0) return 0;
  const rank = Math.min(
    sortedAscending.length - 1,
    Math.floor(p * sortedAscending.length),
  );
  return sortedAscending[rank];
}

export const rollupComputerUseDaily = onSchedule(
  {
    schedule: "30 0 * * *",
    timeZone: "UTC",
    region: "us-central1",
    timeoutSeconds: 540,
  },
  async () => {
    const firestore = getFirestore();
    const now = new Date();
    const yesterday = new Date(now.getTime() - 24 * 60 * 60 * 1000);
    const dayKey = dayKeyUTC(yesterday);
    const dayStart = new Date(`${dayKey}T00:00:00Z`);
    const dayEnd = new Date(dayStart.getTime() + 24 * 60 * 60 * 1000);

    const sessionSnap = await firestore
      .collectionGroup("computer_use_sessions")
      .where("startedAt", ">=", Timestamp.fromDate(dayStart))
      .where("startedAt", "<", Timestamp.fromDate(dayEnd))
      .get();
    const actionSnap = await firestore
      .collectionGroup("computer_use_actions")
      .where("recordedAt", ">=", Timestamp.fromDate(dayStart))
      .where("recordedAt", "<", Timestamp.fromDate(dayEnd))
      .get();

    const sessions = sessionSnap.docs.map(
      (d) => d.data() as ComputerUseSessionDoc,
    );
    const actions = actionSnap.docs.map(
      (d) => d.data() as ComputerUseActionDoc,
    );

    const latencyMs = actions
      .map((a) => a.approvalLatencyMillis)
      .filter((v): v is number => typeof v === "number" && Number.isFinite(v))
      .sort((a, b) => a - b);

    const scopeViolations = actions.filter(
      (a) => a.status === "denied" && a.denyReason === "scope_denied",
    ).length;
    const panicHalts = sessions.filter((s) => (s.endReason ?? "").startsWith("panic_")).length;
    const visionSpend = actions.reduce(
      (acc, a) => acc + (a.visionTokensCostUSD ?? 0),
      0,
    );

    const rollup: ComputerUseSessionDailyRollupDoc = {
      dayKey,
      sessionsStarted: sessions.length,
      sessionsCompleted: sessions.filter((s) => s.endReason === "completed").length,
      browserActionsExecuted: actions.filter(
        (a) => a.toolKind.startsWith("browser_") && a.status === "executed",
      ).length,
      browserActionsRejected: actions.filter(
        (a) => a.toolKind.startsWith("browser_") && a.status !== "executed",
      ).length,
      systemActionsExecuted: actions.filter(
        (a) => (a.toolKind.startsWith("mac_input_") || a.toolKind === "mac_inspect_accessibility") &&
          a.status === "executed",
      ).length,
      systemActionsRejected: actions.filter(
        (a) => (a.toolKind.startsWith("mac_input_") || a.toolKind === "mac_inspect_accessibility") &&
          a.status !== "executed",
      ).length,
      phoneControlIntents: actions.filter((a) => a.approvedBy === "phone").length,
      scopeViolations,
      panicHaltCount: panicHalts,
      approvalLatencyP50Millis: percentile(latencyMs, 0.5),
      approvalLatencyP95Millis: percentile(latencyMs, 0.95),
      approvalLatencyP99Millis: percentile(latencyMs, 0.99),
      visionModelSpendUSD: Math.round(visionSpend * 100) / 100,
      updatedAt: Timestamp.fromDate(now),
    };

    await firestore
      .doc(`ops/computer_use_session_daily_rollups/days/${dayKey}`)
      .set(rollup, { merge: true });
  },
);
