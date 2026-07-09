/**
 * @fileoverview Server-owned Community share snapshot refresh.
 *
 * The owner-facing `users/{uid}/community/share_snapshot` document is a mirror
 * used by clients and aggregation. Clients provide only consent/profile geo via
 * callables; leaderboard totals are refreshed here from trusted
 * `usage_rollups/*` documents so users cannot self-report inflated rankings.
 */

import { firestoreWithResilience } from "../resilienceHelpers.js";
import { CommunityPaths, COMMUNITY_SCHEMA_VERSION, recheckConsent } from "./consent.js";
import { normalizeGeoKey } from "./geo.js";
import type {
  CommunityShareSnapshotDoc,
  CommunityUsageTotal,
  CommunityWindowTotals,
} from "../types/generated/community.js";
import type { CommunityFirestore } from "./firestoreTypes.js";

const MAX_TOTAL_TOKENS = 50_000_000_000;
const MAX_COST_USD = 1_000_000;
const MAX_SESSION_COUNT = 1_000_000;
const MAX_MIX_KEYS = 128;
const MAX_MIX_KEY_LENGTH = 128;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function finiteNumber(value: unknown, max: number, integer = false): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > max) return 0;
  if (integer && (!Number.isInteger(value) || !Number.isSafeInteger(value))) return 0;
  return value;
}

function readRollupTotal(raw: unknown): CommunityUsageTotal {
  if (!isRecord(raw) || !isRecord(raw.totals)) return { totalTokens: 0, costUSD: 0 };
  const totalTokens = finiteNumber(raw.totals.tokens, MAX_TOTAL_TOKENS, true);
  const costUSD = finiteNumber(raw.totals.costUsd ?? raw.totals.costUSD, MAX_COST_USD);
  return { totalTokens, costUSD };
}

function monotonicWindow(current: CommunityUsageTotal, previous: CommunityUsageTotal): CommunityUsageTotal {
  return {
    totalTokens: Math.max(current.totalTokens, previous.totalTokens),
    costUSD: Math.max(current.costUSD, previous.costUSD),
  };
}

function modelMixFromRollup(raw: unknown): Record<string, number> {
  if (!isRecord(raw) || !Array.isArray(raw.modelSummaries)) return {};
  const out: Record<string, number> = {};
  for (const summary of raw.modelSummaries) {
    if (!isRecord(summary) || typeof summary.model !== "string") continue;
    const key = summary.model.trim();
    if (key.length === 0 || key.length > MAX_MIX_KEY_LENGTH) continue;
    const tokens = finiteNumber(summary.tokens, MAX_TOTAL_TOKENS);
    if (tokens <= 0) continue;
    out[key] = (out[key] ?? 0) + tokens;
    if (Object.keys(out).length >= MAX_MIX_KEYS) break;
  }
  return out;
}

function sessionCountFromRollup(raw: unknown): number | undefined {
  if (!isRecord(raw) || !isRecord(raw.totals)) return undefined;
  const requests = finiteNumber(raw.totals.requests, MAX_SESSION_COUNT, true);
  return requests > 0 ? requests : undefined;
}

async function readRollupData(db: CommunityFirestore, uid: string, window: string): Promise<unknown> {
  const snap = await db.doc(`users/${uid}/usage_rollups/${window}`).get();
  return snap.exists ? snap.data() : undefined;
}

function optionalGeo(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  return normalizeGeoKey(raw) ?? undefined;
}

function snapshotRecord(snapshot: CommunityShareSnapshotDoc): Record<string, unknown> {
  const out: Record<string, unknown> = {
    windows: {
      today: snapshot.windows.today,
      "7d": snapshot.windows["7d"],
      "30d": snapshot.windows["30d"],
      "90d": snapshot.windows["90d"],
      all_time: snapshot.windows.all_time,
    },
    modelMix: snapshot.modelMix,
    purposeMix: snapshot.purposeMix,
    schemaVersion: snapshot.schemaVersion,
    updatedAt: snapshot.updatedAt,
  };
  if (snapshot.sessionCount !== undefined) out.sessionCount = snapshot.sessionCount;
  if (snapshot.countryCode !== undefined) out.countryCode = snapshot.countryCode;
  if (snapshot.regionKey !== undefined) out.regionKey = snapshot.regionKey;
  if (snapshot.cityKey !== undefined) out.cityKey = snapshot.cityKey;
  return out;
}

export async function buildCommunityShareSnapshotFromTrustedRollups(
  db: CommunityFirestore,
  uid: string,
  now: Date = new Date(),
): Promise<CommunityShareSnapshotDoc | null> {
  const consent = await recheckConsent(db, uid);
  if (!consent.l2Rankings) return null;

  const profileSnap = await db.doc(CommunityPaths.profile(uid)).get();
  const profile = profileSnap.data();
  if (!profileSnap.exists || !isRecord(profile) || typeof profile.anonId !== "string") return null;

  const todayRaw = await readRollupData(db, uid, "today");
  const sevenDayRaw = await readRollupData(db, uid, "7d");
  const thirtyDayRaw = await readRollupData(db, uid, "30d");
  const ninetyDayRaw = await readRollupData(db, uid, "90d");
  const allTimeRaw = await readRollupData(db, uid, "all_time");

  const today = readRollupTotal(todayRaw);
  const sevenDay = monotonicWindow(readRollupTotal(sevenDayRaw), today);
  const thirtyDay = monotonicWindow(readRollupTotal(thirtyDayRaw), sevenDay);
  const ninetyDay = monotonicWindow(readRollupTotal(ninetyDayRaw), thirtyDay);
  const allTime = monotonicWindow(readRollupTotal(allTimeRaw), ninetyDay);
  const windows: CommunityWindowTotals = {
    today,
    "7d": sevenDay,
    "30d": thirtyDay,
    "90d": ninetyDay,
    all_time: allTime,
  };

  const snapshot: CommunityShareSnapshotDoc = {
    windows,
    modelMix: modelMixFromRollup(allTimeRaw),
    purposeMix: {},
    schemaVersion: COMMUNITY_SCHEMA_VERSION,
    updatedAt: now.toISOString(),
  };

  const sessionCount = sessionCountFromRollup(allTimeRaw);
  if (sessionCount !== undefined) snapshot.sessionCount = sessionCount;

  const countryCode = consent.l2Country ? optionalGeo(profile.countryCode) : undefined;
  const regionKey = consent.l2Region ? optionalGeo(profile.regionKey) : undefined;
  const consentedCity = consent.l2City ? optionalGeo(profile.cityKey) : undefined;
  if (countryCode !== undefined) snapshot.countryCode = countryCode;
  if (regionKey !== undefined) snapshot.regionKey = regionKey;
  if (consentedCity !== undefined) snapshot.cityKey = consentedCity;

  return snapshot;
}

export async function refreshCommunityShareSnapshotForUser(
  db: CommunityFirestore,
  uid: string,
  now: Date = new Date(),
): Promise<CommunityShareSnapshotDoc | null> {
  const snapshot = await buildCommunityShareSnapshotFromTrustedRollups(db, uid, now);
  const ref = db.doc(CommunityPaths.shareSnapshot(uid));
  if (!snapshot) {
    await firestoreWithResilience("community-share-snapshot-delete", () => ref.delete());
    return null;
  }

  await firestoreWithResilience("community-share-snapshot-write", () => ref.set(snapshotRecord(snapshot)));
  return snapshot;
}

export async function refreshCommunityShareSnapshots(
  db: CommunityFirestore,
  now: Date = new Date(),
): Promise<{ refreshed: number; removed: number }> {
  const snapshot = await db.collectionGroup("community").get();
  let refreshed = 0;
  let removed = 0;

  for (const doc of snapshot.docs) {
    if (doc.id !== "consent") continue;
    const uid = doc.ref.parent?.parent?.id;
    if (!uid) continue;
    const shareSnapshot = await refreshCommunityShareSnapshotForUser(db, uid, now);
    if (shareSnapshot) {
      refreshed++;
    } else {
      removed++;
    }
  }

  return { refreshed, removed };
}
