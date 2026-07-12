import type { DaemonStatusCopy } from '../daemonStatusCopy.js';

/**
 * Honest degraded state for daemon-backed routes (`.offline-notice[role="status"]`).
 * Routes never render mock data when the daemon is unreachable.
 */
export function OfflineNotice({
  status,
  summary,
  fixtureMode
}: {
  status: DaemonStatusCopy;
  summary: string;
  fixtureMode: boolean;
}) {
  return (
    <div className="offline-notice" role="status">
      <strong>{status.label}</strong>
      <p>{summary}</p>
      <p className="muted">{status.detail}</p>
      {fixtureMode ? <p className="muted">Fixture mode is enabled for host smoke tests.</p> : null}
    </div>
  );
}
