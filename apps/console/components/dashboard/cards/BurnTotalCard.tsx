import type { CardProps } from "../cardTypes";
import { Sparkline, Stat, formatCompact, formatUsd } from "./primitives";

export function BurnTotalCard({ window: w }: CardProps) {
  return (
    <div className="relative flex h-full flex-col">
      <Stat
        value={formatUsd(w.totalCostUsd)}
        label={`Burn · ${w.rangeLabel}`}
        sub={`${formatCompact(w.totalTokens)} tokens · ${w.sessionCount} sessions`}
      />
      <div className="pointer-events-none mt-3 h-10 opacity-80">
        <Sparkline samples={w.costCurve} />
      </div>
    </div>
  );
}
