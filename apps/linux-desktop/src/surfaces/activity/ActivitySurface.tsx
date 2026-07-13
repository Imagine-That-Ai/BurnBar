import { useState, type ReactNode } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useActivityStore } from '../../state/activityStore.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { SearchBox } from './SearchBox.js';
import { SessionRow, type ActivityMetricMode } from './SessionRow.js';
import { groupSessionsByDay } from './sessionGroups.js';
import './activity.css';

function ActivitySkeleton() {
  return (
    <ul className="activity-list activity-list--skeleton" aria-busy="true" aria-label="Loading sessions">
      {Array.from({ length: 5 }, (_, i) => (
        <li key={i} className="activity-skeleton-row" aria-hidden="true" />
      ))}
    </ul>
  );
}

export function ActivitySurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const bridge = useShellStore((s) => s.bridge);
  const status = useDaemonStatusCopy();
  const sessions = useActivityStore((s) => s.sessions);
  const loading = useActivityStore((s) => s.loading);
  const error = useActivityStore((s) => s.error);
  const query = useActivityStore((s) => s.query);
  const visibleCount = useActivityStore((s) => s.visibleCount);
  const load = useActivityStore((s) => s.load);
  const loadMore = useActivityStore((s) => s.loadMore);

  const [metricMode, setMetricMode] = useState<ActivityMetricMode>('cost');

  const offline = !fixtureMode && !bridge;
  const provenance = fixtureMode
    ? 'fixture transcript'
    : query.trim()
      ? 'live daemon indexed transcript search'
      : 'live daemon session index';

  useLaneLoad(load);

  const visible = sessions.slice(0, visibleCount);
  const dayGroups = groupSessionsByDay(visible);
  const hasMore = sessions.length > visibleCount;

  let body: ReactNode;
  if (offline) {
    body = (
      <OfflineNotice
        status={status}
        summary="Activity & logs needs the packaged shell and local daemon before session rows can load."
        fixtureMode={fixtureMode}
      />
    );
  } else if (error) {
    body = (
      <>
        <Banner tone="degraded">
          <p>{error}</p>
          <div className="actions">
            <button type="button" className="primary" onClick={() => void load()}>
              Retry
            </button>
          </div>
        </Banner>
        <SearchBox />
      </>
    );
  } else if (loading && sessions.length === 0) {
    body = (
      <>
        <SearchBox />
        <ActivitySkeleton />
      </>
    );
  } else if (sessions.length === 0 && query.trim()) {
    body = (
      <>
        <SearchBox />
        <p className="activity-empty">No sessions match &lsquo;{query.trim()}&rsquo;.</p>
      </>
    );
  } else if (sessions.length === 0) {
    body = (
      <>
        <SearchBox />
        <p className="activity-empty">No sessions ingested — check provider log paths in Settings.</p>
      </>
    );
  } else {
    body = (
      <>
        <div className="activity-toolbar">
          <SearchBox />
          <div className="activity-metric-toggle" role="group" aria-label="Session list metric">
            <button
              type="button"
              className={metricMode === 'cost' ? 'is-active' : undefined}
              aria-pressed={metricMode === 'cost'}
              onClick={() => setMetricMode('cost')}
            >
              Cost
            </button>
            <button
              type="button"
              className={metricMode === 'tokens' ? 'is-active' : undefined}
              aria-pressed={metricMode === 'tokens'}
              onClick={() => setMetricMode('tokens')}
            >
              Tokens
            </button>
          </div>
        </div>
        <div className="activity-groups">
          {dayGroups.map((group) => (
            <section key={group.key} className="activity-day-group" aria-labelledby={`activity-day-${group.key}`}>
              <header className="activity-day-header">
                <h2 id={`activity-day-${group.key}`} className="activity-day-title">
                  {group.title}
                </h2>
                <span className="activity-day-count muted">
                  {group.sessions.length} session{group.sessions.length === 1 ? '' : 's'}
                </span>
              </header>
              <ul className="activity-list">
                {group.sessions.map((s) => (
                  <SessionRow key={s.id} session={s} metricMode={metricMode} />
                ))}
              </ul>
            </section>
          ))}
        </div>
        {hasMore ? (
          <div className="actions activity-load-more">
            <button type="button" onClick={() => loadMore()}>
              Load more
            </button>
          </div>
        ) : null}
      </>
    );
  }

  return (
    <div className="activity-surface">
      <p className="muted activity-provenance">Source: {provenance}</p>
      <p className="sr-only" aria-live="polite">
        {loading ? 'Loading sessions' : `${sessions.length} session${sessions.length === 1 ? '' : 's'} shown`}
      </p>
      {body}
    </div>
  );
}
