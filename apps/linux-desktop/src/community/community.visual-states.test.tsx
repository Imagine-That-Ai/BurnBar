import { describe, expect, it } from 'vitest';

import {
  LOCAL_PARTICIPATION_PAUSED_COPY,
  buildCommunityView,
  lookingGlassExportCopy,
  type CommunityViewState,
} from './communityModel.js';
import { defaultCommunityConsent, type CommunityConsentState } from './consentStore.js';

function grantedConsent(partial: Partial<CommunityConsentState> = {}): CommunityConsentState {
  const base = defaultCommunityConsent();
  return {
    ...base,
    l2Rankings: 'granted',
    l2Tiers: { world: 'granted', country: 'granted', region: 'granted', city: 'granted' },
    locationConsent: 'granted',
    l3LookingGlass: 'granted',
    ...partial,
  };
}

function stableVisualSnapshot(view: CommunityViewState) {
  return {
    showInvite: view.showInvite,
    isPreviewData: view.isPreviewData,
    hero: view.hero.modelMixSummary,
    peerCohortCount: view.peerCohortTokens.length,
    purposeCategories: view.purposeBreakdown.map((slice) => slice.category),
    consentPreview: view.consentPreview,
    statusMessage: view.statusMessage,
    cityConfidenceCopy: view.cityConfidenceCopy,
    lookingGlassExport: view.lookingGlassExport,
    leaderboards: view.leaderboards.map((board) => ({
      tier: board.tier,
      geoLabel: board.geoLabel,
      belowThreshold: board.belowThreshold,
      cohortSize: board.cohortSize,
      entryAnonIds: board.entries.map((entry) => entry.anonId),
    })),
  };
}

describe('community visual states (linux)', () => {
  it('opted-out L2 shows invite and withheld cohort chart', () => {
    const view = buildCommunityView(defaultCommunityConsent(), '30d');
    expect(stableVisualSnapshot(view)).toMatchObject({
      showInvite: true,
      isPreviewData: false,
      peerCohortCount: 0,
      purposeCategories: [],
    });
    expect(view.leaderboards.every((b) => b.geoLabel !== 'San Francisco' || b.tier !== 'city')).toBe(true);
    expect(view.leaderboards.find((b) => b.tier === 'city')?.geoLabel).toMatch(/unavailable|manual/i);
  });

  it('city location denied keeps city board empty without inventing a raw city key', () => {
    const view = buildCommunityView(grantedConsent({ locationConsent: 'declined' }), '30d');
    const city = view.leaderboards.find((board) => board.tier === 'city');
    expect(city?.belowThreshold).toBe(true);
    expect(city?.entries).toEqual([]);
    expect(city?.geoLabel).not.toBe('San Francisco');
    expect(view.cityConfidenceCopy).toMatch(/paused until city consent and a manual city label/i);
  });

  it('opted-in L2 renders preview-only empty leaderboards', () => {
    const view = buildCommunityView(grantedConsent({ manualCityInput: 'Berlin' }), '30d');
    expect(view.showInvite).toBe(false);
    expect(view.isPreviewData).toBe(true);
    expect(view.peerCohortTokens).toEqual([]);
    expect(view.leaderboards.every((b) => b.entries.length === 0)).toBe(true);
    expect(view.leaderboards.find((b) => b.tier === 'city')?.geoLabel).toBe('Berlin');
    expect(view.lookingGlassExport.state).toBe('unavailable');
  });

  it('all_time window id is accepted for view build', () => {
    const view = buildCommunityView(grantedConsent(), 'all_time');
    expect(view.isPreviewData).toBe(true);
  });

  it('local revoke copy matches paused participation messaging', () => {
    expect(LOCAL_PARTICIPATION_PAUSED_COPY).toBe(
      'Participation paused locally. Sync revoke when signed in online.',
    );
  });

  it('Looking Glass export ready and error copy stay stable', () => {
    expect(lookingGlassExportCopy('ready').message).toContain('15 minutes');
    expect(lookingGlassExportCopy('error').message).toMatch(/no traces left the device/i);
    expect(lookingGlassExportCopy('unavailable').message).toMatch(/not wired on Linux/i);
  });
});