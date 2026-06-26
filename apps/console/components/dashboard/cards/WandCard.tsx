import type { CardProps } from "../cardTypes";
import { Stat, formatUsd } from "./primitives";

export function WandCard({ window: w }: CardProps) {
  const { fusion } = w;
  const baseline = Math.max(fusion.baselineCostUsd, fusion.fusionCostUsd, 0.0001);
  return (
    <div className="flex h-full flex-col">
      <Stat
        value={
          <span className="text-tier-end-to-end">{formatUsd(fusion.savedUsd)}</span>
        }
        label="The Wand · saved"
        sub={`${fusion.fusionRuns} fusion runs`}
      />
      <div className="mt-3 space-y-2">
        <Bar
          label="fusion"
          value={formatUsd(fusion.fusionCostUsd)}
          frac={fusion.fusionCostUsd / baseline}
          accent
        />
        <Bar
          label="baseline"
          value={formatUsd(fusion.baselineCostUsd)}
          frac={fusion.baselineCostUsd / baseline}
        />
      </div>
    </div>
  );
}

function Bar({
  label,
  value,
  frac,
  accent = false,
}: {
  label: string;
  value: string;
  frac: number;
  accent?: boolean;
}) {
  const pct = Math.min(100, Math.max(2, frac * 100));
  return (
    <div>
      <div className="flex justify-between font-mono text-[0.62rem] uppercase tracking-[0.12em] text-content-dim">
        <span>{label}</span>
        <span className="tabular-nums">{value}</span>
      </div>
      <div className="mt-1 h-2 w-full overflow-hidden rounded-pill bg-mercury-wash">
        <div
          className="h-full rounded-pill"
          style={{
            width: pct + "%",
            background: accent ? "var(--accent)" : "var(--color-mercury-deep)",
          }}
        />
      </div>
    </div>
  );
}
