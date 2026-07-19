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
import { InsightsWorkspace } from './InsightsWorkspace.js';
import { TrendChart } from './TrendChart.js';
import { buildInsightsBrief } from './insightsBrief.js';
import {
  insightsCitationPrompt,
  resolveInsightsEvidence,
  resolveQualitativeCapability,
  uniqueInsightsCitations
} from './insightsEvidence.js';
import {
  accountScopeForInsights,
  insightsWorkspaceStorageKey,
  readInsightsWorkspace,
  writeInsightsWorkspace
} from './insightsWorkspacePersistence.js';


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

describe('insights brief', () => {
  it('derives a bounded brief from normalized aggregates without adding provider claims', () => {
    const brief = buildInsightsBrief(fixtureUsageInsights());
    expect(brief.headline).toMatch(/trending/i);
    expect(brief.observations).toEqual(expect.arrayContaining([
      expect.stringMatching(/Primary provider by recorded share/),
      expect.stringMatching(/Cache hit rate/)
    ]));
    expect(brief.summary).toMatch(/recorded activity only/i);
    expect(brief.followUps.map((item) => item.href)).toEqual(['#/providers', '#/activity']);
  });
});

describe('insights evidence and workspace persistence', () => {
  beforeEach(() => localStorage.clear());

  it('accepts only the known usage authority and exposes qualitative analysis as unavailable', () => {
    const fixture = fixtureUsageInsights();
    const evidence = resolveInsightsEvidence(fixture, 'fixture transcript');
    expect(evidence).toMatchObject({
      sourceID: 'fixture.usage.insights',
      state: 'verified',
      sourceKind: 'fixture'
    });
    expect(resolveQualitativeCapability(fixture)).toMatchObject({ state: 'unavailable' });

    const malformed = { ...fixture, source: { id: 'forged.source' } } as unknown as UsageInsights;
    expect(resolveInsightsEvidence(malformed, 'live daemon usage insights')).toMatchObject({
      sourceID: 'unavailable',
      state: 'unavailable'
    });
    const mismatchedKind = {
      ...fixture,
      source: { id: 'daemon.usage.recent', kind: 'fixture', label: 'forged' }
    } as unknown as UsageInsights;
    expect(resolveInsightsEvidence(mismatchedKind, 'live daemon usage insights').state).toBe('unavailable');
  });

  it('keeps citation IDs opaque, bounded, and ordered for the evidence chip flow', () => {
    const citations = [
      { id: 'citation-1', label: 'Codex session' },
      { id: 'citation-1', label: 'duplicate label' },
      { id: 'citation-2', label: 'Provider mix' }
    ];
    expect(uniqueInsightsCitations(citations, 2)).toEqual([
      citations[0],
      citations[2]
    ]);
    expect(insightsCitationPrompt(citations[0])).toContain('citation citation-1');
    expect(insightsCitationPrompt(citations[0])).toContain('Codex session');
  });

  it('persists selection and density per account scope without storing the identity in the key', () => {
    const accountScope = accountScopeForInsights({
      identityLabel: 'alberto@example.test',
      installationDeviceID: 'linux-device-1'
    });
    writeInsightsWorkspace(accountScope, {
      version: 1,
      selectedWidgetID: 'provider-mix',
      layout: 'compact'
    });
    expect(readInsightsWorkspace(accountScope, ['usage-trend', 'provider-mix'])).toMatchObject({
      selectedWidgetID: 'provider-mix',
      layout: 'compact'
    });
    expect(insightsWorkspaceStorageKey(accountScope)).not.toContain('alberto@example.test');
    expect(readInsightsWorkspace('account:other', ['usage-trend', 'provider-mix']).selectedWidgetID).toBe('usage-trend');
  });
});

describe('InsightsSurface', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('renders populated fixture insights with chart aria-labels and hidden tables', () => {
    useShellStore.setState({ fixtureMode: true });
    render(<InsightsSurface />);
    expect(screen.getByText(/Provenance: fixture transcript/i)).toBeTruthy();
    expect(screen.getByRole('heading', { name: /Usage is trending/i })).toBeTruthy();
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

  it('supports evidence selection, audit disclosure, and chat follow-up handoff', () => {
    const refresh = vi.fn();
    const followUp = vi.fn();
    render(
      <InsightsWorkspace
        data={{
          ...fixtureUsageInsights(),
          source: { id: 'daemon.usage.recent', kind: 'daemon-method', label: 'live daemon usage insights' }
        }}
        sourceLabel="live daemon usage insights"
        onRefresh={refresh}
        onFollowUp={followUp}
      />
    );

    fireEvent.click(screen.getByRole('button', { name: /provider mix/i }));
    expect(screen.getAllByText(/live daemon usage insights/i).length).toBeGreaterThan(0);
    fireEvent.click(screen.getByRole('button', { name: /^audit$/i }));
    expect(screen.getByRole('dialog', { name: /insights audit/i })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /close/i }));

    const input = screen.getByRole('textbox', { name: /ask about this data/i });
    fireEvent.change(input, { target: { value: 'Compare provider mix with last week' } });
    fireEvent.click(screen.getByRole('button', { name: /open in chat/i }));
    expect(followUp).toHaveBeenCalledWith('Compare provider mix with last week');
    fireEvent.click(screen.getByRole('button', { name: /refresh insights/i }));
    expect(refresh).toHaveBeenCalledTimes(1);
  });

  it('renders daemon citations for qualitative findings and hands opaque evidence to chat', () => {
    const followUp = vi.fn();
    const data: UsageInsights = {
      ...fixtureUsageInsights(),
      source: { id: 'daemon.usage.insights', kind: 'daemon-method', label: 'daemon-authored qualitative insights' },
      qualitative: {
        state: 'available',
        reason: 'Bounded local-rules analysis.',
        method: 'daemon.usage.insights',
        sourceID: 'daemon.usage.ledger',
        analysis: {
          requestID: 'request-1',
          generatedAt: '2026-07-19T00:00:00Z',
          executiveSummary: 'Codex is the main spend driver.',
          modelDisplayName: 'Linux local rules',
          citations: [{ id: 'citation-1', label: 'Codex session' }],
          findings: [{
            id: 'finding-1',
            title: 'Codex is the main spend driver',
            whyItMatters: 'It accounts for the included spend.',
            recommendedAction: 'Compare lower-cost routes.',
            evidence: [{ id: 'citation-1', label: 'Codex session' }]
          }]
        }
      }
    };

    render(
      <InsightsWorkspace
        data={data}
        sourceLabel="daemon-authored qualitative insights"
        onRefresh={vi.fn()}
        onFollowUp={followUp}
      />
    );

    expect(screen.getByText('It accounts for the included spend.')).toBeTruthy();
    const citationButtons = screen.getAllByRole('button', { name: /Open citation: Codex session/i });
    expect(citationButtons.length).toBe(2);
    fireEvent.click(citationButtons[0]!);
    expect(followUp).toHaveBeenCalledWith(
      'Explain the Insights evidence "Codex session" (citation citation-1) from the current daemon response.'
    );
  });

  it('restores the selected widget and compact density for the same account scope', () => {
    const props = {
      data: fixtureUsageInsights(),
      sourceLabel: 'fixture transcript',
      onRefresh: vi.fn(),
      onFollowUp: vi.fn(),
      accountScope: 'account:linux-device-1'
    };
    const first = render(<InsightsWorkspace {...props} />);
    fireEvent.click(screen.getByRole('button', { name: /provider mix/i }));
    fireEvent.click(screen.getByRole('button', { name: /^compact$/i }));
    expect(document.querySelector('.insights-canvas-grid')?.getAttribute('data-layout')).toBe('compact');
    first.unmount();

    render(<InsightsWorkspace {...props} />);
    expect(screen.getByRole('button', { name: /provider mix/i }).getAttribute('aria-pressed')).toBe('true');
    expect(document.querySelector('.insights-canvas-grid')?.getAttribute('data-layout')).toBe('compact');
    expect(screen.getByTestId('insights-source-id').textContent).toContain('fixture.usage.insights');
    expect(screen.getByTestId('insights-qualitative-state').textContent).toMatch(/unavailable/i);
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
