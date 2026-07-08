// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureUsageInsights } from '../../daemonFixture.js';
import type { UsageInsights } from '../../tauriBridge.js';
import { useInsightsStore } from '../../state/insightsStore.js';
import { useShellStore } from '../../state/shellStore.js';
import {
  mixPercentTotal,
  normalizeValues,
  trendAriaSummary
} from './insightsChartMath.js';
import { InsightsSurface } from './InsightsSurface.js';
import { TrendChart } from './TrendChart.js';


function noopLoad(): Promise<void> {
  return Promise.resolve();
}
function resetStores(): void {
  localStorage.clear();
  useShellStore.setState({
    bridge: null,
    bridgeReady: true,
    fixtureMode: false,
    health: null,
    healthBusy: false,
    healthError: null
  });
  useInsightsStore.setState({ data: null, loading: false, error: null });
}

describe('insightsChartMath', () => {
  it('normalizes min/max spread to 0 and 1', () => {
    expect(normalizeValues([10, 20, 30])).toEqual([0, 0.5, 1]);
  });

  it('handles degenerate single-point series at midline', () => {
    expect(normalizeValues([42])).toEqual([0.5]);
  });

  it('handles flat series at 0.5', () => {
    expect(normalizeValues([5, 5, 5])).toEqual([0.5, 0.5, 0.5]);
  });

  it('sums mix percentages for fixture data', () => {
    const fx = fixtureUsageInsights();
    expect(mixPercentTotal(fx.providerMix)).toBe(100);
    expect(mixPercentTotal(fx.modelMix)).toBe(100);
  });

  it('builds trend aria summary with week count', () => {
    const weekly = fixtureUsageInsights().weekly;
    const label = trendAriaSummary(weekly);
    expect(label).toMatch(/5 weeks/i);
    expect(label.length).toBeGreaterThan(20);
  });
});

describe('InsightsSurface', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('renders populated fixture insights with chart aria-labels and hidden tables', () => {
    useShellStore.setState({ fixtureMode: true });
    render(<InsightsSurface />);
    expect(screen.getByText(/fixture transcript/i)).toBeTruthy();
    const imgs = screen.getAllByRole('img');
    expect(imgs.length).toBeGreaterThanOrEqual(3);
    for (const img of imgs) {
      expect(img.getAttribute('aria-label')?.length).toBeGreaterThan(10);
    }
    const hiddenTables = document.querySelectorAll('table.visually-hidden');
    expect(hiddenTables.length).toBeGreaterThanOrEqual(3);
  });

  it('shows loading skeleton with fixed chart region', () => {
    useInsightsStore.setState({ loading: true, data: null, error: null, load: noopLoad });
    const { container } = render(<InsightsSurface />);
    expect(container.querySelector('.insights-skeleton-chart')).toBeTruthy();
    expect(screen.queryByRole('img')).toBeNull();
  });

  it('shows empty copy when usage has no tokens', () => {
    const empty: UsageInsights = {
      weekly: [{ label: 'W1', tokens: 0, costUsd: 0 }],
      providerMix: [],
      modelMix: [],
      cacheHitRatePct: 0
    };
    useShellStore.setState({ fixtureMode: true });
    useInsightsStore.setState({ data: empty, loading: false, error: null, load: noopLoad });
    render(<InsightsSurface />);
    expect(screen.getByText(/Not enough usage yet/i)).toBeTruthy();
  });

  it('shows error banner with retry', () => {
    const loadSpy = vi.fn(noopLoad);
    useShellStore.setState({ bridge: null, fixtureMode: false });
    useInsightsStore.setState({
      data: null,
      loading: false,
      error: 'Daemon unreachable',
      load: loadSpy
    });
    render(<InsightsSurface />);
    expect(screen.getByRole('alert')).toBeTruthy();
    expect(screen.getByText('Daemon unreachable')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    expect(loadSpy).toHaveBeenCalled();
  });

  it('shows offline notice without bridge', () => {
    useShellStore.setState({ bridge: null, fixtureMode: false });
    useInsightsStore.setState({ data: null, loading: false, error: null });
    render(<InsightsSurface />);
    expect(screen.getByRole('status')).toBeTruthy();
    expect(screen.getByText(/packaged shell/i)).toBeTruthy();
  });
});

describe('TrendChart', () => {
  afterEach(cleanup);

  it('exposes role=img and data table for single week', () => {
    render(
      <TrendChart weekly={[{ label: 'W1', tokens: 1000, costUsd: 1.2 }]} />
    );
    const img = screen.getByRole('img');
    expect(img.getAttribute('aria-label')).toMatch(/1 weeks/i);
    const table = document.querySelector('table.visually-hidden');
    expect(table).toBeTruthy();
    expect(within(table as HTMLElement).getByText('1000')).toBeTruthy();
  });
});