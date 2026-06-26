import type { CardProps } from "../cardTypes";
import { Stat, formatCompact } from "./primitives";

export function RequestsCard({ data }: CardProps) {
  const { totals } = data.rollup;
  const avg = totals.requests > 0 ? totals.tokens / totals.requests : 0;
  return (
    <Stat
      value={formatCompact(totals.requests)}
      label="Requests"
      sub={`~${formatCompact(avg)} tokens each`}
    />
  );
}
