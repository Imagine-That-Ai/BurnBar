export type ConsentTriState = 'unset' | 'granted' | 'declined';

export type GeographyTier = 'world' | 'country' | 'region' | 'city';

export type CommunityTimeWindow = 'today' | '7d' | '30d' | '90d' | 'all_time';

export type RankMovement = 'up' | 'down' | 'same' | 'new';

export interface LeaderboardEntry {
  rank: number;
  handle?: string;
  anonId: string;
  totalTokens: number;
  costUSD: number;
  movement: RankMovement;
}

export interface PercentileBands {
  p50: number;
  p75: number;
  p90: number;
  p99: number;
}

export interface CommunityLeaderboardCard {
  tier: GeographyTier;
  geoLabel: string;
  entries: LeaderboardEntry[];
  percentiles: PercentileBands;
  cohortSize: number;
  belowThreshold: boolean;
  kThreshold: number;
  yourRank?: number;
  yourMovement?: RankMovement;
}

export interface PurposeSlice {
  category: string;
  share: number;
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
}

export const GEO_TIER_ORDER: GeographyTier[] = ['city', 'region', 'country', 'world'];

export const TIME_WINDOWS: { id: CommunityTimeWindow; label: string }[] = [
  { id: 'today', label: 'Today' },
  { id: '7d', label: '7d' },
  { id: '30d', label: '30d' },
  { id: '90d', label: '90d' },
  { id: 'all_time', label: 'All' },
];