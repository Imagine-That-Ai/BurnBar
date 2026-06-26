import type { CardProps } from "../cardTypes";
import { Stat, formatCompact } from "./primitives";

export function TokensCard({ window: w }: CardProps) {
  return (
    <Stat
      value={formatCompact(w.totalTokens)}
      label="Tokens"
      sub={`across ${w.sessionCount} sessions · ${w.rangeLabel.toLowerCase()}`}
    />
  );
}
