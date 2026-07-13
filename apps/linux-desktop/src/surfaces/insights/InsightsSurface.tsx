import { useEffect } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useInsightsStore } from '../../state/insightsStore.js';
import { useAccountStore } from '../../state/accountStore.js';
import { hasInsightsUsage } from './insightsChartMath.js';
import { InsightsEditorialBrief } from './InsightsEditorialBrief.js';
import { buildInsightsBrief } from './insightsBrief.js';
import { InsightsWorkspace } from './InsightsWorkspace.js';
import { accountScopeForInsights } from './insightsWorkspacePersistence.js';
import { useChatStore } from '../../state/chatStore.js';
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
  const accountStatus = useAccountStore((s) => s.data);
  const accountLoading = useAccountStore((s) => s.loading);
  const loadAccount = useAccountStore((s) => s.load);
  const status = useDaemonStatusCopy();
  const data = useInsightsStore((s) => s.data);
  const loading = useInsightsStore((s) => s.loading);
  const error = useInsightsStore((s) => s.error);
  const load = useInsightsStore((s) => s.load);
  const openFollowUp = (question: string) => {
    useShellStore.getState().setRoute('chat');
    useChatStore.getState().startNewChat();
    void useChatStore.getState().sendToThread({ backend: 'hermes', text: question });
  };

  useEffect(() => {
    // Load the daemon-owned identity while Insights is open so persisted
    // canvas state is namespaced per account even when Settings was never
    // visited in this session. Failure keeps the local-only fallback.
    if (!fixtureMode && bridge && !accountStatus && !accountLoading) void loadAccount();
  }, [accountLoading, accountStatus, bridge, fixtureMode, loadAccount]);

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

  const sourceLabel = fixtureMode ? 'fixture transcript' : 'live daemon usage insights';
  const accountScope = accountScopeForInsights(accountStatus);
  const brief = buildInsightsBrief(data);
  return (
    <div className="insights-observatory">
      <InsightsEditorialBrief brief={brief} />
      <InsightsWorkspace
        data={data}
        sourceLabel={sourceLabel}
        onRefresh={() => void load()}
        onFollowUp={openFollowUp}
        accountScope={accountScope}
      />
    </div>
  );
}
