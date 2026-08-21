import { DataTable } from '../../components/DataTable.js';
import type { UsageSummary } from '../../tauriBridge.js';

export function RecentActivityList({
  summary,
  fixtureMode,
  live,
  limit
}: {
  summary: UsageSummary | null;
  fixtureMode: boolean;
  live: boolean;
  limit?: number;
}) {
  if (!summary) return null;

  const events = typeof limit === 'number' ? summary.recentEvents.slice(0, Math.max(0, limit)) : summary.recentEvents;
  const rows = events.map((e) => ({
    id: e.id,
    title: e.title,
    detail: e.detail
  }));

  if (rows.length === 0) {
    return (
      <div className="overview-activity-empty" role="status">
        <p>No usage recorded yet.</p>
        <p className="muted">
          Connect providers on the{' '}
          <a className="overview-link" href="#/providers">
            Providers &amp; models
          </a>{' '}
          route to start ingesting sessions.
        </p>
      </div>
    );
  }

  const sourceLabel = fixtureMode
    ? 'fixture transcript'
    : live
      ? 'live daemon usage summary'
      : 'fixture transcript';

  return (
    <section className="overview-activity" aria-labelledby="overview-activity-heading">
      <h2 id="overview-activity-heading" className="overview-section-title">
        Recent activity
      </h2>
      <DataTable rows={rows} sourceLabel={sourceLabel} />
    </section>
  );
}