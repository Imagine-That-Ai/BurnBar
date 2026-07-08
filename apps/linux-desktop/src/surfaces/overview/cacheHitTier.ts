/**
 * Window-wide cache hit rate bands (macOS oracle: CacheHitRateView.swift).
 * Shared with insights surfaces — import from here; do not duplicate.
 */

export type CacheHitRateTierId = 'strong' | 'healthy' | 'warming' | 'cold' | 'noSignal';

export type CacheHitRateTier = {
  id: CacheHitRateTierId;
  /** Design-token color for value text / tint */
  color: string;
  caption: string;
  formattedValue: string;
};

const pctFmt = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });

export function resolveCacheHitRateTier(cacheHitRatePct: number | null): CacheHitRateTier {
  if (cacheHitRatePct == null || !Number.isFinite(cacheHitRatePct)) {
    return {
      id: 'noSignal',
      color: 'var(--color-tier-zero-access)',
      caption: 'No cache data',
      formattedValue: '—'
    };
  }

  const display = `${pctFmt.format(cacheHitRatePct)}%`;

  if (cacheHitRatePct >= 60) {
    return {
      id: 'strong',
      color: 'var(--color-tier-end-to-end)',
      caption: 'Strong reuse',
      formattedValue: display
    };
  }
  if (cacheHitRatePct >= 30) {
    return {
      id: 'healthy',
      color: 'color-mix(in srgb, var(--color-tier-end-to-end) 55%, var(--color-mercury-bright) 45%)',
      caption: 'Healthy reuse',
      formattedValue: display
    };
  }
  if (cacheHitRatePct >= 5) {
    return {
      id: 'warming',
      color: 'var(--color-tier-server-readable)',
      caption: 'Warming up',
      formattedValue: display
    };
  }
  if (cacheHitRatePct > 0) {
    return {
      id: 'cold',
      color: 'var(--color-seal-crimson)',
      caption: 'Low reuse',
      formattedValue: display
    };
  }
  return {
    id: 'noSignal',
    color: 'var(--color-tier-zero-access)',
    caption: 'No cache data',
    formattedValue: display
  };
}

export function formatOverviewRefreshTime(at: Date | null): string {
  if (!at) return 'never';
  return at.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}