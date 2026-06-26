import type { CardProps } from "../cardTypes";
import { EmptyHint, ProportionBar, formatUsd } from "./primitives";

export function ModelsCard({ data }: CardProps) {
  const models = data.rollup.modelSummaries;
  if (models.length === 0) return <EmptyHint label="Models" />;
  const max = Math.max(...models.map((m) => m.cost), 0.0001);
  return (
    <div className="flex h-full flex-col">
      <span className="eyebrow">Models</span>
      <ul className="mt-2 min-h-0 flex-1 space-y-2 overflow-y-auto pr-1">
        {models.map((m) => (
          <li key={`${m.provider}/${m.model}`}>
            <div className="flex items-baseline justify-between gap-2">
              <span className="truncate text-sm text-content-base" title={m.model}>
                {m.model}
              </span>
              <span className="shrink-0 font-mono text-xs text-content-mute tabular-nums">
                {formatUsd(m.cost)}
              </span>
            </div>
            <div className="mt-1">
              <ProportionBar value={m.cost / max} />
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}
