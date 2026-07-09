import { classifyPurpose } from './classifier.js';
import type { CommunityConsentState } from './consentStore.js';
import { isConsentActive } from './consentStore.js';
import type {
  CommunityLeaderboardCard,
  CommunityTimeWindow,
  GeographyTier,
  PercentileBands,
  PurposeSlice,
} from './types.js';
import { GEO_TIER_ORDER } from './types.js';

export type CommunityHero = {
  tokens: number;
  costUSD: number;
  trendDeltaPct: number;
  modelMixSummary: string;
};

export type LookingGlassExportState = 'idle' | 'ready' | 'error';

export type LookingGlassExportCopy = {
  state: LookingGlassExportState;
  message: string;
};

export const LOCAL_PARTICIPATION_PAUSED_COPY =
  'Participation paused locally. Sync revoke when signed in online.';

export type CommunityViewState = {
  hero: CommunityHero;
  leaderboards: CommunityLeaderboardCard[];
  percentiles: PercentileBands;
  peerCohortTokens: number[];
  purposeBreakdown: PurposeSlice[];
  consentPreview: string;
  showInvite: boolean;
  statusMessage: string;
  cityConfidenceCopy: string;
  lookingGlassExport: LookingGlassExportCopy;
};



function geoLabel(tier: GeographyTier): string {
  switch (tier) {
    case 'city':
      return 'San Francisco';
    case 'region':
      return 'California';
    case 'country':
      return 'United States';
    default:
      return 'Global';
  }
}

export function cityConfidenceCopy(consent: CommunityConsentState): string {
  const cityRequested = isConsentActive(consent.l2Rankings) && isConsentActive(consent.l2Tiers.city);
  if (!cityRequested) {
    return 'City confidence: no city lookup. Country and region can use locale/timezone; world ranking needs no location.';
  }
  if (!isConsentActive(consent.locationConsent)) {
    return 'City confidence: city rank is paused until city consent and a manual city label are provided; broader tiers still use locale/timezone.';
  }
  if (consent.manualCityInput?.trim()) {
    return 'City confidence: manual city label only; BurnBar stores the canonical city key, never raw coordinates.';
  }
  return 'City confidence: manual city label required; BurnBar does not reverse-geocode desktop/browser coordinates.';
}

export function lookingGlassExportCopy(state: LookingGlassExportState): LookingGlassExportCopy {
  switch (state) {
    case 'ready':
      return {
        state,
        message:
          'Looking Glass export ready: download link expires in 15 minutes and never feeds leaderboards.',
      };
    case 'error':
      return {
        state,
        message: 'Looking Glass export failed: no traces left the device; try again after reconnecting.',
      };
    default:
      return {
        state,
        message:
          'Looking Glass export: grant L3 to create a private bundle; leaderboard rankings never use traces.',
      };
  }
}


function thresholdCards(): CommunityLeaderboardCard[] {
  return GEO_TIER_ORDER.map((tier) => ({
    tier,
    geoLabel: geoLabel(tier),
    entries: [],
    percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 },
    cohortSize: 0,
    belowThreshold: true,
    kThreshold: 10,
  }));
}

function sampleEntries(tier: GeographyTier) {
  const prefix = tier === 'city' ? 'city' : tier === 'region' ? 'region' : tier === 'country' ? 'country' : 'world';
  return [
    { rank: 1, anonId: `${prefix}-a1`, handle: 'ember-fox', totalTokens: 1_200_000, costUSD: 3.4, movement: 'same' as const },
    { rank: 2, anonId: `${prefix}-b2`, handle: 'quiet-orbit', totalTokens: 980_000, costUSD: 2.8, movement: 'up' as const },
    { rank: 3, anonId: `${prefix}-c3`, handle: 'glass-pine', totalTokens: 860_000, costUSD: 2.1, movement: 'down' as const },
  ];
}

function sampleLeaderboards(consent: CommunityConsentState): CommunityLeaderboardCard[] {
  return GEO_TIER_ORDER.map((tier) => {
    const below = tier === 'city' && !isConsentActive(consent.locationConsent);
    if (below) {
      return {
        tier,
        geoLabel: geoLabel(tier),
        entries: [],
        percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 },
        cohortSize: 0,
        belowThreshold: true,
        kThreshold: 10,
      };
    }
    return {
      tier,
      geoLabel: geoLabel(tier),
      entries: sampleEntries(tier),
      percentiles: { p50: 180_000, p75: 320_000, p90: 510_000, p99: 920_000 },
      cohortSize: 48,
      belowThreshold: false,
      kThreshold: 10,
      yourRank: 12,
      yourMovement: 'up',
    };
  });
}

function heroForWindow(window: CommunityTimeWindow): CommunityHero {
  const tokens =
    window === 'today'
      ? 42_000
      : window === '7d'
        ? 310_000
        : window === '90d'
          ? 1_450_000
          : window === 'all'
            ? 3_200_000
            : 890_000;
  return {
    tokens,
    costUSD: Math.round(tokens * 0.0000028 * 100) / 100,
    trendDeltaPct: 12.4,
    modelMixSummary: 'claude-3.5-sonnet 42% · gpt-4o 31% · deepseek 27%',
  };
}

function purposeBreakdown(): PurposeSlice[] {
  const primary = classifyPurpose({
    fileExtensions: ['swift', 'ts'],
    keywords: ['refactor', 'ui'],
    model: 'claude-3.5-sonnet',
    appSurface: 'editor',
  });
  return [
    { category: primary.category, share: 0.34 },
    { category: 'logic', share: 0.28 },
    { category: 'backend', share: 0.18 },
    { category: 'writing', share: 0.12 },
    { category: 'other', share: 0.08 },
  ];
}

function consentPreview(consent: CommunityConsentState): string {
  return `L1 ${consent.l1Analytics} · L2 ${consent.l2Rankings} · L3 ${consent.l3LookingGlass} · Location ${consent.locationConsent}`;
}

export function buildCommunityView(
  consent: CommunityConsentState,
  window: CommunityTimeWindow,
): CommunityViewState {
  if (!isConsentActive(consent.l2Rankings)) {
    return {
      hero: {
        tokens: 0,
        costUSD: 0,
        trendDeltaPct: 0,
        modelMixSummary: 'Opt in to L2 rankings to preview your share snapshot.',
      },
      leaderboards: thresholdCards(),
      percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 },
      peerCohortTokens: [],
      purposeBreakdown: [],
      consentPreview: consentPreview(consent),
      showInvite: true,
      statusMessage: '',
      cityConfidenceCopy: cityConfidenceCopy(consent),
      lookingGlassExport: lookingGlassExportCopy('idle'),
    };
  }

  const leaderboards = sampleLeaderboards(consent);
  const firstOpen = leaderboards.find((c) => !c.belowThreshold);

  return {
    hero: heroForWindow(window),
    leaderboards,
    percentiles: firstOpen?.percentiles ?? { p50: 0, p75: 0, p90: 0, p99: 0 },
    peerCohortTokens: [120_000, 185_000, 240_000, 310_000, 420_000, 580_000],
    purposeBreakdown: purposeBreakdown(),
    consentPreview: consentPreview(consent),
    showInvite: false,
    statusMessage: '',
    cityConfidenceCopy: cityConfidenceCopy(consent),
    lookingGlassExport: lookingGlassExportCopy('idle'),
  };
}