import { useState, type ReactNode } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useActivityStore } from '../../state/activityStore.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { SearchBox } from './SearchBox.js';
import { SessionRow, type ActivityMetricMode } from './SessionRow.js';
import { groupSessionsByDay } from './sessionGroups.js';
import {
  buildDaemonActivityHistoryExport,
  buildActivityExportDocument,
  downloadActivityExport,
  sanitizeActivityExportFilename,
  serializeActivityExport,
  type ActivityExportFormat
} from './activityExport.js';
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
  const [exportFormat, setExportFormat] = useState<ActivityExportFormat>('json');
  const [exportStatus, setExportStatus] = useState<string | null>(null);
  const [historyExportLoading, setHistoryExportLoading] = useState(false);
  const [historyExportStatus, setHistoryExportStatus] = useState<string | null>(null);

  const offline = !fixtureMode && !bridge;
  const provenance = fixtureMode ? 'fixture transcript' : 'live daemon session index';

  useLaneLoad(load);

  const visible = sessions.slice(0, visibleCount);
  const dayGroups = groupSessionsByDay(visible);
  const hasMore = sessions.length > visibleCount;
  const exportDisabled = sessions.length === 0;
  // Keep the action available in fixture/older shells so the UI can surface a
  // typed unavailable reason instead of silently implying that history is
  // empty. Only an in-flight export disables the control.
  const historyExportDisabled = historyExportLoading;

  const exportActivity = () => {
    if (exportDisabled) return;
    try {
      const document = buildActivityExportDocument(
        sessions,
        fixtureMode ? 'fixture transcript' : 'live daemon session index'
      );
      const filename = sanitizeActivityExportFilename('activity-export', exportFormat);
      const content = serializeActivityExport(document, exportFormat);
      downloadActivityExport({
        filename,
        content,
        mimeType: exportFormat === 'markdown' ? 'text/markdown' : 'application/json'
      });
      setExportStatus(`Exported ${filename} (${document.loadedCount} loaded rows)`);
    } catch (error) {
      setExportStatus(error instanceof Error ? error.message : 'Activity export failed.');
    }
  };

  const exportActivityHistory = async () => {
    setHistoryExportStatus(null);
    if (historyExportDisabled || fixtureMode || !bridge || typeof bridge.sessionReplay !== 'function') {
      setHistoryExportStatus(
        'Full activity history export is unavailable until the live daemon and persisted session replay are connected.'
      );
      return;
    }
    setHistoryExportLoading(true);
    try {
      const result = await buildDaemonActivityHistoryExport(bridge);
      if (result.kind === 'unavailable') {
        setHistoryExportStatus(`Full history export unavailable: ${result.message}`);
        return;
      }
      const filename = sanitizeActivityExportFilename('activity-history', exportFormat);
      const content = serializeActivityExport(result.document, exportFormat);
      downloadActivityExport({
        filename,
        content,
        mimeType: exportFormat === 'markdown' ? 'text/markdown' : 'application/json'
      });
      setHistoryExportStatus(
        `Exported ${filename} (${result.document.loadedCount} daemon sessions with persisted bodies)`
      );
    } catch (error) {
      setHistoryExportStatus(
        error instanceof Error ? error.message : 'Full activity history export failed.'
      );
    } finally {
      setHistoryExportLoading(false);
    }
  };

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
          <div className="activity-export-control" role="group" aria-label="Activity export">
            <span className="sr-only">Activity export format</span>
            <select
              value={exportFormat}
              onChange={(event) => setExportFormat(event.target.value as ActivityExportFormat)}
              aria-label="Activity export format"
              disabled={exportDisabled}
            >
              <option value="json">JSON</option>
              <option value="markdown">Markdown</option>
            </select>
            <button
              type="button"
              className="ghost activity-export-button"
              onClick={exportActivity}
              disabled={exportDisabled}
              title={exportDisabled ? 'Load activity rows to export' : `Export activity as ${exportFormat === 'json' ? 'JSON' : 'Markdown'}`}
              aria-label={`Export activity as ${exportFormat === 'json' ? 'JSON' : 'Markdown'}`}
            >
              <span aria-hidden="true">⇩</span>
            </button>
            {exportStatus ? (
              <span className="activity-export-status" role="status" aria-live="polite">
                {exportStatus}
              </span>
            ) : null}
            <button
              type="button"
              className="ghost activity-export-history-button"
              onClick={() => void exportActivityHistory()}
              disabled={historyExportDisabled}
              title={
                historyExportDisabled
                  ? 'Full history export requires a live daemon with persisted session replay'
                  : fixtureMode || !bridge?.sessionReplay
                    ? 'Full history export is unavailable in fixture or older shells'
                  : 'Export a bounded, daemon-authoritative history with persisted bodies'
              }
            >
              {historyExportLoading ? 'Preparing history...' : 'Export full history'}
            </button>
            {historyExportStatus ? (
              <span className="activity-export-status" role="status" aria-live="polite">
                {historyExportStatus}
              </span>
            ) : null}
          </div>
        </div>
        <p className="activity-export-scope">
          Loaded export includes {sessions.length} currently loaded row{sessions.length === 1 ? '' : 's'}; full history re-reads a bounded daemon snapshot and fails closed when any source or body is unavailable.
        </p>
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
