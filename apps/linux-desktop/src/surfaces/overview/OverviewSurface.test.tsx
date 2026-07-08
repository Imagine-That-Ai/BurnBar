// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi, type Mock } from 'vitest';
import {
  fixtureDaemonHealth,
  fixtureUsageInsights,
  fixtureUsageSummary
} from '../../daemonFixture.js';
import type { LinuxShellBridge, UsageSummary } from '../../tauriBridge.js';
import { useInsightsStore } from '../../state/insightsStore.js';
import { useOverviewStore } from '../../state/overviewStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { OverviewSurface } from '../OverviewSurface.js';

const realOverviewLoad = useOverviewStore.getState().load;
const realInsightsLoad = useInsightsStore.getState().load;

function resetStores(): void {
  localStorage.clear();
  location.hash = '#/overview';
  useShellStore.setState({
    route: 'overview',
    health: null,
    healthError: null,
    healthBusy: false,
    trayDegraded: false,
    skin: 'editorial',
    bridge: null,
    bridgeReady: true,
    fixtureMode: false
  });
  useOverviewStore.setState({
    summary: null,
    cacheHitRatePct: null,
    lastRefreshedAt: null,
    loading: false,
    error: null,
    load: realOverviewLoad
  });
  useInsightsStore.setState({
    data: null,
    loading: false,
    error: null,
    load: realInsightsLoad
  });
}

function freezeLoads(): { overviewLoad: Mock<() => Promise<void>>; insightsLoad: Mock<() => Promise<void>> } {
  const overviewLoad = vi.fn(async () => {});
  const insightsLoad = vi.fn(async () => {});
  useOverviewStore.setState({ load: overviewLoad });
  useInsightsStore.setState({ load: insightsLoad });
  return { overviewLoad, insightsLoad };
}

const emptySummary: UsageSummary = {
  todayTokens: 0,
  todayCostUsd: 0,
  sevenDay: [0, 0, 0, 0, 0, 0, 0],
  recentEvents: []
};

describe('OverviewSurface', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('renders Atelier hero, provider rail, and stat tiles in fixture mode', () => {
    freezeLoads();
    useShellStore.setState({
      fixtureMode: true,
      health: fixtureDaemonHealth('/tmp/openburnbar.sock')
    });
    useOverviewStore.setState({
      summary: fixtureUsageSummary(),
      cacheHitRatePct: fixtureUsageInsights().cacheHitRatePct,
      lastRefreshedAt: new Date('2026-07-05T12:00:00Z'),
      loading: false,
      error: null
    });
    useInsightsStore.setState({
      data: fixtureUsageInsights(),
      loading: false,
      error: null
    });
    render(<OverviewSurface />);
    expect(screen.getByText(/living substrate/i)).toBeTruthy();
    expect(screen.getByText('MiMo')).toBeTruthy();
    expect(screen.getByText('Hermes')).toBeTruthy();
    expect(screen.getByText('Burn · Today')).toBeTruthy();
    expect(screen.getByText('Cache hit rate')).toBeTruthy();
    expect(document.querySelector('.atelier-spend-curve-svg')).toBeTruthy();
    expect(screen.getByText(/Data source: fixture transcript/)).toBeTruthy();
  });

  it('renders loading skeleton with aria-busy', () => {
    freezeLoads();
    useShellStore.setState({ fixtureMode: true, health: fixtureDaemonHealth('/tmp/x.sock') });
    const { container } = render(<OverviewSurface />);
    act(() => {
      useOverviewStore.setState({ loading: true });
      useInsightsStore.setState({ loading: true });
    });
    expect(container.querySelector('[aria-busy="true"]')).toBeTruthy();
  });

  it('renders empty provider rail and empty curve when summary has no spend', () => {
    freezeLoads();
    useShellStore.setState({ fixtureMode: false, health: fixtureDaemonHealth('/tmp/x.sock'), bridge: {} as LinuxShellBridge });
    useOverviewStore.setState({
      loading: false,
      error: null,
      summary: emptySummary,
      cacheHitRatePct: 0
    });
    useInsightsStore.setState({
      data: { weekly: [], providerMix: [], modelMix: [], cacheHitRatePct: 0 },
      loading: false,
      error: null
    });
    render(<OverviewSurface />);
    expect(screen.getByText('No provider activity yet.')).toBeTruthy();
    expect(screen.getByText('No spend in this range')).toBeTruthy();
  });

  it('renders error banner with retry', () => {
    const { overviewLoad } = freezeLoads();
    useShellStore.setState({ fixtureMode: true, health: fixtureDaemonHealth('/tmp/x.sock') });
    useOverviewStore.setState({ error: 'RPC timeout', loading: false, summary: null });
    render(<OverviewSurface />);
    expect(screen.getByRole('alert')).toBeTruthy();
    expect(screen.getByText('RPC timeout')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
    expect(overviewLoad).toHaveBeenCalled();
  });

  it('renders offline notice when bridge is unavailable', () => {
    freezeLoads();
    render(<OverviewSurface />);
    expect(
      screen.getByText(/Start or reconnect the local daemon to populate health, activity, and provider data./)
    ).toBeTruthy();
  });

  it('reconnect refreshes health and both lane loads', async () => {
    const refreshHealth = vi.fn(async () => {});
    const { overviewLoad, insightsLoad } = freezeLoads();
    useShellStore.setState({
      fixtureMode: true,
      health: fixtureDaemonHealth('/tmp/x.sock'),
      refreshHealth
    });
    render(<OverviewSurface />);
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: 'Reconnect' }));
    });
    expect(refreshHealth).toHaveBeenCalled();
    expect(overviewLoad.mock.calls.length).toBeGreaterThanOrEqual(2);
    expect(insightsLoad.mock.calls.length).toBeGreaterThanOrEqual(2);
  });

  it('overview store load uses bridge usageSummary when live', async () => {
    const usageSummary = vi.fn(async (): Promise<UsageSummary> => ({
      todayTokens: 1,
      todayCostUsd: 0.01,
      sevenDay: [1, 2],
      recentEvents: []
    }));
    const usageInsights = vi.fn(async () => ({
      weekly: [],
      providerMix: [],
      modelMix: [],
      cacheHitRatePct: 42
    }));
    const bridge = { usageSummary, usageInsights } as unknown as LinuxShellBridge;
    useShellStore.setState({ bridge, fixtureMode: false, health: { ok: true } });
    await act(async () => {
      await useOverviewStore.getState().load();
    });
    expect(usageSummary).toHaveBeenCalled();
    expect(useOverviewStore.getState().summary?.todayTokens).toBe(1);
    expect(useOverviewStore.getState().cacheHitRatePct).toBe(42);
  });
});