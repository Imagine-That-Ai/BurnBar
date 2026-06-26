import type { CardProps } from "../cardTypes";
import { Stat, formatCompact } from "./primitives";

export function SessionsCard({ window: w }: CardProps) {
  const avg = w.sessionCount > 0 ? w.totalTokens / w.sessionCount : 0;
  return (
    <Stat
      value={w.sessionCount}
      label="Sessions"
      sub={`~${formatCompact(avg)} tokens each · ${w.rangeLabel.toLowerCase()}`}
    />
  );
}
