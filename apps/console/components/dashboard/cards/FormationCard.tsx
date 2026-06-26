import type { CardProps } from "../cardTypes";
import { ProviderMark } from "./ProviderMark";

// The formation field has no numeric source by design — it IS the live
// particle swarm on the backdrop. This card is a legend: the marks currently
// cycling through the swarm, seeded from the provider rollup.
export function FormationCard({ window: w }: CardProps) {
  const marks = w.providers.slice(0, 8);
  return (
    <div className="flex h-full flex-col">
      <span className="eyebrow">Formation field</span>
      <div className="mt-3 flex min-h-0 flex-1 flex-wrap content-start gap-2">
        {marks.map((p) => (
          <span
            key={p.id}
            className="flex items-center gap-1.5 rounded-pill py-1 pl-1 pr-2.5"
            style={{ border: "1px solid var(--color-glass-line)" }}
          >
            <ProviderMark id={p.id} label={p.label} size={18} />
            <span className="text-xs text-content-mute">{p.label}</span>
          </span>
        ))}
      </div>
      <p className="mt-2 text-xs text-content-dim">
        Providers resolve, hold, and dissolve across the backdrop swarm.
      </p>
    </div>
  );
}
