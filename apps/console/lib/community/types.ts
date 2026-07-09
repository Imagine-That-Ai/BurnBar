/** Mirrors functions/src/types/generated/community.ts (subset used by the console UI). */

export type ConsentTriState = "unset" | "granted" | "declined";

export type GeographyTier = "world" | "country" | "region" | "city";

export type CommunityTimeWindow = "today" | "7d" | "30d" | "90d" | "all";

export type RankMovement = "up" | "down" | "same" | "new";

export interface CommunityTierConsent {
  world: ConsentTriState;
  country: ConsentTriState;
  region: ConsentTriState;
  city: ConsentTriState;
}

export interface CommunityConsentDoc {
  l1Analytics: ConsentTriState;
  l2Rankings: ConsentTriState;
  l2Tiers: CommunityTierConsent;
  l3LookingGlass: ConsentTriState;
  locationConsent: ConsentTriState;
  manualCityInput?: string;
  schemaVersion: number;
  updatedAt: string;
  optedInAt?: string;
}

export interface CommunityProfileDoc {
  handle?: string;
  anonId: string;
  countryCode?: string;
  regionKey?: string;
  cityKey?: string;
  schemaVersion: number;
  updatedAt: string;
}

export interface LeaderboardEntry {
  rank: number;
  handle?: string;
  anonId: string;
  totalTokens: number;
  costUSD: number;
  movement: RankMovement | string;
}

export interface PercentileBands {
  p50: number;
  p75: number;
  p90: number;
  p99: number;
}

export interface CommunityLeaderboardDoc {
  window: string;
  tier: GeographyTier | string;
  geoKey: string;
  entries: LeaderboardEntry[];
  percentiles: PercentileBands;
  cohortSize: number;
  belowThreshold: boolean;
  kThreshold: number;
  updatedAt: string;
}

export interface CommunityUsageTotal {
  totalTokens: number;
  costUSD: number;
}

export interface CommunityWindowTotals {
  today: CommunityUsageTotal;
  sevenDay: CommunityUsageTotal;
  thirtyDay: CommunityUsageTotal;
  ninetyDay: CommunityUsageTotal;
  allTime: CommunityUsageTotal;
}

export interface CommunityShareSnapshotDoc {
  windows: CommunityWindowTotals;
  modelMix: Record<string, number>;
  purposeMix: Record<string, number>;
  sessionCount?: number;
  updatedAt?: string;
}

export const GEO_TIER_ORDER: GeographyTier[] = ["city", "region", "country", "world"];

export const TIME_WINDOWS: { id: CommunityTimeWindow; label: string }[] = [
  { id: "today", label: "Today" },
  { id: "7d", label: "7d" },
  { id: "30d", label: "30d" },
  { id: "90d", label: "90d" },
  { id: "all", label: "All" },
];