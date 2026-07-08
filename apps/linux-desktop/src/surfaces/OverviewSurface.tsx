import { useEffect, useMemo } from 'react';
import { Banner } from '../components/Banner.js';
import { OfflineNotice } from '../components/OfflineNotice.js';
import { ProviderListPanel } from '../components/ProviderListPanel.js';
import { useDaemonStatusCopy, useShellStore } from '../state/shellStore.js';
import { useOverviewStore } from '../state/overviewStore.js';
import { useInsightsStore } from '../state/insightsStore.js';
import { AtelierHero } from './overview/AtelierHero.js';
import {
  buildSpendCurveModel,
  providerRowsFromInsights
} from './overview/overviewAtelierData.js';
import './overview/overview.css';

export function OverviewSurface() {
  const refreshHealth = useShellStore((s) => s.refreshHealth);
  const healthBusy = useShellStore((s) => s.healthBusy);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const status = useDaemonStatusCopy();

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
  const busy = loading || insightsLoading;

  const providerRows = useMemo(() => {
    const mix = insights?.providerMix ?? [];
    const total = fixtureMode ? 680.94 : summary?.todayCostUsd ?? 0;
    return providerRowsFromInsights(mix, total, fixtureMode);
  }, [insights, summary, fixtureMode]);

  const curveModel = useMemo(
    () => buildSpendCurveModel(insights, summary, fixtureMode),
    [insights, summary, fixtureMode]
  );

  if (offlineNoBridge) {
    return (
      <OfflineNotice
        status={status}
        summary="Start or reconnect the local daemon to populate health, activity, and provider data."
        fixtureMode={fixtureMode}
      />
    );
  }

  return (
    <div className="overview-atelier">
      {error ? (
        <Banner tone="degraded" role="alert">
          <p>{error}</p>
          <button type="button" className="primary overview-retry" onClick={() => void loadSummary()}>
            Retry
          </button>
        </Banner>
      ) : null}

      <div className="overview-atelier-layout">
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

      <p className="overview-provenance muted" role="status">
        Data source: {fixtureMode ? 'fixture transcript' : bridge ? 'live daemon' : 'unavailable'} ·{' '}
        <button type="button" className="overview-reconnect-link" disabled={healthBusy} onClick={reconnect}>
          {healthBusy ? 'Reconnecting…' : 'Reconnect'}
        </button>
      </p>
    </div>
  );
}