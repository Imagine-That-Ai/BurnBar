"use client";

/**
 * Token trend — trailing-90-day sparkline over the active view, with honest
 * endpoint labels. Same Sparkline idiom as the dashboard cards.
 */

import { Sparkline, formatCompact } from "@/components/dashboard/cards/primitives";
import { formatDayLabel } from "@/lib/profile/activityStats";
import type { DailyPoint } from "@/lib/usage";

export function ProfileTrendSection({
  trend,
  pending,
}: {
  trend: DailyPoint[];
  pending: boolean;
}) {
  const total = trend.reduce((n, p) => n + p.tokens, 0);
  return (
    <section aria-label="Token trend">
      <h2 className="eyebrow mb-token-1">Tokens</h2>
      <p className="font-display text-2xl text-content-bright tabular-nums">
        {pending ? "—" : `${formatCompact(total)} tokens`}
        <span className="ml-2 text-sm font-normal text-content-dim">last 90 days of view</span>
      </p>
      <div className="mt-token-3 h-36">
        <Sparkline values={trend.map((p) => p.tokens)} className="h-full" />
      </div>
      <div className="mt-token-2 flex justify-between text-xs text-content-dim">
        <span>{trend[0] ? formatDayLabel(trend[0].day) : "—"}</span>
        <span>Today</span>
      </div>
    </section>
  );
}
