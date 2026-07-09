// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { CommunitySurface } from './CommunitySurface.js';
import { defaultCommunityConsent, type CommunityConsentState } from './consentStore.js';
import { useCommunityStore } from '../state/communityStore.js';
import { useShellStore } from '../state/shellStore.js';
import type { LinuxShellBridge } from '../tauriBridge.js';

const CONSENT_KEY = 'openburnbar.linux.communityConsent.v1';

function grantedConsent(partial: Partial<CommunityConsentState> = {}): CommunityConsentState {
  const base = defaultCommunityConsent();
  return {
    ...base,
    l2Rankings: 'granted',
    l2Tiers: { world: 'granted', country: 'granted', region: 'granted', city: 'granted' },
    locationConsent: 'granted',
    manualCityInput: 'Berlin',
    ...partial,
  };
}

function persistConsent(consent: CommunityConsentState): void {
  localStorage.setItem(CONSENT_KEY, JSON.stringify(consent));
}

function resetStores(): void {
  localStorage.clear();
  useCommunityStore.setState({ liveData: null, loading: false, error: null });
  useShellStore.setState({
    bridge: null,
    bridgeReady: true,
    fixtureMode: false,
  });
}

describe('CommunitySurface Linux live data seam', () => {
  beforeEach(resetStores);
  afterEach(() => {
    cleanup();
    resetStores();
  });

  it('degrades to explicit preview when no daemon community bridge exists', async () => {
    persistConsent(grantedConsent());
    render(<CommunitySurface />);

    expect(await screen.findByText(/Preview layout only/i)).toBeTruthy();
    expect(screen.getByText(/Preview — not live usage or rankings/i)).toBeTruthy();
  });

  it('renders bridge-supplied share snapshot and leaderboard docs through the component', async () => {
    persistConsent(grantedConsent());
    useShellStore.setState({
      bridge: {
        communityLiveData: async () => ({
          shareSnapshot: {
            windows: {
              today: { totalTokens: 1_000, costUSD: 1.25 },
              sevenDay: { totalTokens: 7_000, costUSD: 8.5 },
              thirtyDay: { totalTokens: 30_000, costUSD: 37.5 },
              ninetyDay: { totalTokens: 90_000, costUSD: 112.5 },
              allTime: { totalTokens: 120_000, costUSD: 150 },
            },
            modelMix: { gpt: 0.7, claude: 0.3 },
            purposeMix: { coding: 8, research: 2 },
          },
          leaderboards: [
            {
              tier: 'city',
              geoLabel: 'Berlin',
              entries: [
                { rank: 1, anonId: 'anon-self', handle: 'you', totalTokens: 30_000, costUSD: 37.5, movement: 'up' },
                { rank: 2, anonId: 'anon-peer', totalTokens: 12_000, costUSD: 16, movement: 'same' },
              ],
              percentiles: { p50: 10_000, p75: 20_000, p90: 30_000, p99: 45_000 },
              cohortSize: 12,
              belowThreshold: false,
              kThreshold: 10,
              yourRank: 1,
              yourMovement: 'up',
            },
          ],
        }),
      } as unknown as LinuxShellBridge,
      bridgeReady: true,
    });

    render(<CommunitySurface />);

    expect(await screen.findByText(/Live community data synced/i)).toBeTruthy();
    expect(screen.getByText('30,000')).toBeTruthy();
    expect(screen.getByText(/Top models: gpt 70% · claude 30%/i)).toBeTruthy();
    expect(screen.getByText(/#1 you · 30,000 tok/i)).toBeTruthy();
    await waitFor(() => expect(useCommunityStore.getState().error).toBeNull());
  });
});
