import type { CardProps } from "../cardTypes";
import { Sparkline, formatUsd } from "./primitives";

export function CostCurveCard({ window: w }: CardProps) {
  return (
    <div className="flex h-full flex-col">
      <div className="flex items-baseline justify-between">
        <span className="eyebrow">Cost curve</span>
        <span className="font-display text-lg text-content-bright tabular-nums">
          {formatUsd(w.totalCostUsd)}
        </span>
      </div>
      <div className="mt-3 min-h-0 flex-1">
        <Sparkline samples={w.costCurve} />
      </div>
      <div className="mt-2 flex justify-between font-mono text-[0.62rem] uppercase tracking-[0.12em] text-content-dim">
        <span>start</span>
        <span>{w.rangeLabel.toLowerCase()}</span>
      </div>
    </div>
  );
}
