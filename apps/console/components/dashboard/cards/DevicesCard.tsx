import type { CardProps } from "../cardTypes";
import { EmptyHint, ProportionBar, formatCompact } from "./primitives";

export function DevicesCard({ data }: CardProps) {
  const devices = data.rollup.deviceSummaries;
  if (devices.length === 0) return <EmptyHint label="Devices" />;
  const max = Math.max(...devices.map((d) => d.tokens), 1);
  return (
    <div className="flex h-full flex-col">
      <span className="eyebrow">Devices</span>
      <ul className="mt-2 min-h-0 flex-1 space-y-2 overflow-y-auto pr-1">
        {devices.map((d) => (
          <li key={d.deviceId}>
            <div className="flex items-baseline justify-between gap-2">
              <span className="truncate font-mono text-xs text-content-base" title={d.deviceId}>
                {d.deviceId.slice(0, 12)}
              </span>
              <span className="shrink-0 font-mono text-xs text-content-mute tabular-nums">
                {formatCompact(d.tokens)}
              </span>
            </div>
            <div className="mt-1">
              <ProportionBar value={d.tokens / max} />
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}
