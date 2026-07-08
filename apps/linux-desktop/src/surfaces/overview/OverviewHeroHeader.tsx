import { formatOverviewRefreshTime } from './cacheHitTier.js';

export function OverviewHeroHeader({
  subheadline,
  lastRefreshedAt,
  loading
}: {
  subheadline: string;
  lastRefreshedAt: Date | null;
  loading?: boolean;
}) {
  return (
    <header className="overview-hero-header">
      <div className="overview-hero-header-text">
        <h2 className="overview-hero-title">Usage window</h2>
        <p className="overview-hero-subheadline muted">{subheadline}</p>
      </div>
      <time
        className="overview-hero-refresh mono tabular-nums"
        dateTime={lastRefreshedAt?.toISOString()}
        aria-label={`Last refresh ${formatOverviewRefreshTime(lastRefreshedAt)}`}
      >
        {loading ? 'Refreshing…' : formatOverviewRefreshTime(lastRefreshedAt)}
      </time>
    </header>
  );
}