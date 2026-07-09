import { useMemo, useState } from 'react';
import { Banner } from '../components/Banner.js';
import { CommunityConsentPanel } from './CommunityConsentPanel.js';
import { CommunityLeaderboardCards } from './CommunityLeaderboardCards.js';
import { LOCAL_PARTICIPATION_PAUSED_COPY, buildCommunityView } from './communityModel.js';
import {
  defaultCommunityConsent,
  readCommunityConsent,
  writeCommunityConsent,
  type CommunityConsentState,
} from './consentStore.js';
import type { CommunityTimeWindow } from './types.js';
import { TIME_WINDOWS } from './types.js';
import './community.css';

export function CommunitySurface() {
  const [consent, setConsent] = useState<CommunityConsentState>(() => readCommunityConsent());
  const [window, setWindow] = useState<CommunityTimeWindow>('30d');
  const [statusMessage, setStatusMessage] = useState('');

  const view = useMemo(() => buildCommunityView(consent, window), [consent, window]);

  const persistConsent = (next: CommunityConsentState) => {
    setConsent(next);
    writeCommunityConsent(next);
  };

  return (
    <div className="community-observatory">
      <header className="community-hero glass-card">
        <p className="eyebrow">Community</p>
        <h2>Anonymous rankings & consent-first sharing</h2>
        {view.showInvite ? (
          <Banner tone="ok">
            Share anonymized usage to see where you stand — every tier is opt-in and unset stays dark.
          </Banner>
        ) : null}
        {view.isPreviewData ? (
          <Banner tone="info">{view.statusMessage}</Banner>
        ) : null}
        <div className="community-hero-metrics">
          <div>
            <span className="community-kpi">{view.hero.tokens.toLocaleString()}</span>
            <span className="community-muted">tokens</span>
          </div>
          <div>
            <span className="community-kpi">${view.hero.costUSD.toFixed(2)}</span>
            <span className="community-muted">estimated cost</span>
          </div>
          <div>
            <span className="community-kpi">{view.hero.trendDeltaPct >= 0 ? '+' : ''}{view.hero.trendDeltaPct}%</span>
            <span className="community-muted">trend delta</span>
          </div>
        </div>
        <p className="community-muted">{view.hero.modelMixSummary}</p>
        {view.isPreviewData ? (
          <p className="community-muted">Preview — not live usage or rankings.</p>
        ) : null}
        <p className="community-muted">{view.cityConfidenceCopy}</p>
      </header>

      <section className="community-panel glass-card">
        <h3>Time filter</h3>
        <div className="community-window-row">
          {TIME_WINDOWS.map((w) => (
            <button
              key={w.id}
              type="button"
              className={`glass-interactive ${window === w.id ? 'is-selected' : ''}`}
              onClick={() => setWindow(w.id)}
            >
              {w.label}
            </button>
          ))}
        </div>
      </section>

      <CommunityLeaderboardCards cards={view.leaderboards} />

      <section className="community-panel glass-card">
        <h3>Percentile strip</h3>
        <p>
          p50 {view.percentiles.p50.toLocaleString()} · p75 {view.percentiles.p75.toLocaleString()} · p90{' '}
          {view.percentiles.p90.toLocaleString()} · p99 {view.percentiles.p99.toLocaleString()}
        </p>
      </section>

      <section className="community-panel glass-card">
        <h3>Peer comparison chart (anonymized cohort)</h3>
        <p className="community-muted">
          {view.peerCohortTokens.length === 0
            ? view.isPreviewData
              ? 'Preview only — cohort chart stays empty until live boards sync.'
              : 'Cohort chart unlocks once a leaderboard tier clears the anonymity threshold.'
            : view.peerCohortTokens.map((v) => v.toLocaleString()).join(' · ')}
      </section>

      <section className="community-panel glass-card">
        <h3>Purpose breakdown</h3>
        <ul className="community-purpose-list">
          {view.purposeBreakdown.length === 0 ? (
            <li className="community-muted">Purpose mix appears after you opt into community sharing.</li>
          ) : (
            view.purposeBreakdown.map((slice) => (
              <li key={slice.category}>
                <span>{slice.category}</span>
                <span>{Math.round(slice.share * 100)}%</span>
              </li>
            ))
          )}
        </ul>
      </section>

      <CommunityConsentPanel
        consent={consent}
        onChange={persistConsent}
        statusMessage={view.consentPreview}
        exportStatusMessage={view.lookingGlassExport.message}
        onRevoke={() => {
          const declined = defaultCommunityConsent();
          declined.l1Analytics = 'declined';
          declined.l2Rankings = 'declined';
          declined.l3LookingGlass = 'declined';
          declined.locationConsent = 'declined';
          declined.l2Tiers = { world: 'declined', country: 'declined', region: 'declined', city: 'declined' };
          persistConsent(declined);
          setStatusMessage(LOCAL_PARTICIPATION_PAUSED_COPY);
        }}
      />
      {statusMessage ? <p className="community-muted">{statusMessage}</p> : null}
    </div>
  );
}
