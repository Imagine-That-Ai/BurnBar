import type { CardProps } from "../cardTypes";
import { Stat, formatCompact } from "./primitives";

export function TokensCard({ data }: CardProps) {
  const { totals } = data.rollup;
  return (
    <Stat
      value={formatCompact(totals.tokens)}
      label="Tokens"
      sub={`${formatCompact(totals.requests)} requests`}
    />
  );
}
