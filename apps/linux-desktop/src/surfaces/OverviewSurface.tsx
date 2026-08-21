import { useEffect, useMemo, useRef } from 'react';
import { Banner } from '../components/Banner.js';
import {
  DashboardLayoutShell,
  type DashboardSurfaceState
} from '../dashboard/DashboardLayoutShell.js';
import { DASHBOARD_LAYOUT_META } from '../dashboard/dashboardLayout.js';
import { useDashboardLayoutStore } from '../state/dashboardLayoutStore.js';
import { useActivityStore } from '../state/activityStore.js';
import { useDaemonStatusCopy, useShellStore } from '../state/shellStore.js';
import { useInsightsStore } from '../state/insightsStore.js';
import { useLaneLoad } from '../state/useLaneLoad.js';
import { useMissionsStore } from '../state/missionsStore.js';
import { useOverviewStore } from '../state/overviewStore.js';
import { OverviewLayoutBody } from './overview/OverviewLayoutBody.js';
import { buildSpendCurveModel, providerRowsFromInsights } from './overview/overviewAtelierData.js';
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
  const lastRefreshedAt = useOverviewStore((s) => s.lastRefreshedAt);
  const loading = useOverviewStore((s) => s.loading);
  const error = useOverviewStore((s) => s.error);
  const loadSummary = useOverviewStore((s) => s.load);

  const insights = useInsightsStore((s) => s.data);
  const insightsLoading = useInsightsStore((s) => s.loading);
  const loadInsights = useInsightsStore((s) => s.load);

  const sessions = useActivityStore((s) => s.sessions);
  const loadActivity = useActivityStore((s) => s.load);
  const missions = useMissionsStore((s) => s.data);
  const loadMissions = useMissionsStore((s) => s.load);
  const dataRevision = useShellStore((s) => s.dataRevision);

  useLaneLoad(loadSummary);
  useLaneLoad(loadInsights);

  // setFixtureMode() changes neither bridgeReady nor dataRevision, so useLaneLoad
  // cannot see a fixture/live switch on its own. Re-fire the summary and insight
  // lanes on the transition itself — mount is already covered by useLaneLoad, so
  // the ref keeps the first render from issuing a duplicate (and, in the packaged
  // shell, un-deferred) load.
  const loadedFixtureModeRef = useRef(fixtureMode);
  useEffect(() => {
    if (loadedFixtureModeRef.current === fixtureMode) return;
    loadedFixtureModeRef.current = fixtureMode;
    void loadSummary();
    void loadInsights();
  }, [fixtureMode, loadSummary, loadInsights]);

  useEffect(() => {
    if (layout !== 'stream' && layout !== 'atlas') return;
    void loadActivity();
    void loadMissions();
  }, [layout, loadActivity, loadMissions, dataRevision, fixtureMode]);

  const reconnect = () => {
    void refreshHealth();
    void loadSummary();
    void loadInsights();
    void loadActivity();
    void loadMissions();
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

  const providerRows = useMemo(() => {
    const mix = insights?.providerMix ?? [];
    const total = summary?.todayCostUsd ?? 0;
    return providerRowsFromInsights(mix, total, fixtureMode);
  }, [insights, summary, fixtureMode]);

  const curveModel = useMemo(
    () => buildSpendCurveModel(insights, summary, fixtureMode),
    [insights, summary, fixtureMode]
  );

  const overviewBody = (
    <OverviewLayoutBody
      layout={layout}
      summary={error ? null : summary}
      cacheHitRatePct={cacheHitRatePct}
      lastRefreshedAt={lastRefreshedAt}
      curveModel={curveModel}
      providerRows={providerRows}
      providerMix={insights?.providerMix ?? []}
      sessions={sessions}
      missions={missions}
      fixtureMode={fixtureMode}
      live={!!bridge}
      loading={busy && !summary}
    />
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
      data-overview-layout={layout}
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
        content: {layout}
        {' · '}
        Data source: {fixtureMode ? 'fixture transcript' : bridge ? 'live daemon' : 'unavailable'} ·{' '}
        <button type="button" className="overview-reconnect-link" disabled={healthBusy} onClick={reconnect}>
          {healthBusy ? 'Reconnecting…' : 'Reconnect'}
        </button>
      </p>
    </div>
  );
}
