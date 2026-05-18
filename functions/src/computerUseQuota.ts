/**
 * @fileoverview Computer Use — daily quota rollup.
 *
 * `recomputeComputerUseQuotaUsage` runs hourly. For every active user
 * it walks `users/{uid}/computer_use_actions/*` for the current UTC
 * day, sums per-tool counts and vision spend, and writes the canonical
 * `users/{uid}/computer_use_quota_usage/<YYYY-MM-DD>` document.
 *
 * The Mac coordinator writes a *live* mirror to this document every
 * 30 s. This rollup is the source-of-truth correction for any drift
 * (clock skew, missed writes, malicious local mutation).
 */

import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import type {
  ComputerUseActionDoc,
  ComputerUseQuotaUsageDoc,
} from "./types.js";

function dayKeyUTC(date: Date): string {
  return date.toISOString().slice(0, 10);
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

  const counters: ComputerUseQuotaUsageDoc = {
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
    updatedAt: Timestamp.fromDate(new Date()),
  };

  for (const docSnap of snap.docs) {
    const action = docSnap.data() as ComputerUseActionDoc;
    const isBrowser = action.toolKind.startsWith("browser_");
    const isSystem = action.toolKind.startsWith("mac_input_") ||
      action.toolKind === "mac_inspect_accessibility";
    const isPhone = action.approvedBy === "phone";

    if (action.status === "executed") {
      if (isBrowser) counters.browserActionsExecuted += 1;
      else if (isSystem) counters.systemActionsExecuted += 1;
      if (isPhone) counters.phoneControlIntentsExecuted += 1;
    } else if (action.status === "denied" || action.status === "rejected") {
      if (isBrowser) counters.browserActionsRejected += 1;
      else if (isSystem) counters.systemActionsRejected += 1;
      if (isPhone) counters.phoneControlIntentsRejected += 1;
    }
    counters.visionModelSpendUSD += action.visionTokensCostUSD ?? 0;
  }

  await firestore
    .doc(`users/${uid}/computer_use_quota_usage/${dayKey}`)
    .set(counters, { merge: true });
}

export const recomputeComputerUseQuotaUsage = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "UTC",
    region: "us-central1",
    timeoutSeconds: 540,
  },
  async () => {
    const firestore = getFirestore();
    const todayKey = dayKeyUTC(new Date());
    // Use the live session document as the active-users index: a
    // session writes today means the user is in scope for the rollup
    // pass. This is cheaper than scanning every user.
    const startOfDay = new Date(`${todayKey}T00:00:00Z`);
    const sessions = await firestore
      .collectionGroup("computer_use_sessions")
      .where("startedAt", ">=", Timestamp.fromDate(startOfDay))
      .select("userId")
      .get();

    const seen = new Set<string>();
    for (const doc of sessions.docs) {
      const { userId } = doc.data() as { userId?: string };
      if (!userId || seen.has(userId)) continue;
      seen.add(userId);
      await recomputeForUser(userId, todayKey);
    }
  },
);
