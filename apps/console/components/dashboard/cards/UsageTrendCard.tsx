import type { CardProps } from "../cardTypes";
import { Sparkline, formatCompact } from "./primitives";

export function UsageTrendCard({ data }: CardProps) {
  const { dailyPoints, totals } = data.rollup;
  const first = dailyPoints[0]?.day;
  const last = dailyPoints[dailyPoints.length - 1]?.day;
  return (
    <div className="flex h-full flex-col">
      <div className="flex items-baseline justify-between">
        <span className="eyebrow">Tokens / day</span>
        <span className="font-display text-lg text-content-bright tabular-nums">
          {formatCompact(totals.tokens)}
        </span>
      </div>
      <div className="mt-3 min-h-0 flex-1">
        <Sparkline values={dailyPoints.map((p) => p.tokens)} />
      </div>
      <div className="mt-2 flex justify-between font-mono text-[0.62rem] uppercase tracking-[0.12em] text-content-dim">
        <span>{first ?? "—"}</span>
        <span>{last ?? "—"}</span>
      </div>
    </div>
  );
}
