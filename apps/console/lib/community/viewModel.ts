import { resolveGeoDisplayLabel } from "./geoDisplay";
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
export type LookingGlassExportState = "idle" | "ready" | "error";

export type LookingGlassExportCopy = {
  state: LookingGlassExportState;
  message: string;
};

export type CommunityViewState = {
  hero: CommunityHero;
  leaderboards: CommunityLeaderboardDoc[];
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

export const LOCAL_PARTICIPATION_PAUSED_COPY =
  "Participation paused locally. Sync revoke when signed in online.";

export function cityConfidenceCopy(consent: CommunityConsentDoc): string {
  const cityRequested = isConsentActive(consent.l2Rankings) && isConsentActive(consent.l2Tiers.city);
  if (!cityRequested) {
    return "City confidence: no city lookup. Country and region can use locale/timezone; world ranking needs no location.";
  }
  if (!isConsentActive(consent.locationConsent)) {
    return "City confidence: city rank is paused until city consent and a manual city label are provided; broader tiers still use locale/timezone.";
  }
  if (consent.manualCityInput?.trim()) {
    return "City confidence: manual city label only; BurnBar stores the canonical city key, never raw coordinates.";
  }
  return "City confidence: manual city label required; BurnBar does not reverse-geocode browser coordinates.";
}

export function lookingGlassExportCopy(state: LookingGlassExportState): LookingGlassExportCopy {
  switch (state) {
    case "ready":
      return {
        state,
        message: "Looking Glass export ready: download link expires in 15 minutes and never feeds leaderboards.",
      };
    case "error":
      return {
        state,
        message: "Looking Glass export failed: no traces left the device; try again after reconnecting.",
      };
    default:
      return {
        state,
        message: "Looking Glass export: grant L3 to create a private bundle; leaderboard rankings never use traces.",
      };
  }
}

function thresholdCards(consent: CommunityConsentDoc): CommunityLeaderboardDoc[] {
  return GEO_TIER_ORDER.map((tier) => ({
    window: "30d",
    tier,
    geoKey: resolveGeoDisplayLabel(consent, tier),
    entries: [],
    percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 },
    cohortSize: 0,
    belowThreshold: true,
    kThreshold: 10,
    updatedAt: new Date(0).toISOString(),
  }));
}

function previewLeaderboards(consent: CommunityConsentDoc): CommunityLeaderboardDoc[] {
  return GEO_TIER_ORDER.map((tier) => ({
    window: "30d",
    tier,
    geoKey: resolveGeoDisplayLabel(consent, tier),
    entries: [],
    percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 },
    cohortSize: 0,
    belowThreshold: true,
    kThreshold: 10,
    updatedAt: new Date().toISOString(),
  }));
}
export function buildCommunityView(
  consent: CommunityConsentDoc,
  _window: CommunityTimeWindow,
): CommunityViewState {
  if (!isConsentActive(consent.l2Rankings)) {
    return {
      hero: {
        tokens: 0,
        costUSD: 0,
        trendDeltaPct: 0,
        modelMixSummary: "Opt in to L2 rankings to preview your share snapshot.",
      },
      leaderboards: thresholdCards(consent),
      percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 },
      peerCohortTokens: [],
      purposeBreakdown: [],
      consentPreview: `L1 ${consent.l1Analytics} · L2 ${consent.l2Rankings} · L3 ${consent.l3LookingGlass} · Location ${consent.locationConsent}`,
      showInvite: true,
      isPreviewData: false,
      statusMessage: "",
      cityConfidenceCopy: cityConfidenceCopy(consent),
      lookingGlassExport: lookingGlassExportCopy("idle"),
    };
  }

  return {
    hero: {
      tokens: 0,
      costUSD: 0,
      trendDeltaPct: 0,
      modelMixSummary: "Preview only — live leaderboards sync after community preferences save.",
    },
    leaderboards: previewLeaderboards(consent),
    percentiles: { p50: 0, p75: 0, p90: 0, p99: 0 },
    peerCohortTokens: [],
    purposeBreakdown: [],
    consentPreview: `L1 ${consent.l1Analytics} · L2 ${consent.l2Rankings} · L3 ${consent.l3LookingGlass} · Location ${consent.locationConsent}`,
    showInvite: false,
    isPreviewData: true,
    statusMessage: "Preview layout only — no live leaderboard or cohort data is shown on this surface yet.",
    cityConfidenceCopy: cityConfidenceCopy(consent),
    lookingGlassExport: lookingGlassExportCopy("idle"),
  };
}