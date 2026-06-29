/**
 * @fileoverview Hourly reconciliation of `media_quota_usage` per user.
 *
 * This worker writes `users/{uid}/media_quota_usage/{day}` from
 * `users/{uid}/media_session_events/*`, the bounded metadata stream that
 * already carries feature, byte, and duration fields for media sessions.
 * Firestore rules keep that quota document read-only to clients so admission
 * checks never trust owner-writable counters. Mirrors the bounded
 * `mediaMonitoring.ts` rollup query shape.
 *
 * Source of truth contract:
 * - During a session, the Mac is authoritative for live capability gating
 *   (Decision 2 — see `plans/2026-05-15-mercury-media-master-plan.md`).
 * - Hourly, this Function publishes the persisted counter so the next
 *   session starts from a server-reconciled cumulative number.
 */

import { getFirestore, Timestamp } from "firebase-admin/firestore";
import type { SetOptions, WhereFilterOp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { numberField, stringField } from "./guards.js";
import { logError } from "./logging.js";
import type { MediaFeature, MediaQuotaUsageDoc } from "./types.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const QUOTA_SCHEMA_VERSION = 1;
const QUOTA_COLLECTION = "media_quota_usage";

interface FeatureAccumulator {
  bytesIn: number;
  bytesOut: number;
  secondsUsed: number;
  sessionCount: number;
  failureCount: number;
}

type MediaQuotaSourceDoc = {
  data(): Record<string, unknown>;
};

interface MediaQuotaSourceQuery {
  where(field: string, op: WhereFilterOp, value: string): MediaQuotaSourceQuery;
  get(): Promise<{ readonly docs: readonly MediaQuotaSourceDoc[] }>;
}

interface MediaQuotaCollection extends MediaQuotaSourceQuery {
  doc(id: string): {
    set(data: MediaQuotaUsageDoc, options: SetOptions): Promise<unknown>;
  };
}

interface MediaQuotaFirestore {
  collection(path: string): MediaQuotaCollection;
}

function newAccumulator(): FeatureAccumulator {
  return {
    bytesIn: 0,
    bytesOut: 0,
    secondsUsed: 0,
    sessionCount: 0,
    failureCount: 0,
  };
}

function utcDayWindow(date: Date): { date: string; start: Date; end: Date } {
  const dateId = date.toISOString().slice(0, 10);
  const start = new Date(`${dateId}T00:00:00.000Z`);
  const end = new Date(start.getTime() + 24 * 60 * 60 * 1000);
  return { date: dateId, start, end };
}

function inferFeature(streamClass: string | undefined): MediaFeature | undefined {
  if (!streamClass) return undefined;
  if (streamClass.startsWith("media.blob")) return "fileTransfer";
  if (streamClass === "media.screen.video") return "screenShare";
  if (
    streamClass === "media.video.out" ||
    streamClass === "media.video.in" ||
    streamClass === "media.audio.out" ||
    streamClass === "media.audio.in"
  ) {
    return "videoCall";
  }
  return undefined;
}

function isMediaFeature(value: unknown): value is MediaFeature {
  return value === "fileTransfer" || value === "screenShare" || value === "videoCall";
}

function nonNegativeNumber(value: number | undefined): number {
  return value !== undefined && value >= 0 ? value : 0;
}

function durationSeconds(raw: Record<string, unknown>): number {
  const startedAt = stringField(raw, "startedAt");
  const endedAt = stringField(raw, "endedAt");
  if (!startedAt || !endedAt) return 0;
  const startedMs = Date.parse(startedAt);
  const endedMs = Date.parse(endedAt);
  if (!Number.isFinite(startedMs) || !Number.isFinite(endedMs) || endedMs <= startedMs) return 0;
  return Math.round((endedMs - startedMs) / 1000);
}

function isFailureEndReason(value: string | undefined): boolean {
  return Boolean(value && !value.startsWith("completed"));
}

interface RecomputeOptions {
  uid: string;
  dateUTC: Date;
  firestore?: MediaQuotaFirestore;
}

export async function recomputeQuotaUsageForUid(options: RecomputeOptions): Promise<MediaQuotaUsageDoc> {
  const firestore: MediaQuotaFirestore = options.firestore ?? getFirestore();
  const window = utcDayWindow(options.dateUTC);

  const snapshot = await firestore
    .collection(`users/${options.uid}/media_session_events`)
    .where("startedAt", ">=", window.start.toISOString())
    .where("startedAt", "<", window.end.toISOString())
    .get();

  const buckets: Record<MediaFeature, FeatureAccumulator> = {
    fileTransfer: newAccumulator(),
    screenShare: newAccumulator(),
    videoCall: newAccumulator(),
  };

  for (const doc of snapshot.docs) {
    const data = doc.data();
    const featureFromDoc = stringField(data, "feature");
    const feature = isMediaFeature(featureFromDoc) ? featureFromDoc : inferFeature(stringField(data, "streamClass"));
    if (!feature) continue;
    const bucket = buckets[feature];
    bucket.bytesIn += nonNegativeNumber(numberField(data, "byteCountInbound"));
    bucket.bytesOut += nonNegativeNumber(numberField(data, "byteCountOutbound"));
    bucket.sessionCount += 1;
    bucket.secondsUsed += durationSeconds(data);
    if (isFailureEndReason(stringField(data, "endReason"))) {
      bucket.failureCount += 1;
    }
  }

  const recomputed: MediaQuotaUsageDoc = {
    id: window.date,
    bytesUploadedFile: buckets.fileTransfer.bytesOut,
    bytesDownloadedFile: buckets.fileTransfer.bytesIn,
    fileTransfersInitiated: buckets.fileTransfer.sessionCount,
    fileTransfersFailed: buckets.fileTransfer.failureCount,
    screenShareSecondsUsed: buckets.screenShare.secondsUsed,
    screenShareSessions: buckets.screenShare.sessionCount,
    videoCallSecondsUsed: buckets.videoCall.secondsUsed,
    videoCallSessions: buckets.videoCall.sessionCount,
    updatedAt: nowTimestamp(),
    schemaVersion: QUOTA_SCHEMA_VERSION,
  };

  await firestore
    .collection(`users/${options.uid}/${QUOTA_COLLECTION}`)
    .doc(window.date)
    .set(recomputed, { merge: true });

  return recomputed;
}

function nowTimestamp(): Timestamp {
  return Timestamp.now();
}

/**
 * Scheduled hourly. Iterates every user that has any
 * `media_session_events` in the last hour and reconciles their daily
 * usage doc. Bounded fan-out — the cost is per active media user, not
 * per total user.
 */
export const recomputeMediaQuotaUsage = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "UTC",
    region: FUNCTIONS_REGION,
  },
  async () => {
    const firestore = getFirestore();
    const cutoff = new Date(Date.now() - 60 * 60 * 1000);
    const recentSessions = await firestore
      .collectionGroup("media_session_events")
      .where("startedAt", ">=", cutoff.toISOString())
      .select()
      .limit(2_000)
      .get();

    const uniqueUids = new Set<string>();
    for (const doc of recentSessions.docs) {
      const path = doc.ref.path; // users/{uid}/media_session_events/{eventId}
      const segments = path.split("/");
      if (segments[0] === "users" && segments[1]) {
        uniqueUids.add(segments[1]);
      }
    }

    const today = new Date();
    for (const uid of uniqueUids) {
      try {
        await recomputeQuotaUsageForUid({ uid, dateUTC: today, firestore });
      } catch (err) {
        logError({
          event: "media.quota.recompute_failed",
          uid,
          error: String(err),
        });
      }
    }
  },
);
