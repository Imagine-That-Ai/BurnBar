/**
 * @fileoverview Hourly community leaderboard aggregation.
 *
 * Scheduled function that:
 *   1. collectionGroup over all `share_snapshot` docs.
 *   2. Server-side consent recheck — drops any user whose consent was revoked
 *      or is no longer granted for a given tier.
 *   3. Groups by geography tier (world/country/region/city) × time window
 *      (today/7d/30d/90d/all_time).
 *   4. Applies k-anonymity threshold (k=10): boards with fewer than K members
 *      get `belowThreshold: true` (UI falls back to the next-broader tier).
 *   5. Writes public `community_leaderboards/{window}_{tier}_{geoKey}` docs.
 *   6. Computes percentile bands (p50/p75/p90/p99) and movement arrows.
 *
 * Reuses `firestoreWithResilience` for all Firestore reads/writes and
 * `runScheduledJob` for observability wrapping.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { runScheduledJob } from "../scheduledOps.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { logInfo, logWarn } from "../logging.js";
import { recheckConsent, COMMUNITY_K_THRESHOLD, CommunityPaths } from "./consent.js";
import type { CommunityShareSnapshotDoc } from "./shareTypes.js";
import type {
  LeaderboardEntry,
  CommunityLeaderboardDoc,
  PercentileBands,
  RankMovement,
} from "../types/generated/community.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type WindowKey = "today" | "7d" | "30d" | "90d" | "all_time";
type Tier = "world" | "country" | "region" | "city";

const WINDOWS: readonly WindowKey[] = ["today", "7d", "30d", "90d", "all_time"];
const TIERS: readonly Tier[] = ["world", "country", "region", "city"];

interface Participant {
  uid: string;
  anonId: string;
  handle: string | null;
  totalTokens: number;
  costUSD: number;
  /** Geo keys from the snapshot (only at consented tiers). */
  countryCode: string | null;
  regionKey: string | null;
  cityKey: string | null;
  prevRank: number | null;
}

// ---------------------------------------------------------------------------
// Scheduled export
// ---------------------------------------------------------------------------

/**
 * Hourly aggregation: reads all share snapshots, rechecks consent, computes
 * leaderboards per window × tier, and writes public aggregate docs.
 */
export const aggregateCommunityLeaderboards = onSchedule(
  {
    schedule: "every 60 minutes",
    region: FUNCTIONS_REGION,
    timeoutSeconds: 540,
    memory: "1GiB",
  },
  async () =>
    runScheduledJob("aggregateCommunityLeaderboards", async () => {
      const db = getFirestore();
      await runAggregation(db);
    }),
);

/**
 * Pure aggregation pipeline — exported for test injection. Takes a Firestore
 * instance, reads all snapshots, rechecks consent, computes boards, writes them.
 */
export async function runAggregation(db: Firestore): Promise<void> {
  const participants = await collectValidParticipants(db);
  if (participants.length === 0) {
    logInfo({ event: "community_aggregation_empty", message: "No valid participants" });
    return;
  }

  // Read previous leaderboards for movement computation (rank delta vs. last cycle).
  const prevRankMap = await loadPreviousRanks(db, participants);

  let boardsWritten = 0;
  for (const window of WINDOWS) {
    for (const tier of TIERS) {
      const groups = groupByGeoTier(participants, tier);
      for (const [geoKey, group] of Object.entries(groups)) {
        const board = buildLeaderboard(window, tier, geoKey, group, prevRankMap);
        await writeLeaderboard(db, board);
        boardsWritten++;
      }
    }
  }

  logInfo({
    event: "community_aggregation_complete",
    participants: participants.length,
    boardsWritten,
  });
}

// ---------------------------------------------------------------------------
// Participant collection (consent recheck)
// ---------------------------------------------------------------------------

/**
 * collectionGroup over `share_snapshot`, server-side consent recheck, and
 * tombstone cleanup. Returns only participants whose L2 consent is still
 * granted for at least one tier.
 */
async function collectValidParticipants(db: Firestore): Promise<Participant[]> {
  const snapshot = await db.collectionGroup("share_snapshot").get();
  const participants: Participant[] = [];

  for (const doc of snapshot.docs) {
    const uid = doc.ref.parent.parent?.id;
    if (!uid) continue;

    const data = doc.data() as Partial<CommunityShareSnapshotDoc>;

    // Tombstone sweep: a revoked snapshot means the user opted out since the
    // last sweep. Delete the snapshot doc and skip.
    if (data.revoked === true) {
      await doc.ref.delete();
      continue;
    }

    // Server-side consent recheck — the authoritative gate.
    const consent = await recheckConsent(db, uid);
    if (!consent.l2Rankings) continue;

    // Derive the participant's geo keys based on consented tiers.
    const countryCode = consent.l2Country ? (data.countryCode ?? null) : null;
    const regionKey = consent.l2Region ? (data.regionKey ?? null) : null;
    const cityKey = consent.l2City ? (data.cityKey ?? null) : null;

    // Read profile for anonId + handle.
    const profileDoc = await db.doc(CommunityPaths.profile(uid)).get();
    const profile = profileDoc.data() as { anonId?: string; handle?: string } | undefined;
    const anonId = profile?.anonId ?? uid;

    const windowTotals = data.windows;
    if (!windowTotals) continue;

    participants.push({
      uid,
      anonId,
      handle: profile?.handle ?? null,
      totalTokens: 0, // Set per-window below
      costUSD: 0,
      countryCode,
      regionKey,
      cityKey,
      prevRank: null,
    });

    // Store the last participant index for window-specific totals
    // (we attach per-window totals during grouping).
    const lastIdx = participants.length - 1;
    (participants[lastIdx] as Participant & { windowTotals: typeof windowTotals }).windowTotals =
      windowTotals;
  }

  return participants;
}

// ---------------------------------------------------------------------------
// Grouping + board construction
// ---------------------------------------------------------------------------

/** Resolve the geo key for a participant at a given tier. */
function geoKeyForTier(p: Participant, tier: Tier): string | null {
  switch (tier) {
    case "world":
      return "world";
    case "country":
      return p.countryCode;
    case "region":
      return p.regionKey;
    case "city":
      return p.cityKey;
  }
}

/** Resolve the window total for a participant at a given window. */
function windowTotal(p: Participant & { windowTotals?: CommunityShareSnapshotDoc["windows"] }, window: WindowKey): {
  totalTokens: number;
  costUSD: number;
} {
  const w = p.windowTotals;
  if (!w) return { totalTokens: 0, costUSD: 0 };
  const slot = w[window];
  if (!slot) return { totalTokens: 0, costUSD: 0 };
  return {
    totalTokens: typeof slot.totalTokens === "number" ? slot.totalTokens : 0,
    costUSD: typeof slot.costUSD === "number" ? slot.costUSD : 0,
  };
}

/**
 * Group participants by their geo key at the given tier. Participants whose
 * tier is not consented are excluded (their geo key is null at that tier).
 */
function groupByGeoTier(
  participants: Array<Participant & { windowTotals?: CommunityShareSnapshotDoc["windows"] }>,
  tier: Tier,
): Record<string, Participant[]> {
  const groups: Record<string, Participant[]> = {};
  for (const p of participants) {
    const key = geoKeyForTier(p, tier);
    if (key === null) continue;
    (groups[key] ??= []).push(p);
  }
  return groups;
}

/** Build a leaderboard doc for one window × tier × geoKey cohort. */
function buildLeaderboard(
  window: WindowKey,
  tier: Tier,
  geoKey: string,
  group: Array<Participant & { windowTotals?: CommunityShareSnapshotDoc["windows"] }>,
  prevRankMap: Map<string, number>,
): CommunityLeaderboardDoc {
  const scored = group.map((p) => {
    const totals = windowTotal(p, window);
    return { ...p, ...totals };
  });

  // Sort by totalTokens descending (costUSD as tiebreaker).
  scored.sort((a, b) => b.totalTokens - a.totalTokens || b.costUSD - a.costUSD);

  const cohortSize = scored.length;
  const belowThreshold = cohortSize < COMMUNITY_K_THRESHOLD;

  // k-anonymity gate: when the cohort is below the threshold, NO individual
  // data may be published — not entries, not percentiles, not the exact
  // cohort size. The public doc carries only enough metadata for the UI to
  // fall back to the next-broader tier and show "needs N more burners".
  // (cohortSize is omitted — the UI shows the fixed kThreshold, not how close
  //  the tiny cohort is, to avoid revealing "only 3 people in this city".)
  if (belowThreshold) {
    return {
      window,
      tier,
      geoKey,
      entries: [],
      percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 },
      cohortSize: 0,
      belowThreshold: true,
      kThreshold: COMMUNITY_K_THRESHOLD,
      updatedAt: new Date().toISOString(),
    };
  }

  // Top 100 entries.
  const entries: LeaderboardEntry[] = scored.slice(0, 100).map((p, idx) => {
    const rank = idx + 1;
    const prevRank = prevRankMap.get(p.anonId) ?? null;
    const movement: RankMovement = computeMovement(rank, prevRank);
    return {
      rank,
      handle: p.handle ?? undefined,
      anonId: p.anonId,
      totalTokens: p.totalTokens,
      costUSD: p.costUSD,
      movement,
    };
  });

  const allTokens = scored.map((p) => p.totalTokens);
  const percentiles = computePercentiles(allTokens);

  return {
    window,
    tier,
    geoKey,
    entries,
    percentiles,
    cohortSize,
    belowThreshold: false,
    kThreshold: COMMUNITY_K_THRESHOLD,
    updatedAt: new Date().toISOString(),
  };
}

function computeMovement(currentRank: number, prevRank: number | null): RankMovement {
  if (prevRank === null) return "new";
  if (currentRank < prevRank) return "up";
  if (currentRank > prevRank) return "down";
  return "same";
}

// ---------------------------------------------------------------------------
// Percentile computation
// ---------------------------------------------------------------------------

/** Compute p50/p75/p90/p99 using nearest-rank interpolation on a sorted array. */
function computePercentiles(sortedAsc: number[]): PercentileBands {
  if (sortedAsc.length === 0) {
    return { p50: 0, p75: 0, p90: 0, p99: 0 };
  }
  const sorted = [...sortedAsc].sort((a, b) => a - b);
  return {
    p50: percentile(sorted, 0.5),
    p75: percentile(sorted, 0.75),
    p90: percentile(sorted, 0.9),
    p99: percentile(sorted, 0.99),
  };
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  if (sorted.length === 1) return sorted[0];
  const idx = (sorted.length - 1) * p;
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
}

// ---------------------------------------------------------------------------
// Previous rank loading (for movement arrows)
// ---------------------------------------------------------------------------

async function loadPreviousRanks(
  db: Firestore,
  participants: Participant[],
): Promise<Map<string, number>> {
  const rankMap = new Map<string, number>();
  // Only need to check world boards for movement (all participants share world).
  // For efficiency, we read a few key boards. In practice, we read the all_time
  // world board and extract rank mapping. This is O(1) reads.
  try {
    const prevDoc = await db.doc(CommunityPaths.leaderboard("all_time", "world", "world")).get();
    if (prevDoc.exists) {
      const data = prevDoc.data() as CommunityLeaderboardDoc;
      for (const entry of data.entries) {
        rankMap.set(entry.anonId, entry.rank);
      }
    }
  } catch {
    logWarn({ event: "community_prev_rank_load_failed" });
  }
  return rankMap;
}

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

async function writeLeaderboard(db: Firestore, board: CommunityLeaderboardDoc): Promise<void> {
  const docPath = CommunityPaths.leaderboard(board.window, board.tier, board.geoKey);
  await db.doc(docPath).set(board);
}

// ---------------------------------------------------------------------------
// Test exports (pure functions for unit testing)
// ---------------------------------------------------------------------------

export { computePercentiles, groupByGeoTier, buildLeaderboard };
export type { Participant, WindowKey, Tier };
