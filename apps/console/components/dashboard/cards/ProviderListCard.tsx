import type { CardProps } from "../cardTypes";
import { ProviderMark } from "./ProviderMark";
import { ProportionBar, formatUsd } from "./primitives";

export function ProviderListCard({ window: w }: CardProps) {
  const max = Math.max(...w.providers.map((p) => p.costUsd), 1);
  return (
    <div className="flex h-full flex-col">
      <span className="eyebrow">Providers</span>
      <ul className="mt-2 min-h-0 flex-1 space-y-2 overflow-y-auto pr-1">
        {w.providers.map((p) => (
          <li key={p.id} className="flex items-center gap-token-3">
            <ProviderMark id={p.id} label={p.label} />
            <div className="min-w-0 flex-1">
              <div className="flex items-baseline justify-between gap-2">
                <span className="truncate text-sm text-content-base">{p.label}</span>
                <span className="shrink-0 font-mono text-xs text-content-mute tabular-nums">
                  {formatUsd(p.costUsd)}
                </span>
              </div>
              <div className="mt-1">
                <ProportionBar value={p.costUsd / max} />
              </div>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}
