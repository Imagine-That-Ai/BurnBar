import type { CardProps } from "../cardTypes";
import { ProviderMark } from "./ProviderMark";
import { EmptyHint } from "./primitives";

// The formation field has no numeric source by design — it IS the live particle
// swarm on the backdrop. This card is a legend of the providers in this window,
// seeded from the real provider rollup.
export function FormationCard({ data }: CardProps) {
  const marks = data.rollup.providerSummaries.slice(0, 8);
  if (marks.length === 0) {
    return <EmptyHint label="Formation field" hint="Providers appear as you use them." />;
  }
  return (
    <div className="flex h-full flex-col">
      <span className="eyebrow">Formation field</span>
      <div className="mt-3 flex min-h-0 flex-1 flex-wrap content-start gap-2">
        {marks.map((p) => (
          <span
            key={p.providerID ?? p.provider}
            className="flex items-center gap-1.5 rounded-pill py-1 pl-1 pr-2.5"
            style={{ border: "1px solid var(--color-glass-line)" }}
          >
            <ProviderMark id={p.provider} label={p.provider} size={18} />
            <span className="text-xs capitalize text-content-mute">{p.provider}</span>
          </span>
        ))}
      </div>
      <p className="mt-2 text-xs text-content-dim">
        Providers resolve, hold, and dissolve across the backdrop swarm.
      </p>
    </div>
  );
}
