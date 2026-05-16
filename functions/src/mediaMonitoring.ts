/**
 * @fileoverview Daily rollups of Mercury media session events for the
 * operator dashboard. Mirrors `rollupIrohTransportDaily` but ranges over
 * `users/{uid}/media_session_events/*`.
 */

import { getFirestore } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import type { Firestore, QueryDocumentSnapshot, Timestamp } from "firebase-admin/firestore";
import type {
  MediaFeature,
  MediaSessionDailyRollupDoc,
  MediaSessionEventDoc,
} from "./types.js";

const ROLLUP_SCHEMA_VERSION = 1;
const ROLLUP_COLLECTION = "ops/media_session_daily_rollups/days";
const FEATURES: MediaFeature[] = ["fileTransfer", "screenShare", "videoCall"];

function utcDayWindow(date: Date) {
  const dateId = date.toISOString().slice(0, 10);
  const start = new Date(`${dateId}T00:00:00.000Z`);
  const end = new Date(start.getTime() + 24 * 60 * 60 * 1000);
  return { date: dateId, start, end };
}

function previousUtcDay(now: Date): Date {
  const today = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  return new Date(today.getTime() - 24 * 60 * 60 * 1000);
}

function emptyFeatureBucket(): MediaSessionDailyRollupDoc["perFeature"][MediaFeature] {
  return {
    sessionCount: 0,
    successRate: 0,
    fallbackRate: 0,
    totalSeconds: 0,
    totalBytes: 0,
    rttMillis: { count: 0 },
    bitsPerSecond: { count: 0 },
    freezeCount: { count: 0 },
  };
}

function percentile(sorted: number[], pct: number): number | undefined {
  if (sorted.length === 0) return undefined;
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((pct / 100) * sorted.length) - 1));
  return sorted[index];
}

function bucketRtt(b: string | undefined): number | undefined {
  switch (b) {
    case "lt_50ms": return 25;
    case "50_150ms": return 100;
    case "150_400ms": return 275;
    case "gte_400ms": return 600;
    default: return undefined;
  }
}

function bucketBitsPerSecond(b: string | undefined): number | undefined {
  switch (b) {
    case "lt_300kbps": return 200_000;
    case "300_600kbps": return 450_000;
    case "600kbps_1mbps": return 800_000;
    case "1_2mbps": return 1_500_000;
    case "2_4mbps": return 3_000_000;
    case "4_8mbps": return 6_000_000;
    case "gte_8mbps": return 12_000_000;
    default: return undefined;
  }
}

export interface RollupOptions {
  dateUTC: Date;
  firestore?: Firestore;
}

export async function rollupMediaSessionsForDay(options: RollupOptions): Promise<MediaSessionDailyRollupDoc> {
  const firestore = options.firestore ?? getFirestore();
  const window = utcDayWindow(options.dateUTC);

  const snapshot = await firestore
    .collectionGroup("media_session_events")
    .where("startedAt", ">=", window.start.toISOString())
    .where("startedAt", "<", window.end.toISOString())
    .get();

  const perFeature: MediaSessionDailyRollupDoc["perFeature"] = Object.fromEntries(
    FEATURES.map((feature) => [feature, emptyFeatureBucket()])
  ) as MediaSessionDailyRollupDoc["perFeature"];

  const rttSamples: Record<MediaFeature, number[]> = { fileTransfer: [], screenShare: [], videoCall: [] };
  const bpsSamples: Record<MediaFeature, number[]> = { fileTransfer: [], screenShare: [], videoCall: [] };
  const freezeSamples: Record<MediaFeature, number[]> = { fileTransfer: [], screenShare: [], videoCall: [] };
  const successesByFeature: Record<MediaFeature, { ok: number; total: number }> = {
    fileTransfer: { ok: 0, total: 0 },
    screenShare: { ok: 0, total: 0 },
    videoCall: { ok: 0, total: 0 },
  };

  const uniqueUids = new Set<string>();

  for (const doc of snapshot.docs as QueryDocumentSnapshot[]) {
    const data = doc.data() as MediaSessionEventDoc;
    const segments = doc.ref.path.split("/");
    if (segments.length === 4 && segments[0] === "users" && segments[1]) {
      uniqueUids.add(segments[1]);
    }
    const feature = data.feature;
    if (!perFeature[feature]) continue;

    const bucket = perFeature[feature];
    bucket.sessionCount += 1;
    bucket.totalBytes += (data.byteCountInbound ?? 0) + (data.byteCountOutbound ?? 0);

    successesByFeature[feature].total += 1;
    if (data.endReason === "completedSuccess") {
      successesByFeature[feature].ok += 1;
    }

    const rtt = bucketRtt(data.p95RoundTripMillisBucket);
    if (rtt !== undefined) rttSamples[feature].push(rtt);
    const bps = bucketBitsPerSecond(data.p95BitsPerSecondBucket);
    if (bps !== undefined) bpsSamples[feature].push(bps);
    if (typeof data.freezeCount === "number") freezeSamples[feature].push(data.freezeCount);

    if (data.startedAt && data.endedAt) {
      const startedMs = Date.parse(data.startedAt);
      const endedMs = Date.parse(data.endedAt);
      if (Number.isFinite(startedMs) && Number.isFinite(endedMs) && endedMs > startedMs) {
        bucket.totalSeconds += Math.round((endedMs - startedMs) / 1000);
      }
    }
  }

  for (const feature of FEATURES) {
    const bucket = perFeature[feature];
    const tally = successesByFeature[feature];
    bucket.successRate = tally.total > 0 ? tally.ok / tally.total : 0;

    const rttSorted = [...rttSamples[feature]].sort((a, b) => a - b);
    const bpsSorted = [...bpsSamples[feature]].sort((a, b) => a - b);
    const freezeSorted = [...freezeSamples[feature]].sort((a, b) => a - b);

    bucket.rttMillis = {
      count: rttSorted.length,
      p50: percentile(rttSorted, 50),
      p95: percentile(rttSorted, 95),
      p99: percentile(rttSorted, 99),
    };
    bucket.bitsPerSecond = {
      count: bpsSorted.length,
      p50: percentile(bpsSorted, 50),
      p95: percentile(bpsSorted, 95),
      p99: percentile(bpsSorted, 99),
    };
    bucket.freezeCount = {
      count: freezeSorted.length,
      p50: percentile(freezeSorted, 50),
      p95: percentile(freezeSorted, 95),
      p99: percentile(freezeSorted, 99),
    };
  }

  const rollup: MediaSessionDailyRollupDoc = {
    id: window.date,
    date: window.date,
    windowStart: window.start.toISOString(),
    windowEnd: window.end.toISOString(),
    generatedAt: new Date().toISOString(),
    totalEvents: snapshot.size,
    uniqueUsers: uniqueUids.size,
    perFeature,
    schemaVersion: ROLLUP_SCHEMA_VERSION,
  };

  await firestore.doc(`${ROLLUP_COLLECTION}/${window.date}`).set(rollup, { merge: true });
  return rollup;
}

export const rollupMediaSessionDaily = onSchedule(
  {
    schedule: "every 24 hours",
    timeZone: "UTC",
    region: "us-central1",
  },
  async () => {
    const target = previousUtcDay(new Date());
    await rollupMediaSessionsForDay({ dateUTC: target });
  }
);
