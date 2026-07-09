/**
 * @fileoverview Hand-maintained types for the community share snapshot.
 *
 * These types use Record<> and @encodedName field keys that don't round-trip
 * through the TypeSpec canon gate (check-tsp-canon.mjs), so they're maintained
 * by hand here rather than in the generated community.ts — same pattern as
 * UsageRollupDoc in the legacy types.
 *
 * The canonical documentation lives in
 * tools/schema-sync/typespec/domains/community.tsp (listed under tspOnlyModels).
 */

/** Token + cost totals for a single leaderboard window. */
export interface CommunityUsageTotal {
  totalTokens: number;
  costUSD: number;
}

/** Totals keyed by leaderboard window. The "7d"/"30d"/"90d" keys are the
 *  canonical Firestore field names (not valid TS identifiers). */
export interface CommunityWindowTotals {
  today: CommunityUsageTotal;
  "7d": CommunityUsageTotal;
  "30d": CommunityUsageTotal;
  "90d": CommunityUsageTotal;
  all_time: CommunityUsageTotal;
}

/**
 * Firestore: users/{uid}/community/share_snapshot
 *
 * Per-window usage totals derived client-side from UsageRollupDoc merge.
 * Written only while L2 is granted. The hourly aggregation reads these via
 * collectionGroup to compute public leaderboards.
 */
export interface CommunityShareSnapshotDoc {
  windows: CommunityWindowTotals;
  modelMix: Record<string, number>;
  purposeMix: Record<string, number>;
  sessionCount?: number;
  countryCode?: string;
  regionKey?: string;
  cityKey?: string;
  revoked?: boolean;
  schemaVersion: number;
  updatedAt: string;
}
