import { useEffect } from 'react';
import type { UsageSummary } from '../../tauriBridge.js';
import { useOverviewStore } from '../../state/overviewStore.js';

const costFmt = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2
});

const POLL_MS = 30_000;

export function CostTicker({ summary }: { summary: UsageSummary | null }) {
  const load = useOverviewStore((s) => s.load);

  useEffect(() => {
    const tick = () => {
      if (document.hidden) return;
      void load();
    };

    const id = setInterval(tick, POLL_MS);

    const onVisibility = () => {
      if (!document.hidden) void load();
    };
    document.addEventListener('visibilitychange', onVisibility);

    return () => {
      clearInterval(id);
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, [load]);

  if (!summary) return null;

  return (
    <p className="overview-cost-ticker" role="status" aria-live="polite">
      <span className="overview-cost-ticker-label">Today</span>
      <span className="overview-cost-ticker-value tabular-nums">{costFmt.format(summary.todayCostUsd)}</span>
    </p>
  );
}