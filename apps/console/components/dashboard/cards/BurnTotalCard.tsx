import type { CardProps } from "../cardTypes";
import { Sparkline, Stat, formatCompact, formatUsd } from "./primitives";

export function BurnTotalCard({ data }: CardProps) {
  const { totals, dailyPoints } = data.rollup;
  return (
    <div className="relative flex h-full flex-col">
      <Stat
        value={formatUsd(totals.costUsd)}
        label="Burn"
        sub={`${formatCompact(totals.tokens)} tokens · ${formatCompact(totals.requests)} requests`}
      />
      <div className="pointer-events-none mt-3 h-10 opacity-80">
        <Sparkline values={dailyPoints.map((p) => p.tokens)} />
      </div>
    </div>
  );
}
