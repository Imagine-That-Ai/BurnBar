import { StatCardGrid, StatCardGridSkeleton, type StatCardItem } from '../../components/StatCardGrid.js';
import type { UsageSummary } from '../../tauriBridge.js';
import { resolveCacheHitRateTier } from './cacheHitTier.js';

const tokenFmt = new Intl.NumberFormat('en-US');
const costFmt = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2
});

const TINT_COST = 'var(--color-brass-bright)';
const TINT_TOKENS = 'var(--color-brass-core)';
const TINT_SESSIONS = 'var(--color-tier-server-readable)';

function providerIdsFromSummary(summary: UsageSummary): string[] {
  const ids = new Set<string>();
  for (const e of summary.recentEvents) {
    const provider = e.title.split('/')[0]?.trim();
    if (provider) ids.add(provider.toLowerCase());
  }
  return [...ids];
}

function windowTokenTotal(summary: UsageSummary): number {
  return summary.sevenDay.reduce((a, b) => a + b, 0);
}

function windowSessionCount(summary: UsageSummary): number {
  const ids = new Set(summary.recentEvents.map((e) => e.id));
  return ids.size;
}

export function UsageTiles({
  summary,
  cacheHitRatePct,
  lastRefreshedAt,
  skeleton
}: {
  summary: UsageSummary | null;
  cacheHitRatePct: number | null;
  lastRefreshedAt: Date | null;
  skeleton?: boolean;
}) {
  if (skeleton) {
    return (
      <StatCardGridSkeleton
        count={4}
        className="overview-usage-tiles"
        ariaLabel="Usage summary loading"
      />
    );
  }
  if (!summary) return null;

  const sessions = windowSessionCount(summary);
  const providers = providerIdsFromSummary(summary);
  const activeProviderCount = providers.length;
  const windowTokens = windowTokenTotal(summary);
  const cacheTier = resolveCacheHitRateTier(cacheHitRatePct);

  const refreshLabel = lastRefreshedAt
    ? lastRefreshedAt.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
    : 'never';

  const costFooter = `${sessions} session${sessions === 1 ? '' : 's'} tracked in the current window. Last refresh ${refreshLabel}.`;
  const tokensFooter = `${activeProviderCount} active provider${activeProviderCount === 1 ? '' : 's'} in this window.`;
  const sessionsFooter = `${windowTokens.toLocaleString('en-US')} tokens across the 7-day window.`;
  const cacheFooter =
    cacheTier.id === 'noSignal' && cacheHitRatePct == null
      ? 'No prompt cache reads recorded yet for this window.'
      : cacheTier.caption;

  const items: StatCardItem[] = [
    {
      id: 'total-cost',
      label: 'Total cost',
      value: costFmt.format(summary.todayCostUsd),
      valueGradient: true,
      tint: TINT_COST,
      footer: <p className="stat-card-footer">{costFooter}</p>
    },
    {
      id: 'tokens',
      label: 'Tokens',
      value: tokenFmt.format(summary.todayTokens),
      tint: TINT_TOKENS,
      footer: <p className="stat-card-footer">{tokensFooter}</p>
    },
    {
      id: 'sessions',
      label: 'Sessions',
      value: tokenFmt.format(sessions),
      tint: TINT_SESSIONS,
      footer: <p className="stat-card-footer">{sessionsFooter}</p>
    },
    {
      id: 'cache-hit',
      label: 'Cache hit',
      value: (
        <span className="overview-cache-hit-value" style={{ color: cacheTier.color }}>
          {cacheTier.formattedValue}
        </span>
      ),
      tint: cacheTier.color,
      footer: (
        <p className="stat-card-footer overview-cache-hit-footer">
          <span className="overview-cache-hit-dot" style={{ background: cacheTier.color }} aria-hidden />
          <span style={{ color: cacheTier.color }}>{cacheFooter}</span>
        </p>
      )
    }
  ];

  return <StatCardGrid items={items} className="overview-usage-tiles" aria-label="Usage summary" />;
}