/**
 * @fileoverview Usage rollup computation.
 *
 * Reads raw usage events from Firestore, computes per-window aggregates, and
 * writes `usage_rollups/{windowKey}` documents.  All computation is idempotent:
 * re-running with the same input produces the same output.
 */

import { getFirestore, type Firestore } from "firebase-admin/firestore";
import type {
  UsageEventDoc,
  UsageRollupDoc,
  ProviderSummary,
  ModelSummary,
  DeviceSummary,
  RollupJobDoc,
} from "./types.js";

const ROLLUP_SCHEMA_VERSION = 1;

/** Window keys in ascending granularity order. */
const WINDOW_KEYS = ["today", "7d", "30d", "90d", "all_time"] as const;
export type WindowKey = (typeof WINDOW_KEYS)[number];

/**
 * Return the UTC date string (YYYY-MM-DD) for a given ISO timestamp.
 */
function toUtcDate(iso: string): string {
  const d = new Date(iso);
  return d.toISOString().slice(0, 10);
}

/**
 * Extract cost from a usage event, trying both field names used by
 * the desktop sync (`cost`) and the canonical schema (`costUsd`).
 */
function eventCost(ev: UsageEventDoc): number | undefined {
  const v = ev.costUsd ?? ev.cost;
  if (typeof v === "number") return v;
  return undefined;
}

/**
 * Build inclusive date-range predicate for a window key.
 */
function windowPredicate(key: WindowKey, now: Date): (iso: string) => boolean {
  const nowTs = now.getTime();
  switch (key) {
    case "today": {
      const today = toUtcDate(now.toISOString());
      return (iso: string) => toUtcDate(iso) === today;
    }
    case "7d": {
      const cutoff7 = nowTs - 7 * 24 * 60 * 60 * 1000;
      return (iso: string) => new Date(iso).getTime() >= cutoff7;
    }
    case "30d": {
      const cutoff30 = nowTs - 30 * 24 * 60 * 60 * 1000;
      return (iso: string) => new Date(iso).getTime() >= cutoff30;
    }
    case "90d": {
      const cutoff90 = nowTs - 90 * 24 * 60 * 60 * 1000;
      return (iso: string) => new Date(iso).getTime() >= cutoff90;
    }
    case "all_time":
      return () => true;
  }
}

/**
 * Compute rollup aggregates for a single user's usage collection.
 *
 * @param db - Firestore instance.
 * @param uid - Firebase Auth UID.
 * @returns The computed rollup doc for each window key.
 */
export async function computeUserRollups(
  db: Firestore,
  uid: string
): Promise<Record<WindowKey, UsageRollupDoc>> {
  const usageRef = db.collection(`users/${uid}/usage`);
  // Read all usage docs. In production with >10k events this should paginate
  // or use an hourly pre-aggregate; for the MVP we read the whole stream.
  const snapshot = await usageRef.get();
  const events: UsageEventDoc[] = snapshot.docs.map(
    (d) => d.data() as UsageEventDoc
  );

  const now = new Date();
  const results = {} as Record<WindowKey, UsageRollupDoc>;

  for (const key of WINDOW_KEYS) {
    const pred = windowPredicate(key, now);
    const filtered = events.filter((e) => pred(e.timestamp));

    const providerMap = new Map<string, ProviderSummary>();
    const modelMap = new Map<string, ModelSummary>();
    const deviceMap = new Map<string, DeviceSummary>();
    const dailyPoints = new Map<string, number>();
    let totalRequests = 0;
    let totalTokens = 0;
    let totalCost = 0;

    for (const ev of filtered) {
      totalRequests += 1;
      const tokens = (ev.inputTokens ?? 0) + (ev.outputTokens ?? 0);
      totalTokens += tokens;
      const evCost = eventCost(ev);
      if (evCost != null) totalCost += evCost;

      // Provider
      const pKey = ev.provider;
      const pEx = providerMap.get(pKey);
      if (pEx) {
        pEx.totalRequests += 1;
        pEx.totalTokens += tokens;
        if (evCost != null) pEx.totalCost = (pEx.totalCost ?? 0) + evCost;
      } else {
        providerMap.set(pKey, {
          provider: ev.provider,
          totalRequests: 1,
          totalTokens: tokens,
          totalCost: evCost ?? undefined,
        });
      }

      // Model
      if (ev.model) {
        const mKey = `${ev.provider}:${ev.model}`;
        const mEx = modelMap.get(mKey);
        if (mEx) {
          mEx.requests += 1;
          mEx.tokens += tokens;
          if (evCost != null) mEx.cost = (mEx.cost ?? 0) + evCost;
        } else {
          modelMap.set(mKey, {
            model: ev.model,
            provider: ev.provider,
            requests: 1,
            tokens,
            cost: evCost ?? undefined,
          });
        }
      }

      // Device
      if (ev.deviceId) {
        const dEx = deviceMap.get(ev.deviceId);
        if (dEx) {
          dEx.requests += 1;
          dEx.tokens += tokens;
        } else {
          deviceMap.set(ev.deviceId, {
            deviceId: ev.deviceId,
            requests: 1,
            tokens,
          });
        }
      }

      // Daily points
      const day = toUtcDate(ev.timestamp);
      dailyPoints.set(day, (dailyPoints.get(day) ?? 0) + tokens);
    }

    results[key] = {
      today: key === "today" ? totalTokens : 0,
      "7d": key === "7d" ? totalTokens : 0,
      "30d": key === "30d" ? totalTokens : 0,
      "90d": key === "90d" ? totalTokens : 0,
      all_time: key === "all_time" ? totalTokens : 0,
      totals: {
        requests: totalRequests,
        tokens: totalTokens,
        costUsd: Math.round(totalCost * 1e6) / 1e6,
      },
      providerSummaries: Array.from(providerMap.values()),
      modelSummaries: Array.from(modelMap.values()),
      deviceSummaries: Array.from(deviceMap.values()),
      dailyPoints: Object.fromEntries(dailyPoints),
      computedAt: now.toISOString(),
      schemaVersion: ROLLUP_SCHEMA_VERSION,
    };
  }

  return results;
}

/**
 * Write computed rollups to Firestore and clear the dirty marker.
 *
 * @param db - Firestore instance.
 * @param uid - Firebase Auth UID.
 * @param rollups - Computed rollup map from computeUserRollups.
 */
export async function writeUserRollups(
  db: Firestore,
  uid: string,
  rollups: Record<WindowKey, UsageRollupDoc>
): Promise<void> {
  const batch = db.batch();

  for (const key of WINDOW_KEYS) {
    const ref = db.doc(`users/${uid}/usage_rollups/${key}`);
    batch.set(ref, rollups[key], { merge: true });
  }

  const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
  const job: RollupJobDoc = {
    dirty: false,
    lastComputedAt: new Date().toISOString(),
    lastErrorCode: undefined,
  };
  batch.set(jobRef, job, { merge: true });

  await batch.commit();
}
