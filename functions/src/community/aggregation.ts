/**
 * @fileoverview Hourly community leaderboard aggregation.
 *
 * Scheduled function that:
 *   1. Publishes the Community runtime status used by Firestore rules.
 *   2. collectionGroup over all `share_snapshot` docs.
 *   3. Server-side consent recheck — drops any user whose consent was revoked
 *      or is no longer granted for a given tier.
 *   4. Validates share snapshots against poisoning, freshness, and shape limits.
 *   5. Groups by geography tier (world/country/region/city) × time window
 *      (today/7d/30d/90d/all_time).
 *   6. Applies k-anonymity threshold (k=10): boards with fewer than K members
 *      get `belowThreshold: true` (UI falls back to the next-broader tier).
 *   7. Writes public `community_leaderboards/{window}_{tier}_{geoKey}` docs.
 *   8. Computes percentile bands (p50/p75/p90/p99) and movement arrows.
 *   9. Removes stale public boards not produced by the current generation.
 *
 * Reuses `firestoreWithResilience` for all Firestore reads/writes and
 * `runScheduledJob` for observability wrapping.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore } from "firebase-admin/firestore";
import { runScheduledJob } from "../scheduledOps.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { logInfo, logWarn } from "../logging.js";
import { recheckConsent, COMMUNITY_K_THRESHOLD, COMMUNITY_SCHEMA_VERSION, CommunityPaths } from "./consent.js";
import { normalizeGeoKey } from "./geo.js";
import { publishCommunityRuntimeStatus } from "./rollout.js";
import { refreshCommunityShareSnapshots } from "./snapshot.js";
import type { CommunityDocumentReference, CommunityDocumentSnapshot, CommunityFirestore } from "./firestoreTypes.js";
import type {
  LeaderboardEntry,
  CommunityLeaderboardDoc,
  PercentileBands,
  RankMovement,
  CommunityShareSnapshotDoc,
  CommunityUsageTotal,
  CommunityWindowTotals,
} from "../types/generated/community.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type WindowKey = "today" | "7d" | "30d" | "90d" | "all_time";
type Tier = "world" | "country" | "region" | "city";

const WINDOWS: readonly WindowKey[] = ["today", "7d", "30d", "90d", "all_time"];
const TIERS: readonly Tier[] = ["world", "country", "region", "city"];

const MAX_SHARE_SNAPSHOT_AGE_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_SHARE_SNAPSHOT_FUTURE_SKEW_MS = 10 * 60 * 1000;
const MAX_TOTAL_TOKENS = 50_000_000_000;
const MAX_COST_USD = 1_000_000;
const MAX_SESSION_COUNT = 1_000_000;
const MAX_MIX_KEYS = 128;
const MAX_MIX_KEY_LENGTH = 128;
const MAX_BATCH_GET_DOCS = 300;
const MAX_CLEANUP_BATCH_WRITES = 400;
const PERCENTILE_MOVEMENT_DEADBAND = 1;
const MIX_KEY_PATTERN = /^[\p{L}\p{N}._:@/+ -]+$/u;
const GEO_KEY_PATTERN = /^[A-Za-z0-9_-]+$/u;

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
  windowTotals?: CommunityWindowTotals;
}

interface BoardWorkItem {
  window: WindowKey;
  tier: Tier;
  geoKey: string;
  group: Participant[];
}
interface PreviousPosition {
  rank: number;
  percentile: number | null;
}

interface PreviousBoardHistory {
  hasUsableHistory: boolean;
  positions: Map<string, PreviousPosition>;
}

const EMPTY_PREVIOUS_BOARD_HISTORY: PreviousBoardHistory = {
  hasUsableHistory: false,
  positions: new Map(),
};

interface StableMovementPercentiles {
  currentPercentile: number;
  previousPercentile: number;
}


// ---------------------------------------------------------------------------
// Scheduled exports
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
 * Daily public-board cleanup safety net. `runAggregation` already sweeps stale
 * boards after each successful generation; this scheduled job clears old docs if
 * aggregation was disabled, interrupted, or no valid participants remained.
 */
export const cleanupStaleCommunityLeaderboards = onSchedule(
  {
    schedule: "every 24 hours",
    region: FUNCTIONS_REGION,
    timeoutSeconds: 300,
    memory: "512MiB",
  },
  async () =>
    runScheduledJob("cleanupStaleCommunityLeaderboards", async () => {
      const db = getFirestore();
      const status = await publishCommunityRuntimeStatus(db);
      if (!status.enabled) {
        const deleted = await cleanupStaleLeaderboards(db, new Set(), new Date());
        logInfo({ event: "community_leaderboard_cleanup_kill_switch", deleted });
        return;
      }
      const deleted = await cleanupStaleLeaderboards(db, new Set(), new Date(Date.now() - MAX_SHARE_SNAPSHOT_AGE_MS));
      logInfo({ event: "community_leaderboard_cleanup_complete", deleted });
    }),
);

/**
 * Pure aggregation pipeline — exported for test injection. Takes a Firestore
 * instance, reads all snapshots, rechecks consent, computes boards, writes them.
 */
async function runAggregation(db: CommunityFirestore): Promise<void> {
  const runStartedAt = new Date();
  const status = await publishCommunityRuntimeStatus(db);
  if (!status.enabled) {
    logInfo({ event: "community_aggregation_disabled", reason: status.reason });
    return;
  }

  const snapshotRefresh = await refreshCommunityShareSnapshots(db, runStartedAt);
  const participants = await collectValidParticipants(db);
  if (participants.length === 0) {
    const staleDeleted = await cleanupStaleLeaderboards(db, new Set(), runStartedAt);
    logInfo({
      event: "community_aggregation_empty",
      message: "No valid participants",
      staleDeleted,
      shareSnapshotsRefreshed: snapshotRefresh.refreshed,
      shareSnapshotsRemoved: snapshotRefresh.removed,
    });
    return;
  }

  const workItems: BoardWorkItem[] = [];
  for (const window of WINDOWS) {
    for (const tier of TIERS) {
      const groups = groupByGeoTier(participants, tier);
      for (const [geoKey, group] of Object.entries(groups)) {
        workItems.push({ window, tier, geoKey, group });
      }
    }
  }

  const previousBoards = await loadPreviousBoardHistoriesForBoards(db, workItems);
  const activeDocPaths = new Set<string>();
  let boardsWritten = 0;

  for (const item of workItems) {
    const board = buildLeaderboard(
      item.window,
      item.tier,
      item.geoKey,
      item.group,
      previousBoards.get(previousRankKey(item.window, item.tier, item.geoKey)) ?? EMPTY_PREVIOUS_BOARD_HISTORY,
    );
    await writeLeaderboard(db, board);
    activeDocPaths.add(CommunityPaths.leaderboard(board.window, board.tier, board.geoKey));
    boardsWritten++;
  }

  const staleDeleted = await cleanupStaleLeaderboards(db, activeDocPaths, runStartedAt);

  logInfo({
    event: "community_aggregation_complete",
    participants: participants.length,
    boardsWritten,
    staleDeleted,
    shareSnapshotsRefreshed: snapshotRefresh.refreshed,
    shareSnapshotsRemoved: snapshotRefresh.removed,
  });
}

// ---------------------------------------------------------------------------
// Participant collection (consent recheck + share snapshot validation)
// ---------------------------------------------------------------------------

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function finiteNumber(value: unknown, max: number, integer = false): number | null {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > max) return null;
  if (integer && (!Number.isInteger(value) || !Number.isSafeInteger(value))) return null;
  return value;
}

function parseUsageTotal(value: unknown): CommunityUsageTotal | null {
  if (!isRecord(value)) return null;
  const totalTokens = finiteNumber(value.totalTokens, MAX_TOTAL_TOKENS, true);
  const costUSD = finiteNumber(value.costUSD, MAX_COST_USD);
  if (totalTokens === null || costUSD === null) return null;
  return { totalTokens, costUSD };
}

function parseWindowTotals(value: unknown): CommunityWindowTotals | null {
  if (!isRecord(value)) return null;
  const today = parseUsageTotal(value.today);
  const sevenDay = parseUsageTotal(value["7d"]);
  const thirtyDay = parseUsageTotal(value["30d"]);
  const ninetyDay = parseUsageTotal(value["90d"]);
  const allTime = parseUsageTotal(value.all_time);
  if (!today || !sevenDay || !thirtyDay || !ninetyDay || !allTime) return null;

  const ordered = [today, sevenDay, thirtyDay, ninetyDay, allTime];
  for (let i = 1; i < ordered.length; i++) {
    const previous = ordered[i - 1];
    const current = ordered[i];
    if (current.totalTokens < previous.totalTokens || current.costUSD < previous.costUSD) return null;
  }

  return { today, "7d": sevenDay, "30d": thirtyDay, "90d": ninetyDay, all_time: allTime };
}

function parseMix(value: unknown): Record<string, number> | null {
  if (!isRecord(value)) return null;
  const entries = Object.entries(value);
  if (entries.length > MAX_MIX_KEYS) return null;
  const out: Record<string, number> = {};
  for (const [key, raw] of entries) {
    if (key.length === 0 || key.length > MAX_MIX_KEY_LENGTH || !MIX_KEY_PATTERN.test(key)) return null;
    const parsed = finiteNumber(raw, MAX_TOTAL_TOKENS);
    if (parsed === null) return null;
    out[key] = parsed;
  }
  return out;
}

function parseOptionalGeoKey(value: unknown): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string" || value.length > 160 || value.includes("/") || value.includes("\\")) return undefined;
  const normalized = normalizeGeoKey(value);
  if (!normalized || !GEO_KEY_PATTERN.test(normalized)) return undefined;
  return normalized;
}

function freshUpdatedAt(value: unknown, nowMs: number): string | null {
  if (typeof value !== "string" || value.length > 80) return null;
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) return null;
  if (parsed > nowMs + MAX_SHARE_SNAPSHOT_FUTURE_SKEW_MS) return null;
  if (parsed < nowMs - MAX_SHARE_SNAPSHOT_AGE_MS) return null;
  return new Date(parsed).toISOString();
}

function parseCommunityShareSnapshotDoc(raw: unknown, nowMs: number = Date.now()): CommunityShareSnapshotDoc | null {
  if (!isRecord(raw)) return null;
  if (raw.schemaVersion !== COMMUNITY_SCHEMA_VERSION) return null;

  const windows = parseWindowTotals(raw.windows);
  if (!windows) return null;

  const modelMix = parseMix(raw.modelMix);
  const purposeMix = parseMix(raw.purposeMix);
  if (!modelMix || !purposeMix) return null;

  const updatedAt = freshUpdatedAt(raw.updatedAt, nowMs);
  if (!updatedAt) return null;

  const out: CommunityShareSnapshotDoc = {
    windows,
    modelMix,
    purposeMix,
    schemaVersion: COMMUNITY_SCHEMA_VERSION,
    updatedAt,
  };

  const sessionCount = finiteNumber(raw.sessionCount, MAX_SESSION_COUNT, true);
  if (raw.sessionCount !== undefined) {
    if (sessionCount === null) return null;
    out.sessionCount = sessionCount;
  }

  const countryCode = parseOptionalGeoKey(raw.countryCode);
  const regionKey = parseOptionalGeoKey(raw.regionKey);
  const cityKey = parseOptionalGeoKey(raw.cityKey);
  if (raw.countryCode !== undefined && countryCode === undefined) return null;
  if (raw.regionKey !== undefined && regionKey === undefined) return null;
  if (raw.cityKey !== undefined && cityKey === undefined) return null;
  if (countryCode) out.countryCode = countryCode;
  if (regionKey) out.regionKey = regionKey;
  if (cityKey) out.cityKey = cityKey;
  if (raw.revoked === true) out.revoked = true;

  return out;
}

/**
 * collectionGroup over `share_snapshot`, server-side consent recheck, and
 * tombstone cleanup. Returns only participants whose L2 consent is still
 * granted for at least one tier and whose share snapshot is publishable.
 */
async function collectValidParticipants(db: CommunityFirestore): Promise<Participant[]> {
  const snapshot = await db.collectionGroup("community").get();
  const participants: Participant[] = [];
  const nowMs = Date.now();

  for (const doc of snapshot.docs) {
    if (doc.id !== "share_snapshot") continue;
    const uid = doc.ref.parent?.parent?.id;
    if (!uid) continue;

    const raw = doc.data();

    // Tombstone sweep: a revoked snapshot means the user opted out since the
    // last sweep. Delete the snapshot doc and skip before applying shape checks.
    if (isRecord(raw) && raw.revoked === true) {
      await doc.ref.delete();
      continue;
    }

    const data = parseCommunityShareSnapshotDoc(raw, nowMs);
    if (!data) {
      logWarn({ event: "community_share_snapshot_invalid", uid_prefix: uid.slice(0, 8) });
      continue;
    }

    // Server-side consent recheck — the authoritative gate.
    const consent = await recheckConsent(db, uid);
    if (!consent.l2Rankings) continue;

    // Read profile for anonId, handle, and consent-normalized geo keys. A
    // missing anonId means the user has no publishable pseudonym yet; never
    // fall back to the Firebase Auth uid on a public leaderboard row.
    const profileDoc = await db.doc(CommunityPaths.profile(uid)).get();
    const profile = profileDoc.data();
    if (!isRecord(profile) || typeof profile.anonId !== "string") continue;

    const countryCode = consent.l2Country ? (parseOptionalGeoKey(profile.countryCode) ?? null) : null;
    const regionKey = consent.l2Region ? (parseOptionalGeoKey(profile.regionKey) ?? null) : null;
    const cityGeo = consent.l2City ? (parseOptionalGeoKey(profile.cityKey) ?? null) : null;

    participants.push({
      uid,
      anonId: profile.anonId,
      handle: typeof profile.handle === "string" ? profile.handle : null,
      totalTokens: 0,
      costUSD: 0,
      countryCode,
      regionKey,
      cityKey: cityGeo,
      prevRank: null,
      windowTotals: data.windows,
    });
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
function windowTotal(
  p: Participant,
  window: WindowKey,
): {
  totalTokens: number;
  costUSD: number;
} {
  const slot = p.windowTotals?.[window];
  return slot ?? { totalTokens: 0, costUSD: 0 };
}

/**
 * Group participants by their geo key at the given tier. Participants whose
 * tier is not consented are excluded (their geo key is null at that tier).
 */
function groupByGeoTier(participants: Participant[], tier: Tier): Record<string, Participant[]> {
  const groups: Record<string, Participant[]> = {};
  for (const p of participants) {
    const key = geoKeyForTier(p, tier);
    const safeKey = key === null ? null : normalizeGeoKey(key);
    if (!safeKey) continue;
    (groups[safeKey] ??= []).push(p);
  }
  return groups;
}

/** Build a leaderboard doc for one window × tier × geoKey cohort. */
function buildLeaderboard(
  window: WindowKey,
  tier: Tier,
  geoKey: string,
  group: Participant[],
  previousHistory: Map<string, number> | PreviousBoardHistory,
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
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
    };
  }

  const previous = normalizePreviousHistory(previousHistory);
  const stableMovement = computeStableMovementPercentiles(scored, previous);
  const entries: LeaderboardEntry[] = scored.slice(0, 100).map((p, idx) => {
    const rank = idx + 1;
    const percentile = percentileForIndex(idx, cohortSize);
    const previousPosition = previous.positions.get(p.anonId) ?? null;
    const movement = computeMovement(rank, percentile, previous, previousPosition, stableMovement.get(p.anonId));
    return {
      rank,
      percentile,
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
    schemaVersion: COMMUNITY_SCHEMA_VERSION,
  };
}

function normalizePreviousHistory(previous: Map<string, number> | PreviousBoardHistory): PreviousBoardHistory {
  if (previous instanceof Map) {
    return {
      hasUsableHistory: true,
      positions: new Map([...previous.entries()].map(([anonId, rank]) => [anonId, { rank, percentile: null }])),
    };
  }
  return previous;
}

function percentileForIndex(index: number, size: number): number {
  if (size <= 0) return 0;
  return Math.round(((size - index) / size) * 10_000) / 100;
}

function computeStableMovementPercentiles(
  currentSorted: Array<Participant & { totalTokens: number; costUSD: number }>,
  history: PreviousBoardHistory,
): Map<string, StableMovementPercentiles> {
  const result = new Map<string, StableMovementPercentiles>();
  if (!history.hasUsableHistory) return result;

  const stableCurrent = currentSorted.filter((p) => history.positions.has(p.anonId));
  if (stableCurrent.length < 2) return result;

  const stablePrevious = [...stableCurrent].sort((a, b) => {
    const aPrevious = history.positions.get(a.anonId)?.rank ?? Number.MAX_SAFE_INTEGER;
    const bPrevious = history.positions.get(b.anonId)?.rank ?? Number.MAX_SAFE_INTEGER;
    return aPrevious - bPrevious;
  });
  const previousPercentiles = new Map<string, number>();
  stablePrevious.forEach((p, index) => {
    previousPercentiles.set(p.anonId, percentileForIndex(index, stablePrevious.length));
  });

  stableCurrent.forEach((p, index) => {
    const previousPercentile = previousPercentiles.get(p.anonId);
    if (previousPercentile === undefined) return;
    result.set(p.anonId, {
      currentPercentile: percentileForIndex(index, stableCurrent.length),
      previousPercentile,
    });
  });
  return result;
}

function computeMovement(
  currentRank: number,
  currentPercentile: number,
  history: PreviousBoardHistory,
  previous: PreviousPosition | null,
  stablePercentiles?: StableMovementPercentiles,
): RankMovement {
  if (!history.hasUsableHistory) return "same";
  if (previous === null) return "new";
  if (stablePercentiles) {
    const delta = stablePercentiles.currentPercentile - stablePercentiles.previousPercentile;
    if (delta >= PERCENTILE_MOVEMENT_DEADBAND) return "up";
    if (delta <= -PERCENTILE_MOVEMENT_DEADBAND) return "down";
    return "same";
  }
  if (previous.percentile !== null) {
    const delta = currentPercentile - previous.percentile;
    if (delta >= PERCENTILE_MOVEMENT_DEADBAND) return "up";
    if (delta <= -PERCENTILE_MOVEMENT_DEADBAND) return "down";
    return "same";
  }
  if (currentRank < previous.rank) return "up";
  if (currentRank > previous.rank) return "down";
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

function previousRankKey(window: WindowKey, tier: Tier, geoKey: string): string {
  return `${window}|${tier}|${normalizeGeoKey(geoKey) ?? "unknown"}`;
}

function previousHistoryFromSnapshot(snapshot: CommunityDocumentSnapshot): PreviousBoardHistory {
  if (!snapshot.exists) return EMPTY_PREVIOUS_BOARD_HISTORY;
  const data = snapshot.data();
  if (!isRecord(data) || data.belowThreshold === true || !Array.isArray(data.entries) || data.entries.length === 0) {
    return EMPTY_PREVIOUS_BOARD_HISTORY;
  }
  const positions = new Map<string, PreviousPosition>();
  for (const entry of data.entries) {
    if (!isRecord(entry) || typeof entry.anonId !== "string" || typeof entry.rank !== "number") continue;
    const percentile = typeof entry.percentile === "number" && Number.isFinite(entry.percentile) ? entry.percentile : null;
    positions.set(entry.anonId, { rank: entry.rank, percentile });
  }
  return {
    hasUsableHistory: positions.size > 0,
    positions,
  };
}

function rankMapFromHistory(history: PreviousBoardHistory): Map<string, number> {
  return new Map([...history.positions.entries()].map(([anonId, position]) => [anonId, position.rank]));
}


interface CommunityFirestoreWithGetAll extends CommunityFirestore {
  getAll(...refsToRead: CommunityDocumentReference[]): Promise<CommunityDocumentSnapshot[]>;
}

function hasGetAll(db: CommunityFirestore): db is CommunityFirestoreWithGetAll {
  if (!("getAll" in db)) return false;
  return typeof db.getAll === "function";
}

async function getAllDocuments(
  db: CommunityFirestore,
  refs: CommunityDocumentReference[],
): Promise<CommunityDocumentSnapshot[]> {
  if (hasGetAll(db)) {
    const docs: CommunityDocumentSnapshot[] = [];
    for (let i = 0; i < refs.length; i += MAX_BATCH_GET_DOCS) {
      docs.push(...(await db.getAll(...refs.slice(i, i + MAX_BATCH_GET_DOCS))));
    }
    return docs;
  }
  return Promise.all(refs.map((ref) => ref.get()));
}

async function loadPreviousBoardHistoriesForBoards(
  db: CommunityFirestore,
  boards: Array<Pick<BoardWorkItem, "window" | "tier" | "geoKey">>,
): Promise<Map<string, PreviousBoardHistory>> {
  const result = new Map<string, PreviousBoardHistory>();
  if (boards.length === 0) return result;

  const unique = new Map<string, { window: WindowKey; tier: Tier; geoKey: string; path: string }>();
  for (const board of boards) {
    const safeGeoKey = normalizeGeoKey(board.geoKey) ?? "unknown";
    const key = previousRankKey(board.window, board.tier, safeGeoKey);
    unique.set(key, {
      window: board.window,
      tier: board.tier,
      geoKey: safeGeoKey,
      path: CommunityPaths.leaderboard(board.window, board.tier, safeGeoKey),
    });
  }

  const descriptors = [...unique.entries()];
  const refs = descriptors.map(([, descriptor]) => db.doc(descriptor.path));
  try {
    const snapshots = await getAllDocuments(db, refs);
    snapshots.forEach((snapshot, index) => {
      const [key] = descriptors[index];
      result.set(key, previousHistoryFromSnapshot(snapshot));
    });
  } catch {
    logWarn({ event: "community_prev_rank_batch_load_failed", boards: descriptors.length });
    for (const [key] of descriptors) result.set(key, EMPTY_PREVIOUS_BOARD_HISTORY);
  }
  return result;
}

async function loadPreviousRanksForBoards(
  db: CommunityFirestore,
  boards: Array<Pick<BoardWorkItem, "window" | "tier" | "geoKey">>,
): Promise<Map<string, Map<string, number>>> {
  const histories = await loadPreviousBoardHistoriesForBoards(db, boards);
  return new Map([...histories.entries()].map(([key, history]) => [key, rankMapFromHistory(history)]));
}

async function loadPreviousRanks(
  db: CommunityFirestore,
  window: WindowKey,
  tier: Tier,
  geoKey: string,
): Promise<Map<string, number>> {
  const ranks = await loadPreviousRanksForBoards(db, [{ window, tier, geoKey }]);
  return ranks.get(previousRankKey(window, tier, geoKey)) ?? new Map();
}

// ---------------------------------------------------------------------------
// Write + cleanup
// ---------------------------------------------------------------------------

function leaderboardRecord(board: CommunityLeaderboardDoc): Record<string, unknown> {
  return {
    window: board.window,
    tier: board.tier,
    geoKey: board.geoKey,
    cohortSize: board.cohortSize,
    belowThreshold: board.belowThreshold,
    entries: board.entries.map((entry) => ({
      anonId: entry.anonId,
      handle: entry.handle,
      rank: entry.rank,
      percentile: entry.percentile,
      totalTokens: entry.totalTokens,
      costUSD: entry.costUSD,
      movement: entry.movement,
    })),
    percentiles: {
      p50: board.percentiles.p50,
      p75: board.percentiles.p75,
      p90: board.percentiles.p90,
      p99: board.percentiles.p99,
    },
    updatedAt: board.updatedAt,
    schemaVersion: board.schemaVersion,
  };
}

async function writeLeaderboard(db: CommunityFirestore, board: CommunityLeaderboardDoc): Promise<void> {
  const docPath = CommunityPaths.leaderboard(board.window, board.tier, board.geoKey);
  await db.doc(docPath).set(leaderboardRecord(board));
}

function isStaleLeaderboardDoc(data: unknown, runStartedAt: Date): boolean {
  if (!isRecord(data)) return true;
  const updatedAt = typeof data.updatedAt === "string" ? Date.parse(data.updatedAt) : Number.NaN;
  return !Number.isFinite(updatedAt) || updatedAt < runStartedAt.getTime();
}

async function cleanupStaleLeaderboards(
  db: CommunityFirestore,
  activeDocPaths: Set<string>,
  runStartedAt: Date,
): Promise<number> {
  const snapshot = await db.collection("community_leaderboards").get();
  let batch = db.batch();
  let pending = 0;
  let deleted = 0;

  const commitPending = async () => {
    if (pending === 0) return;
    await batch.commit();
    batch = db.batch();
    pending = 0;
  };

  for (const doc of snapshot.docs) {
    if (activeDocPaths.has(doc.ref.path)) continue;
    if (!isStaleLeaderboardDoc(doc.data(), runStartedAt)) continue;
    batch.delete(doc.ref);
    pending++;
    deleted++;
    if (pending >= MAX_CLEANUP_BATCH_WRITES) await commitPending();
  }

  await commitPending();
  return deleted;
}

// ---------------------------------------------------------------------------
// Test exports (pure functions for unit testing)
// ---------------------------------------------------------------------------

export {
  computePercentiles,
  groupByGeoTier,
  buildLeaderboard,
  collectValidParticipants,
  loadPreviousRanksForBoards,
  loadPreviousRanks,
  loadPreviousBoardHistoriesForBoards,
  cleanupStaleLeaderboards,
};
export type { Participant, PreviousBoardHistory };
