import { resolveGeoDisplayLabel } from './geoDisplay.js';
import type { CommunityConsentState } from './consentStore.js';
import { isConsentActive } from './consentStore.js';
import type {
  CommunityLeaderboardCard,
  CommunityShareSnapshotDoc,
  CommunityTimeWindow,
  CommunityUsageTotal,
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

export type LookingGlassExportState = 'idle' | 'ready' | 'error' | 'unavailable';

export type LookingGlassExportCopy = {
  state: LookingGlassExportState;
  message: string;
};

export type CommunityLiveData = {
  shareSnapshot?: CommunityShareSnapshotDoc | null;
  leaderboards?: CommunityLeaderboardCard[];
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
  isPreviewData: boolean;
  statusMessage: string;
  cityConfidenceCopy: string;
  lookingGlassExport: LookingGlassExportCopy;
};

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
    case 'unavailable':
      return {
        state,
        message:
          'Looking Glass export is not wired on Linux yet. Grant L3 for when signed-in export is available; leaderboards never use traces.',
      };
    default:
      return {
        state,
        message:
          'Looking Glass export: grant L3 to create a private bundle; leaderboard rankings never use traces.',
      };
  }
}

function emptyPercentiles(): PercentileBands {
  return { p50: 0, p75: 0, p90: 0, p99: 0 };
}

function thresholdCards(consent: CommunityConsentState): CommunityLeaderboardCard[] {
  return GEO_TIER_ORDER.map((tier) => ({
    tier,
    geoLabel: resolveGeoDisplayLabel(consent, tier),
    entries: [],
    percentiles: emptyPercentiles(),
    cohortSize: 0,
    belowThreshold: true,
    kThreshold: 10,
  }));
}

function previewLeaderboards(consent: CommunityConsentState): CommunityLeaderboardCard[] {
  return GEO_TIER_ORDER.map((tier) => ({
    tier,
    geoLabel: resolveGeoDisplayLabel(consent, tier),
    entries: [],
    percentiles: emptyPercentiles(),
    cohortSize: 0,
    belowThreshold: true,
    kThreshold: 10,
  }));
}

function consentPreview(consent: CommunityConsentState): string {
  return `L1 ${consent.l1Analytics} · L2 ${consent.l2Rankings} · L3 ${consent.l3LookingGlass} · Location ${consent.locationConsent}`;
}

function usageForWindow(snapshot: CommunityShareSnapshotDoc | null | undefined, window: CommunityTimeWindow): CommunityUsageTotal {
  if (!snapshot) return { totalTokens: 0, costUSD: 0 };
  switch (window) {
    case 'today':
      return snapshot.windows.today;
    case '7d':
      return snapshot.windows.sevenDay;
    case '30d':
      return snapshot.windows.thirtyDay;
    case '90d':
      return snapshot.windows.ninetyDay;
    default:
      return snapshot.windows.allTime;
  }
}

function summarizeModelMix(modelMix: Record<string, number> | undefined): string {
  const entries = Object.entries(modelMix ?? {})
    .filter(([, share]) => Number.isFinite(share) && share > 0)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 2);
  if (entries.length === 0) return 'Live share snapshot synced; model mix appears after usage accrues.';
  return `Top models: ${entries.map(([name, share]) => `${name} ${Math.round(share * 100)}%`).join(' · ')}`;
}

function purposeBreakdown(snapshot: CommunityShareSnapshotDoc | null | undefined): PurposeSlice[] {
  const entries = Object.entries(snapshot?.purposeMix ?? {})
    .filter(([, value]) => Number.isFinite(value) && value > 0)
    .sort((a, b) => b[1] - a[1]);
  const total = entries.reduce((sum, [, value]) => sum + value, 0);
  if (total <= 0) return [];
  return entries.map(([category, value]) => ({ category, share: value / total }));
}

function primaryBoard(boards: CommunityLeaderboardCard[]): CommunityLeaderboardCard | undefined {
  return boards.find((board) => !board.belowThreshold && board.entries.length > 0) ?? boards[0];
}

function liveLeaderboards(
  consent: CommunityConsentState,
  live: CommunityLiveData | undefined,
): CommunityLeaderboardCard[] {
  const fallback = previewLeaderboards(consent);
  const byTier = new Map((live?.leaderboards ?? []).map((board) => [board.tier, board]));
  return GEO_TIER_ORDER.map((tier, index) => byTier.get(tier) ?? fallback[index]);
}

export function buildCommunityView(
  consent: CommunityConsentState,
  window: CommunityTimeWindow,
  live?: CommunityLiveData,
): CommunityViewState {
  if (!isConsentActive(consent.l2Rankings)) {
    return {
      hero: {
        tokens: 0,
        costUSD: 0,
        trendDeltaPct: 0,
        modelMixSummary: 'Opt in to L2 rankings to preview your share snapshot.',
      },
      leaderboards: thresholdCards(consent),
      percentiles: emptyPercentiles(),
      peerCohortTokens: [],
      purposeBreakdown: [],
      consentPreview: consentPreview(consent),
      showInvite: true,
      isPreviewData: false,
      statusMessage: '',
      cityConfidenceCopy: cityConfidenceCopy(consent),
      lookingGlassExport: lookingGlassExportCopy('idle'),
    };
  }

  const l3Export =
    consent.l3LookingGlass === 'granted'
      ? lookingGlassExportCopy('unavailable')
      : lookingGlassExportCopy('idle');
  const leaderboards = liveLeaderboards(consent, live);
  const board = primaryBoard(leaderboards);
  const usage = usageForWindow(live?.shareSnapshot, window);
  const hasLiveData = Boolean(live?.shareSnapshot) || leaderboards.some((candidate) => candidate.entries.length > 0 || candidate.cohortSize > 0);

  return {
    hero: {
      tokens: usage.totalTokens,
      costUSD: usage.costUSD,
      trendDeltaPct: 0,
      modelMixSummary: hasLiveData
        ? summarizeModelMix(live?.shareSnapshot?.modelMix)
        : 'Preview only — live leaderboards sync after community preferences save.',
    },
    leaderboards,
    percentiles: board?.percentiles ?? emptyPercentiles(),
    peerCohortTokens: board && !board.belowThreshold ? board.entries.map((entry) => entry.totalTokens) : [],
    purposeBreakdown: purposeBreakdown(live?.shareSnapshot),
    consentPreview: consentPreview(consent),
    showInvite: false,
    isPreviewData: !hasLiveData,
    statusMessage: hasLiveData
      ? 'Live community data synced. Public boards remain anonymous and threshold-gated.'
      : 'Preview layout only — no live leaderboard or cohort data is shown on this surface yet.',
    cityConfidenceCopy: cityConfidenceCopy(consent),
    lookingGlassExport: l3Export,
  };
}