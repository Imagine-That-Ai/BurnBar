import { classifyPurpose } from "./classifier";
import { isConsentActive } from "./localConsent";
import type {
  CommunityConsentDoc,
  CommunityLeaderboardDoc,
  CommunityTimeWindow,
  PercentileBands,
} from "./types";
import { GEO_TIER_ORDER } from "./types";

export type CommunityHero = {
  tokens: number;
  costUSD: number;
  trendDeltaPct: number;
  modelMixSummary: string;
};

export type PurposeSlice = { category: string; share: number };

export type CommunityViewState = {
  hero: CommunityHero;
  leaderboards: CommunityLeaderboardDoc[];
  percentiles: PercentileBands;
  peerCohortTokens: number[];
  purposeBreakdown: PurposeSlice[];
  consentPreview: string;
  showInvite: boolean;
};


function thresholdCards(): CommunityLeaderboardDoc[] {
  return GEO_TIER_ORDER.map((tier) => ({
    window: "30d",
    tier,
    geoKey: tier,
    entries: [],
    percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 },
    cohortSize: 0,
    belowThreshold: true,
    kThreshold: 10,
    updatedAt: new Date(0).toISOString(),
  }));
}

function sampleLeaderboards(consent: CommunityConsentDoc): CommunityLeaderboardDoc[] {
  return GEO_TIER_ORDER.map((tier) => {
    const below = tier === "city" && !isConsentActive(consent.locationConsent);
    const prefix = tier;
    if (below) {
      return {
        window: "30d",
        tier,
        geoKey: tier,
        entries: [],
        percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 },
        cohortSize: 0,
        belowThreshold: true,
        kThreshold: 10,
        updatedAt: new Date().toISOString(),
      };
    }
    return {
      window: "30d",
      tier,
      geoKey: tier,
      entries: [
        { rank: 1, anonId: `${prefix}-a1`, handle: "ember-fox", totalTokens: 1_200_000, costUSD: 3.4, movement: "same" },
        { rank: 2, anonId: `${prefix}-b2`, handle: "quiet-orbit", totalTokens: 980_000, costUSD: 2.8, movement: "up" },
        { rank: 3, anonId: `${prefix}-c3`, handle: "glass-pine", totalTokens: 860_000, costUSD: 2.1, movement: "down" },
      ],
      percentiles: { p50: 180_000, p75: 320_000, p90: 510_000, p99: 920_000 },
      cohortSize: 48,
      belowThreshold: false,
      kThreshold: 10,
      updatedAt: new Date().toISOString(),
    };
  });
}

function heroForWindow(window: CommunityTimeWindow): CommunityHero {
  const tokens =
    window === "today"
      ? 42_000
      : window === "7d"
        ? 310_000
        : window === "90d"
          ? 1_450_000
          : window === "all"
            ? 3_200_000
            : 890_000;
  return {
    tokens,
    costUSD: Math.round(tokens * 0.0000028 * 100) / 100,
    trendDeltaPct: 12.4,
    modelMixSummary: "claude-3.5-sonnet 42% · gpt-4o 31% · deepseek 27%",
  };
}

export function buildCommunityView(
  consent: CommunityConsentDoc,
  window: CommunityTimeWindow,
): CommunityViewState {
  if (!isConsentActive(consent.l2Rankings)) {
    return {
      hero: {
        tokens: 0,
        costUSD: 0,
        trendDeltaPct: 0,
        modelMixSummary: "Opt in to L2 rankings to preview your share snapshot.",
      },
      leaderboards: thresholdCards(),
      percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 },
      peerCohortTokens: [],
      purposeBreakdown: [],
      consentPreview: `L1 ${consent.l1Analytics} · L2 ${consent.l2Rankings} · L3 ${consent.l3LookingGlass} · Location ${consent.locationConsent}`,
      showInvite: true,
    };
  }

  const leaderboards = sampleLeaderboards(consent);
  const firstOpen = leaderboards.find((c) => !c.belowThreshold);

  const primary = classifyPurpose({
    fileExtensions: ["swift", "ts"],
    keywords: ["refactor", "ui"],
    model: "claude-3.5-sonnet",
    appSurface: "editor",
  });

  return {
    hero: heroForWindow(window),
    leaderboards,
    percentiles: firstOpen?.percentiles ?? { p50: 0, p75: 0, p90: 0, p99: 0 },
    peerCohortTokens: [120_000, 185_000, 240_000, 310_000, 420_000, 580_000],
    purposeBreakdown: [
      { category: primary.category, share: 0.34 },
      { category: "logic", share: 0.28 },
      { category: "backend", share: 0.18 },
      { category: "writing", share: 0.12 },
      { category: "other", share: 0.08 },
    ],
    consentPreview: `L1 ${consent.l1Analytics} · L2 ${consent.l2Rankings} · L3 ${consent.l3LookingGlass} · Location ${consent.locationConsent}`,
    showInvite: false,
  };
}