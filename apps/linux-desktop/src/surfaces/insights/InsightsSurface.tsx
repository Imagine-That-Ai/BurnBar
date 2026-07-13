import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useInsightsStore } from '../../state/insightsStore.js';
import { hasInsightsUsage, weekOverWeekTokenDeltaPct } from './insightsChartMath.js';
import { MixBar } from './MixBar.js';
import { StatCallout } from './StatCallout.js';
import { TrendChart } from './TrendChart.js';
import { InsightsEditorialBrief } from './InsightsEditorialBrief.js';
import { buildInsightsBrief } from './insightsBrief.js';
import './insights.css';

function InsightsSkeleton() {
  return (
    <div className="insights-observatory insights-observatory--loading" aria-busy="true">
      <div className="insights-grid">
        <div className="insights-panel insights-skeleton-chart" />
        <div className="insights-panel insights-skeleton-stats" />
        <div className="insights-panel insights-skeleton-mix" />
        <div className="insights-panel insights-skeleton-mix" />
      </div>
    </div>
  );
}

export function InsightsSurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const status = useDaemonStatusCopy();
  const data = useInsightsStore((s) => s.data);
  const loading = useInsightsStore((s) => s.loading);
  const error = useInsightsStore((s) => s.error);
  const load = useInsightsStore((s) => s.load);

  useLaneLoad(load);

  if (loading && !data) {
    return <InsightsSkeleton />;
  }

  if (error && !data) {
    return (
      <div className="insights-observatory">
        <Banner tone="degraded">
          <p>{error}</p>
          <button type="button" className="primary" onClick={() => void load()}>
            Retry
          </button>
        </Banner>
      </div>
    );
  }

  const offline = !fixtureMode && !bridge && !loading && !error;
  if (offline) {
    return (
      <OfflineNotice
        status={status}
        summary="Insights need the packaged shell and local daemon before usage trends can load."
        fixtureMode={fixtureMode}
      />
    );
  }

  if (!data || !hasInsightsUsage(data)) {
    return (
      <p className="insights-empty muted">
        Not enough usage yet — insights appear after your first sessions.
      </p>
    );
  }

  const wow = weekOverWeekTokenDeltaPct(data.weekly);
  const sourceLabel = fixtureMode ? 'fixture transcript' : 'live daemon usage insights';
  const brief = buildInsightsBrief(data);

  return (
    <div className="insights-observatory">
      <p className="data-source muted">Provenance: {sourceLabel}</p>
      <InsightsEditorialBrief brief={brief} />
      <div className="insights-grid">
        <div className="insights-panel insights-panel--chart">
          <TrendChart weekly={data.weekly} />
        </div>
        <div className="insights-panel insights-panel--stats">
          <StatCallout cacheHitRatePct={data.cacheHitRatePct} caption="Cache hit rate" />
          <StatCallout value={`${data.weekly.length}`} caption="Weeks tracked" deltaPct={wow} />
        </div>
        <div className="insights-panel">
          <MixBar
            title="Provider mix"
            entries={data.providerMix}
            ariaLabel={`Provider mix: ${data.providerMix.map((e) => `${e.label} ${e.pct}%`).join(', ')}`}
          />
        </div>
        <div className="insights-panel">
          <MixBar
            title="Model mix"
            entries={data.modelMix}
            ariaLabel={`Model mix: ${data.modelMix.map((e) => `${e.label} ${e.pct}%`).join(', ')}`}
          />
        </div>
      </div>
    </div>
  );
}
