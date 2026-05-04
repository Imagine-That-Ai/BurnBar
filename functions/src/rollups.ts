/**
 * @fileoverview Usage rollup computation.
 *
 * Reads raw usage events from Firestore, computes per-window aggregates, and
 * writes `usage_rollups/{windowKey}` documents. All computation is idempotent:
 * re-running with the same input produces the same output.
 */

import { type Firestore } from "firebase-admin/firestore";
import type {
  UsageEventDoc,
  UsageRollupDoc,
  ProviderSummary,
  ProviderAccountSummary,
  ModelSummary,
  DeviceSummary,
  RollupJobDoc,
} from "./types.js";

const ROLLUP_SCHEMA_VERSION = 2;

/** Window keys in ascending granularity order. */
const WINDOW_KEYS = ["today", "7d", "30d", "90d", "all_time"] as const;
export type WindowKey = (typeof WINDOW_KEYS)[number];

type TimestampLike = {
  toDate?: () => Date;
  toMillis?: () => number;
  seconds?: number;
  nanoseconds?: number;
  _seconds?: number;
  _nanoseconds?: number;
};

function coerceDate(value: unknown): Date | undefined {
  if (value == null) return undefined;
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? undefined : value;
  }
  if (typeof value === "string" || typeof value === "number") {
    const d = new Date(value);
    return Number.isNaN(d.getTime()) ? undefined : d;
  }

  if (typeof value === "object") {
    const ts = value as TimestampLike;
    if (typeof ts.toDate === "function") {
      const d = ts.toDate();
      return Number.isNaN(d.getTime()) ? undefined : d;
    }
    if (typeof ts.toMillis === "function") {
      const d = new Date(ts.toMillis());
      return Number.isNaN(d.getTime()) ? undefined : d;
    }
    const seconds = ts.seconds ?? ts._seconds;
    const nanos = ts.nanoseconds ?? ts._nanoseconds ?? 0;
    if (typeof seconds === "number") {
      const d = new Date(seconds * 1000 + Math.floor(nanos / 1_000_000));
      return Number.isNaN(d.getTime()) ? undefined : d;
    }
  }

  return undefined;
}

function eventDate(ev: UsageEventDoc): Date | undefined {
  return (
    coerceDate(ev.timestamp) ??
    coerceDate(ev.startTime) ??
    coerceDate(ev.endTime) ??
    coerceDate(ev.createdAt) ??
    coerceDate(ev.updatedAt)
  );
}

function toUtcDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function finiteNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function eventTokens(ev: UsageEventDoc): number {
  if (typeof ev.totalTokens === "number" && Number.isFinite(ev.totalTokens)) {
    return ev.totalTokens;
  }
  return (
    finiteNumber(ev.inputTokens) +
    finiteNumber(ev.outputTokens) +
    finiteNumber(ev.cacheCreationTokens) +
    finiteNumber(ev.cacheReadTokens) +
    finiteNumber(ev.reasoningTokens)
  );
}

function eventCost(ev: UsageEventDoc): number | undefined {
  const v = ev.costUsd ?? ev.cost;
  if (typeof v === "number" && Number.isFinite(v)) return v;
  return undefined;
}

function isLegacyKimiWireEvent(ev: UsageEventDoc): boolean {
  const provider = String(ev.providerID ?? ev.provider ?? "").toLowerCase();
  const model = String(ev.model ?? "");
  return provider === "kimi" && model.startsWith("chatcmpl-");
}

function kimiCost(
  inputTokens: number,
  outputTokens: number,
  cacheCreationTokens: number,
  cacheReadTokens: number
): number {
  return (
    (inputTokens / 1_000_000) * 0.6 +
    (outputTokens / 1_000_000) * 2.5 +
    (cacheCreationTokens / 1_000_000) * 0.6 +
    (cacheReadTokens / 1_000_000) * 0.15
  );
}

function eventModel(ev: UsageEventDoc): string | undefined {
  return isLegacyKimiWireEvent(ev) ? "kimi-for-coding" : ev.model;
}

function eventMetrics(ev: UsageEventDoc): { tokens: number; cost?: number } {
  if (!isLegacyKimiWireEvent(ev)) {
    return { tokens: eventTokens(ev), cost: eventCost(ev) };
  }

  const rawInput = finiteNumber(ev.inputTokens);
  const output = finiteNumber(ev.outputTokens);
  const cacheCreation = finiteNumber(ev.cacheCreationTokens);
  const cacheRead = finiteNumber(ev.cacheReadTokens);
  const input = Math.max(rawInput - cacheCreation - cacheRead, 0);

  return {
    tokens: input + output + cacheCreation + cacheRead,
    cost: kimiCost(input, output, cacheCreation, cacheRead),
  };
}

function stripUndefined<T>(value: T): T {
  if (Array.isArray(value)) {
    return value.map((item) => stripUndefined(item)) as T;
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .filter(([, entryValue]) => entryValue !== undefined)
        .map(([key, entryValue]) => [key, stripUndefined(entryValue)])
    ) as T;
  }
  return value;
}

function eventProviderID(ev: UsageEventDoc): string {
  return ev.providerID ?? ev.provider;
}

function accountSummaryKey(ev: UsageEventDoc): string {
  return ev.providerAccountID ?? `${eventProviderID(ev)}:unattributed`;
}

function windowPredicate(key: WindowKey, now: Date): (date: Date) => boolean {
  const nowTs = now.getTime();
  switch (key) {
    case "today": {
      const today = toUtcDate(now);
      return (date: Date) => toUtcDate(date) === today;
    }
    case "7d": {
      const cutoff7 = nowTs - 7 * 24 * 60 * 60 * 1000;
      return (date: Date) => date.getTime() >= cutoff7;
    }
    case "30d": {
      const cutoff30 = nowTs - 30 * 24 * 60 * 60 * 1000;
      return (date: Date) => date.getTime() >= cutoff30;
    }
    case "90d": {
      const cutoff90 = nowTs - 90 * 24 * 60 * 60 * 1000;
      return (date: Date) => date.getTime() >= cutoff90;
    }
    case "all_time":
      return () => true;
  }
}

export async function computeUserRollups(
  db: Firestore,
  uid: string
): Promise<Record<WindowKey, UsageRollupDoc>> {
  const usageRef = db.collection(`users/${uid}/usage`);
  const snapshot = await usageRef.get();
  const events = snapshot.docs
    .map((d) => d.data() as UsageEventDoc)
    .map((event) => ({ event, date: eventDate(event) }))
    .filter((entry): entry is { event: UsageEventDoc; date: Date } => {
      return entry.date != null;
    });

  const now = new Date();
  const results = {} as Record<WindowKey, UsageRollupDoc>;

  for (const key of WINDOW_KEYS) {
    const pred = windowPredicate(key, now);
    const filtered = events.filter((entry) => pred(entry.date));

    const providerMap = new Map<string, ProviderSummary>();
    const accountMap = new Map<string, ProviderAccountSummary>();
    const modelMap = new Map<string, ModelSummary>();
    const deviceMap = new Map<string, DeviceSummary>();
    const dailyPoints = new Map<string, number>();
    let totalRequests = 0;
    let totalTokens = 0;
    let totalCost = 0;

    for (const { event: ev, date } of filtered) {
      totalRequests += 1;
      const metrics = eventMetrics(ev);
      const tokens = metrics.tokens;
      const evCost = metrics.cost;
      totalTokens += tokens;
      if (evCost != null) totalCost += evCost;

      const pKey = ev.provider;
      const providerID = eventProviderID(ev);
      const pEx = providerMap.get(pKey);
      if (pEx) {
        pEx.totalRequests += 1;
        pEx.totalTokens += tokens;
        if (evCost != null) pEx.totalCost = (pEx.totalCost ?? 0) + evCost;
      } else {
        providerMap.set(pKey, {
          provider: ev.provider,
          providerID,
          totalRequests: 1,
          totalTokens: tokens,
          totalCost: evCost ?? undefined,
        });
      }

      const aKey = accountSummaryKey(ev);
      const aEx = accountMap.get(aKey);
      if (aEx) {
        aEx.totalRequests += 1;
        aEx.totalTokens += tokens;
        if (evCost != null) aEx.totalCost = (aEx.totalCost ?? 0) + evCost;
      } else {
        accountMap.set(aKey, {
          id: aKey,
          providerID,
          accountID: ev.providerAccountID,
          accountLabel:
            ev.providerAccountLabel ?? "Usage not linked to an account yet",
          storageScope: ev.providerAccountSource,
          totalRequests: 1,
          totalTokens: tokens,
          totalCost: evCost ?? undefined,
        });
      }

      const model = eventModel(ev);
      if (model) {
        const mKey = `${ev.provider}:${model}`;
        const mEx = modelMap.get(mKey);
        if (mEx) {
          mEx.requests += 1;
          mEx.tokens += tokens;
          if (evCost != null) mEx.cost = (mEx.cost ?? 0) + evCost;
        } else {
          modelMap.set(mKey, {
            model,
            provider: ev.provider,
            requests: 1,
            tokens,
            cost: evCost ?? undefined,
          });
        }
      }

      const deviceId = ev.deviceId ?? ev.sourceDeviceId;
      if (deviceId) {
        const dEx = deviceMap.get(deviceId);
        if (dEx) {
          dEx.requests += 1;
          dEx.tokens += tokens;
        } else {
          deviceMap.set(deviceId, { deviceId, requests: 1, tokens });
        }
      }

      const day = toUtcDate(date);
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
      accountSummaries: Array.from(accountMap.values()),
      modelSummaries: Array.from(modelMap.values()),
      deviceSummaries: Array.from(deviceMap.values()),
      dailyPoints: Object.fromEntries(dailyPoints),
      computedAt: now.toISOString(),
      schemaVersion: ROLLUP_SCHEMA_VERSION,
    };
  }

  return results;
}

export async function writeUserRollups(
  db: Firestore,
  uid: string,
  rollups: Record<WindowKey, UsageRollupDoc>
): Promise<void> {
  const batch = db.batch();

  for (const key of WINDOW_KEYS) {
    const ref = db.doc(`users/${uid}/usage_rollups/${key}`);
    batch.set(ref, stripUndefined(rollups[key]), { merge: true });
  }

  const jobRef = db.doc(`users/${uid}/rollup_jobs/current`);
  const job: RollupJobDoc = {
    dirty: false,
    lastComputedAt: new Date().toISOString(),
  };
  batch.set(jobRef, job, { merge: true });

  await batch.commit();
}
