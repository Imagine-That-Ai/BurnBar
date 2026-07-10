/**
 * @fileoverview Computer Use — daily quota rollup.
 *
 * `recomputeComputerUseQuotaUsage` runs hourly. For every active user it
 * walks immutable action/session headers for the current UTC day, reconstructs
 * counters, and writes the canonical
 * `users/{uid}/computer_use_quota_usage/<YYYY-MM-DD>` document.
 *
 * Immediate Firestore triggers advance this document in near real time. This
 * rollup is the source-of-truth correction for drift from missed triggers,
 * clock skew, and delayed offline writes.
 */

import { Timestamp, getFirestore, type DocumentData } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { numberField, stringField } from "./guards.js";
import type { ComputerUseQuotaUsageDoc } from "./types.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

function dayKeyUTC(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function emptyCounters(dayKey: string, updatedAt: Date = new Date()): ComputerUseQuotaUsageDoc {
  return {
    dayKey,
    browserActionsExecuted: 0,
    browserActionsRejected: 0,
    systemActionsExecuted: 0,
    systemActionsRejected: 0,
    phoneControlIntentsExecuted: 0,
    phoneControlIntentsRejected: 0,
    sessionsStarted: 0,
    sessionsCompleted: 0,
    totalSessionSeconds: 0,
    visionModelSpendUSD: 0,
    updatedAt: Timestamp.fromDate(updatedAt),
  };
}

function boundedVisionSpendUSD(value: unknown): number {
  const parsed = numberField({ value }, "value") ?? 0;
  if (!Number.isFinite(parsed) || parsed <= 0) return 0;
  return Math.min(25, parsed);
}

function isRejectedStatus(status: string | undefined): boolean {
  return status === "denied" || status === "rejected" || status === "error";
}

function recordActionCounters(counters: ComputerUseQuotaUsageDoc, action: DocumentData): void {
  const toolKind = stringField(action, "toolKind") ?? "";
  const isBrowser = toolKind.startsWith("browser_");
  const isSystem = toolKind.startsWith("mac_input_") || toolKind === "mac_inspect_accessibility";
  const isPhone = stringField(action, "approvedBy") === "phone";
  const status = stringField(action, "status");

  if (status === "executed") {
    if (isBrowser) counters.browserActionsExecuted += 1;
    else if (isSystem) counters.systemActionsExecuted += 1;
    if (isPhone) counters.phoneControlIntentsExecuted += 1;
  } else if (isRejectedStatus(status)) {
    if (isBrowser) counters.browserActionsRejected += 1;
    else if (isSystem) counters.systemActionsRejected += 1;
    if (isPhone) counters.phoneControlIntentsRejected += 1;
  }
  counters.visionModelSpendUSD += boundedVisionSpendUSD(action.visionTokensCostUSD);
}

function timestampMillis(value: unknown): number | null {
  if (value instanceof Timestamp) return value.toMillis();
  if (value instanceof Date) return value.getTime();
  return null;
}

function recordSessionCompletionCounters(counters: ComputerUseQuotaUsageDoc, session: DocumentData): void {
  counters.sessionsCompleted += 1;
  const startedAt = timestampMillis(session.startedAt);
  const endedAt = timestampMillis(session.endedAt);
  if (startedAt != null && endedAt != null) {
    counters.totalSessionSeconds += Math.max(0, Math.floor((endedAt - startedAt) / 1_000));
  }
}

async function recomputeForUser(uid: string, dayKey: string): Promise<void> {
  const firestore = getFirestore();
  const dayStart = new Date(`${dayKey}T00:00:00Z`);
  const dayEnd = new Date(dayStart.getTime() + 24 * 60 * 60 * 1000);

  const snap = await firestore
    .collection(`users/${uid}/computer_use_actions`)
    .where("recordedAt", ">=", Timestamp.fromDate(dayStart))
    .where("recordedAt", "<", Timestamp.fromDate(dayEnd))
    .get();

  const startedSessions = await firestore
    .collection(`users/${uid}/computer_use_sessions`)
    .where("startedAt", ">=", Timestamp.fromDate(dayStart))
    .where("startedAt", "<", Timestamp.fromDate(dayEnd))
    .get();

  const completedSessions = await firestore
    .collection(`users/${uid}/computer_use_sessions`)
    .where("endedAt", ">=", Timestamp.fromDate(dayStart))
    .where("endedAt", "<", Timestamp.fromDate(dayEnd))
    .get();

  const counters = emptyCounters(dayKey);

  for (const docSnap of snap.docs) {
    recordActionCounters(counters, docSnap.data());
  }
  counters.sessionsStarted = startedSessions.size;
  for (const docSnap of completedSessions.docs) {
    recordSessionCompletionCounters(counters, docSnap.data());
  }

  const quotaRef = firestore.doc(`users/${uid}/computer_use_quota_usage/${dayKey}`);
  await firestore.runTransaction(async (transaction) => {
    const current = await transaction.get(quotaRef);
    const existing = current.data() ?? {};
    counters.browserActionsExecuted = Math.max(
      counters.browserActionsExecuted,
      numberField(existing, "browserActionsExecuted") ?? 0,
    );
    counters.browserActionsRejected = Math.max(
      counters.browserActionsRejected,
      numberField(existing, "browserActionsRejected") ?? 0,
    );
    counters.systemActionsExecuted = Math.max(
      counters.systemActionsExecuted,
      numberField(existing, "systemActionsExecuted") ?? 0,
    );
    counters.systemActionsRejected = Math.max(
      counters.systemActionsRejected,
      numberField(existing, "systemActionsRejected") ?? 0,
    );
    counters.phoneControlIntentsExecuted = Math.max(
      counters.phoneControlIntentsExecuted,
      numberField(existing, "phoneControlIntentsExecuted") ?? 0,
    );
    counters.phoneControlIntentsRejected = Math.max(
      counters.phoneControlIntentsRejected,
      numberField(existing, "phoneControlIntentsRejected") ?? 0,
    );
    counters.sessionsStarted = Math.max(counters.sessionsStarted, numberField(existing, "sessionsStarted") ?? 0);
    counters.sessionsCompleted = Math.max(counters.sessionsCompleted, numberField(existing, "sessionsCompleted") ?? 0);
    counters.totalSessionSeconds = Math.max(
      counters.totalSessionSeconds,
      numberField(existing, "totalSessionSeconds") ?? 0,
    );
    counters.visionModelSpendUSD = Math.max(
      counters.visionModelSpendUSD,
      numberField(existing, "visionModelSpendUSD") ?? 0,
    );
    transaction.set(quotaRef, counters, { merge: false });
  });
}

function uidFromComputerUseSessionPath(path: string): string | null {
  const parts = path.split("/");
  if (parts.length === 4 && parts[0] === "users" && parts[2] === "computer_use_sessions" && parts[1] && parts[3]) {
    return parts[1];
  }
  return null;
}

function uidFromComputerUseActionPath(path: string): string | null {
  const parts = path.split("/");
  if (parts.length === 4 && parts[0] === "users" && parts[2] === "computer_use_actions" && parts[1] && parts[3]) {
    return parts[1];
  }
  return null;
}

export const __testing__ = {
  emptyCounters,
  recordActionCounters,
  recordSessionCompletionCounters,
  uidFromComputerUseActionPath,
  uidFromComputerUseSessionPath,
};

export const recomputeComputerUseQuotaUsage = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "UTC",
    region: FUNCTIONS_REGION,
    timeoutSeconds: 540,
  },
  async () => {
    const firestore = getFirestore();
    const todayKey = dayKeyUTC(new Date());
    // Use immutable action/session headers as the active-users index. This
    // recovers users even when one of the immediate metering triggers missed.
    const startOfDay = new Date(`${todayKey}T00:00:00Z`);
    const [startedSessions, endedSessions, actions] = await Promise.all([
      firestore
        .collectionGroup("computer_use_sessions")
        .where("startedAt", ">=", Timestamp.fromDate(startOfDay))
        .select()
        .get(),
      firestore
        .collectionGroup("computer_use_sessions")
        .where("endedAt", ">=", Timestamp.fromDate(startOfDay))
        .select()
        .get(),
      firestore
        .collectionGroup("computer_use_actions")
        .where("recordedAt", ">=", Timestamp.fromDate(startOfDay))
        .select()
        .get(),
    ]);

    const seen = new Set<string>();
    for (const doc of startedSessions.docs) {
      const userId = uidFromComputerUseSessionPath(doc.ref.path);
      if (!userId) continue;
      seen.add(userId);
    }
    for (const doc of endedSessions.docs) {
      const userId = uidFromComputerUseSessionPath(doc.ref.path);
      if (!userId) continue;
      seen.add(userId);
    }
    for (const doc of actions.docs) {
      const userId = uidFromComputerUseActionPath(doc.ref.path);
      if (!userId) continue;
      seen.add(userId);
    }

    for (const userId of seen) {
      await recomputeForUser(userId, todayKey);
    }
  },
);
