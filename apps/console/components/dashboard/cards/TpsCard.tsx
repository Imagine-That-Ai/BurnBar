import type { CardProps } from "../cardTypes";
import { Stat, formatCompact } from "./primitives";

export function TpsCard({ window: w }: CardProps) {
  // No aggregate TPS exists server-side yet (it is per-message, mobile-only),
  // so this surfaces the most-recent observed reading, or an em-dash when none
  // is known. See useDashboardUsage / README → Follow-ups.
  const tps = w.tokensPerSecond;
  return (
    <Stat
      value={
        tps == null ? (
          <span className="text-content-dim">—</span>
        ) : (
          <span>
            {formatCompact(tps)}
            <span className="ml-1 text-lg text-content-mute">t/s</span>
          </span>
        )
      }
      label="Throughput"
      sub="most recent observed"
    />
  );
}
