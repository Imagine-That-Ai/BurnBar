/**
 * BurnBar Community — consent-gated leaderboards + Looking Glass Mode.
 *
 * Three independent tri-state consent ladders (L1/L2/L3) gate data flow:
 *   L1 Private Analytics — local-only personal dashboard (no egress).
 *   L2 Community Rankings — per-geography-tier share snapshots that feed
 *      public aggregate leaderboards behind a k-anonymity threshold.
 *   L3 Looking Glass Mode — richer private traces + export bundles; never
 *      feeds leaderboards.
 *
 * Collection paths documented in manifest.json.
 */
namespace OpenBurnBar.Firestore.Community;

// ---------------------------------------------------------------------------
// Canonical value aliases (documentation-only; model fields use `string` so
// the emit round-trips through check-tsp-canon without alias-resolution
// mismatches, matching the usage-quota convention).
// ---------------------------------------------------------------------------

/** Tri-state: "unset" | "granted" | "declined" — server treats unset and
 *  declined identically (fail closed). Modeled on AnalyticsConsentStore. */
alias ConsentTriState = "unset" | "granted" | "declined";

/** Geography tiers, broadest-to-narrowest. */
alias GeographyTier = "world" | "country" | "region" | "city";

/** Movement direction vs. previous aggregation cycle. */
alias RankMovement = "up" | "down" | "same" | "new";

/** Classifier purpose categories. */
alias ModelPurposeCategory = "ui" | "backend" | "logic" | "writing" | "research" | "debugging" | "orchestration" | "other";

/** Looking Glass export format. */
alias LookingGlassExportFormat = "jsonl" | "parquet";

// ---------------------------------------------------------------------------
// Consent
// ---------------------------------------------------------------------------

/**
 * Firestore: users/{uid}/community/consent
 *
 * Per-level and per-tier tri-state consent states with timestamps. The entire
 * document defaults to "unset" (fully dark) until the user explicitly grants.
 * Revoking L2 triggers revokeCommunityParticipation (delete share/profile docs).
 */
model CommunityConsentDoc {
  /** L1 Private Analytics — local-only personal dashboard. No egress. */
  l1Analytics: string;

  /** L2 Community Rankings — per-geography-tier sub-toggles. */
  l2Rankings: string;

  /** Per-tier ranking opt-in. City additionally requires location consent. */
  l2Tiers: CommunityTierConsent;

  /** L3 Looking Glass Mode — richer traces + export bundles. */
  l3LookingGlass: string;

  /** Separate consent for coarse OS location (city tier prerequisite). */
  locationConsent: string;

  schemaVersion: int32;

  /** ISO 8601 — last consent change. */
  updatedAt: string;

  /** ISO 8601 — first opt-in of any level. */
  optedInAt?: string;
}

/** Per-geography-tier tri-state for L2 rankings. */
model CommunityTierConsent {
  world: string;
  country: string;
  region: string;
  city: string;
}

// ---------------------------------------------------------------------------
// Profile
// ---------------------------------------------------------------------------

/**
 * Firestore: users/{uid}/community/profile
 *
 * Optional display handle (auto-generated, editable, anonymous default) and a
 * stable anonId. Geo keys (countryCode, regionKey, cityKey) are populated ONLY
 * at consented tiers — never raw coordinates.
 */
model CommunityProfileDoc {
  /** Editable display handle; null = fully anonymous. */
  handle?: string;

  /** Stable anonymous identifier for leaderboard entries. */
  anonId: string;

  /** ISO 3166-1 alpha-2 country code (populated when country tier consented). */
  countryCode?: string;

  /** Region/state key (populated when region tier consented). */
  regionKey?: string;

  /** City key (populated when city tier consented). */
  cityKey?: string;

  schemaVersion: int32;

  updatedAt: string;
}

// ---------------------------------------------------------------------------
// Share snapshot
// ---------------------------------------------------------------------------

/**
 * Firestore: users/{uid}/community/share_snapshot
 *
 * Per-window usage totals derived client-side from UsageRollupDoc merge.
 * Written only while L2 is granted. The hourly aggregation reads these via
 * collectionGroup to compute public leaderboards.
 *
 * The emitter keeps explicit language-native shapes for Record<> maps and
 * non-identifier window keys (7d/30d/90d/all_time).
 */
model CommunityShareSnapshotDoc {
  windows: CommunityWindowTotals;
  modelMix: Record<float32>;
  purposeMix: Record<float32>;
  sessionCount?: int32;
  countryCode?: string;
  regionKey?: string;
  cityKey?: string;
  revoked?: boolean;
  schemaVersion: int32;
  updatedAt: string;
}

model CommunityWindowTotals {
  today: CommunityUsageTotal;
  @encodedName("application/json", "7d") sevenDay: CommunityUsageTotal;
  @encodedName("application/json", "30d") thirtyDay: CommunityUsageTotal;
  @encodedName("application/json", "90d") ninetyDay: CommunityUsageTotal;
  all_time: CommunityUsageTotal;
}

model CommunityUsageTotal {
  totalTokens: int64;
  costUSD: float64;
}

// ---------------------------------------------------------------------------
// Leaderboards (public read-only, admin-write only)
// ---------------------------------------------------------------------------

/** A single leaderboard row. */
model LeaderboardEntry {
  rank: int32;
  percentile: float64;
  handle?: string;
  anonId: string;
  totalTokens: int64;
  costUSD: float64;
  movement: string;
}

model PercentileBands {
  p50: float64;
  p75: float64;
  p90: float64;
  p99: float64;
}

/**
 * Firestore: community_leaderboards/{window}_{tier}_{geoKey}
 *
 * Public aggregate document: top-100 entries, percentile bands, cohort size,
 * and belowThreshold flag. Admin-write only (onSchedule aggregation function).
 * Authenticated clients have read-only access.
 */
model CommunityLeaderboardDoc {
  window: string;
  tier: string;
  geoKey: string;
  entries: LeaderboardEntry[];
  percentiles: PercentileBands;
  cohortSize: int32;
  belowThreshold: boolean;
  kThreshold: int32;
  updatedAt: string;
  schemaVersion: int32;
}

// ---------------------------------------------------------------------------
// Looking Glass (L3, private)
// ---------------------------------------------------------------------------

/**
 * Firestore: users/{uid}/looking_glass_traces/{id}
 *
 * L3-only private trace of a single session's model-purpose classification.
 * Never feeds leaderboards. Exported via exportLookingGlassBundle.
 */
model LookingGlassTraceDoc {
  sessionId: string;
  `model`: string;
  provider: string;
  purpose: string;
  corrected: boolean;
  inferredPurpose?: string;
  totalTokens: int64;
  costUSD: float64;
  signals?: string[];
  recordedAt: string;
  schemaVersion: int32;
}

/**
 * Firestore: users/{uid}/looking_glass_exports/{id}
 *
 * Metadata for an exported Looking Glass bundle (signed Storage URL).
 */
model LookingGlassExportDoc {
  storagePath: string;
  format: string;
  traceCount: int32;
  sizeBytes: int64;
  createdAt: string;
  schemaVersion: int32;
}
