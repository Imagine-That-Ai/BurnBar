import type { CardProps } from "../cardTypes";
import { ProviderMark } from "./ProviderMark";
import { EmptyHint, ProportionBar, formatUsd } from "./primitives";

export function ProviderListCard({ data }: CardProps) {
  const providers = data.rollup.providerSummaries;
  if (providers.length === 0) return <EmptyHint label="Providers" />;
  const max = Math.max(...providers.map((p) => p.totalCost), 0.0001);
  return (
    <div className="flex h-full flex-col">
      <span className="eyebrow">Providers</span>
      <ul className="mt-2 min-h-0 flex-1 space-y-2 overflow-y-auto pr-1">
        {providers.map((p) => (
          <li key={p.providerID ?? p.provider} className="flex items-center gap-token-3">
            <ProviderMark id={p.provider} label={p.provider} />
            <div className="min-w-0 flex-1">
              <div className="flex items-baseline justify-between gap-2">
                <span className="truncate text-sm capitalize text-content-base">{p.provider}</span>
                <span className="shrink-0 font-mono text-xs text-content-mute tabular-nums">
                  {formatUsd(p.totalCost)}
                </span>
              </div>
              <div className="mt-1">
                <ProportionBar value={p.totalCost / max} />
              </div>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}
