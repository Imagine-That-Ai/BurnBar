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
    expect(stableVisualSnapshot(view)).toMatchInlineSnapshot(`
      {
        "cityConfidenceCopy": "City confidence: no city lookup. Country and region can use locale/timezone; world ranking needs no location.",
        "consentPreview": "L1 unset · L2 unset · L3 unset · Location unset",
        "hero": "Opt in to L2 rankings to preview your share snapshot.",
        "leaderboards": [
          {
            "belowThreshold": true,
            "cohortSize": 0,
            "entryAnonIds": [],
            "geoLabel": "San Francisco",
            "tier": "city",
          },
          {
            "belowThreshold": true,
            "cohortSize": 0,
            "entryAnonIds": [],
            "geoLabel": "California",
            "tier": "region",
          },
          {
            "belowThreshold": true,
            "cohortSize": 0,
            "entryAnonIds": [],
            "geoLabel": "United States",
            "tier": "country",
          },
          {
            "belowThreshold": true,
            "cohortSize": 0,
            "entryAnonIds": [],
            "geoLabel": "Global",
            "tier": "world",
          },
        ],
        "lookingGlassExport": {
          "message": "Looking Glass export: grant L3 to create a private bundle; leaderboard rankings never use traces.",
          "state": "idle",
        },
        "peerCohortCount": 0,
        "purposeCategories": [],
        "showInvite": true,
        "statusMessage": "",
      }
    `);
  });

  it('city location denied keeps city board empty without inventing a raw city key', () => {
    const view = buildCommunityView(
      grantedConsent({ locationConsent: 'declined' }),
      '30d',
    );
    const city = view.leaderboards.find((board) => board.tier === 'city');
    expect(city?.belowThreshold).toBe(true);
    expect(city?.entries).toEqual([]);
    expect(city?.geoLabel).toBe('San Francisco');
    expect(view.cityConfidenceCopy).toMatch(/paused until city consent and a manual city label/i);
  });

  it('live participation renders anonymized leaderboard rows', () => {
    const view = buildCommunityView(grantedConsent(), '30d');
    expect(view.showInvite).toBe(false);
    expect(view.peerCohortTokens.length).toBeGreaterThan(0);
    const region = view.leaderboards.find((board) => board.tier === 'region');
    expect(region?.belowThreshold).toBe(false);
    expect(region?.entries.map((e) => e.anonId)).toEqual(['region-a1', 'region-b2', 'region-c3']);
    expect(view.cityConfidenceCopy).toMatch(/manual city label required/i);
  });

  it('local revoke copy matches paused participation messaging', () => {
    expect(LOCAL_PARTICIPATION_PAUSED_COPY).toBe(
      'Participation paused locally. Sync revoke when signed in online.',
    );
  });

  it('Looking Glass export ready and error copy stay stable', () => {
    expect(lookingGlassExportCopy('ready').message).toContain('15 minutes');
    expect(lookingGlassExportCopy('error').message).toMatch(/no traces left the device/i);
  });
});