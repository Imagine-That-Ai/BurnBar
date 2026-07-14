import { useEffect, useMemo } from 'react';
import { Banner } from '../components/Banner.js';
import { ProviderListPanel } from '../components/ProviderListPanel.js';
import {
  DashboardLayoutShell,
  type DashboardSurfaceState
} from '../dashboard/DashboardLayoutShell.js';
import { DASHBOARD_LAYOUT_META } from '../dashboard/dashboardLayout.js';
import { useDashboardLayoutStore } from '../state/dashboardLayoutStore.js';
import { useDaemonStatusCopy, useShellStore } from '../state/shellStore.js';
import { useOverviewStore } from '../state/overviewStore.js';
import { useInsightsStore } from '../state/insightsStore.js';
import { AtelierHero } from './overview/AtelierHero.js';
import {
  buildSpendCurveModel,
  providerRowsFromInsights
} from './overview/overviewAtelierData.js';
import './overview/overview.css';

export function resolveOverviewShellState(input: {
  offlineNoBridge: boolean;
  daemonOffline: boolean;
  error: string | null;
  busy: boolean;
  hasSummary: boolean;
}): DashboardSurfaceState {
  if (input.offlineNoBridge || input.daemonOffline) return 'offline';
  if (input.error && !input.hasSummary) return 'error';
  if (input.busy && !input.hasSummary) return 'loading';
  if (!input.hasSummary && !input.busy) return 'empty';
  return 'populated';
}

export function OverviewSurface() {
  const refreshHealth = useShellStore((s) => s.refreshHealth);
  const healthBusy = useShellStore((s) => s.healthBusy);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const health = useShellStore((s) => s.health);
  const status = useDaemonStatusCopy();
  const layout = useDashboardLayoutStore((s) => s.layout);

  const summary = useOverviewStore((s) => s.summary);
  const cacheHitRatePct = useOverviewStore((s) => s.cacheHitRatePct);
  const loading = useOverviewStore((s) => s.loading);
  const error = useOverviewStore((s) => s.error);
  const loadSummary = useOverviewStore((s) => s.load);

  const insights = useInsightsStore((s) => s.data);
  const insightsLoading = useInsightsStore((s) => s.loading);
  const loadInsights = useInsightsStore((s) => s.load);

  useEffect(() => {
    void loadSummary();
    void loadInsights();
  }, [loadSummary, loadInsights, fixtureMode, bridge]);

  const reconnect = () => {
    void refreshHealth();
    void loadSummary();
    void loadInsights();
  };

  const offlineNoBridge = !fixtureMode && !bridge;
  const daemonOffline = !fixtureMode && !!bridge && health != null && health.ok === false;
  const busy = loading || insightsLoading;
  const shellState = resolveOverviewShellState({
    offlineNoBridge,
    daemonOffline,
    error,
    busy,
    hasSummary: !!summary
  });

  const shellState = resolveOverviewShellState({
    offlineNoBridge,
    daemonOffline,
    error,
    busy,
    hasSummary: !!summary
  });

  const providerRows = useMemo(() => {
    const mix = insights?.providerMix ?? [];
    const total = fixtureMode ? 680.94 : summary?.todayCostUsd ?? 0;
    return providerRowsFromInsights(mix, total, fixtureMode);
  }, [insights, summary, fixtureMode]);

  const curveModel = useMemo(
    () => buildSpendCurveModel(insights, summary, fixtureMode),
    [insights, summary, fixtureMode]
  );

  const overviewBody = (
    <div className={`overview-atelier-layout overview-atelier-layout--${layout}`}>
      <aside className="overview-atelier-rail">
        <ProviderListPanel rows={providerRows} title="Providers" logoSize={40} skeleton={busy && !summary} />
      </aside>
      <div className="overview-atelier-main">
        <AtelierHero
          summary={error ? null : summary}
          cacheHitRatePct={cacheHitRatePct}
          curveModel={curveModel}
          fixtureMode={fixtureMode}
          loading={busy && !summary}
        />
      </div>
    </div>
  );

  if (offlineNoBridge) {
    return (
      <DashboardLayoutShell
        layout={layout}
        state="offline"
        offlineSummary={`${status.label}. Start or reconnect the local daemon to populate health, activity, and provider data.`}
        showSwitcher
      />
    );
  }

  const showBody = shellState === 'populated' || shellState === 'loading';
  const frameState: DashboardSurfaceState = shellState === 'error' ? 'empty' : shellState;

  return (
    <div
      className={`overview-atelier overview-atelier--${layout}`}
      data-overview-shell-state={shellState}
    >
      {error && shellState === 'error' ? (
        <Banner tone="degraded" role="alert">
          <p>{error}</p>
          <button type="button" className="primary overview-retry" onClick={() => void loadSummary()}>
            Retry
          </button>
        </Banner>
      ) : null}

      {daemonOffline ? (
        <Banner tone="degraded" role="status">
          <p>Daemon health check failed. Start openburnbar-daemon or reconnect.</p>
          <button type="button" className="primary overview-retry" onClick={reconnect}>
            Reconnect
          </button>
        </Banner>
      ) : null}

      <DashboardLayoutShell
        layout={layout}
        state={frameState === 'loading' ? 'loading' : frameState}
        offlineSummary="Daemon health check failed. Start openburnbar-daemon or reconnect."
        showSwitcher
      >
        {showBody ? overviewBody : null}
      </DashboardLayoutShell>

      <p className="overview-provenance muted" role="status">
        Layout: {DASHBOARD_LAYOUT_META[layout].displayName}
        {DASHBOARD_LAYOUT_META[layout].isKernelForward ? ' · kernel-forward' : ''}
        {' · '}
        shell: {shellState}
        {' · '}
        content: atelier-shared
        {' · '}
        Data source: {fixtureMode ? 'fixture transcript' : bridge ? 'live daemon' : 'unavailable'} ·{' '}
        <button type="button" className="overview-reconnect-link" disabled={healthBusy} onClick={reconnect}>
          {healthBusy ? 'Reconnecting…' : 'Reconnect'}
        </button>
      </p>
    </div>
  );
}
