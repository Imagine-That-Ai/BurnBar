/**
 * @fileoverview Hourly reconciliation of `media_quota_usage` per user.
 *
 * The Mac writes per-session deltas to `users/{uid}/media_quota_usage/{day}`
 * during active sessions in batched updates every 30 s. This worker
 * recomputes the same documents from authoritative
 * `users/{uid}/iroh_audit_events/*` filtered to `streamClass: "media.*"`
 * so client-side drift never becomes a quota dispute. Mirrors the
 * `rollupIrohTransportDaily` shape from `irohMonitoring.ts`.
 *
 * Source of truth contract:
 * - During a session, the Mac is authoritative for live capability gating
 *   (Decision 2 — see `plans/2026-05-15-mercury-media-master-plan.md`).
 * - Hourly, this Function corrects the persisted counter so the next
 *   session starts from a true cumulative number.
 */

import { getFirestore } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import type { Firestore, QueryDocumentSnapshot, Timestamp } from "firebase-admin/firestore";
import type {
  IrohTransportAuditEventDoc,
  MediaFeature,
  MediaQuotaUsageDoc,
} from "./types.js";

const QUOTA_SCHEMA_VERSION = 1;
const QUOTA_COLLECTION = "media_quota_usage";

interface FeatureAccumulator {
  bytesIn: number;
  bytesOut: number;
  secondsUsed: number;
  sessionCount: number;
  failureCount: number;
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

export interface RecomputeOptions {
  uid: string;
  dateUTC: Date;
  firestore?: Firestore;
}

export async function recomputeQuotaUsageForUid(options: RecomputeOptions): Promise<MediaQuotaUsageDoc> {
  const firestore = options.firestore ?? getFirestore();
  const window = utcDayWindow(options.dateUTC);

  const snapshot = await firestore
    .collection(`users/${options.uid}/iroh_audit_events`)
    .where("createdAt", ">=", window.start)
    .where("createdAt", "<", window.end)
    .get();

  const buckets: Record<MediaFeature, FeatureAccumulator> = {
    fileTransfer: newAccumulator(),
    screenShare: newAccumulator(),
    videoCall: newAccumulator(),
  };

  for (const doc of snapshot.docs as QueryDocumentSnapshot[]) {
    const data = doc.data() as Partial<IrohTransportAuditEventDoc> & {
      streamClass?: string;
      bytesInbound?: number;
      bytesOutbound?: number;
      durationMillis?: number;
    };
    const feature = inferFeature(data.streamClass);
    if (!feature) continue;
    const bucket = buckets[feature];
    bucket.bytesIn += data.bytesInbound ?? 0;
    bucket.bytesOut += data.bytesOutbound ?? 0;
    if (data.eventType === "iroh_stream_closed") {
      bucket.sessionCount += 1;
      bucket.secondsUsed += Math.round((data.durationMillis ?? 0) / 1000);
    } else if (data.eventType === "iroh_stream_failed") {
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
  // Late binding so unit tests can swap in a fake admin SDK.
  // Using `getFirestore` to defer initialization.
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const admin = require("firebase-admin/firestore") as typeof import("firebase-admin/firestore");
  return admin.Timestamp.now();
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
    region: "us-central1",
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
        console.error(`recomputeMediaQuotaUsage failed for uid=${uid}`, err);
      }
    }
  }
);
