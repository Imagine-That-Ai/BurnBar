import type { CardProps } from "../cardTypes";
import { formatPct } from "./primitives";

export function CacheHitCard({ window: w }: CardProps) {
  const pct = Math.min(100, Math.max(0, w.cacheHitRate * 100));
  return (
    <div className="flex h-full items-center gap-token-4">
      <div
        className="relative grid size-20 shrink-0 place-items-center rounded-full"
        style={{
          background: `conic-gradient(var(--accent) ${pct}%, var(--color-mercury-wash) 0)`,
        }}
        aria-hidden
      >
        <div className="grid size-[3.4rem] place-items-center rounded-full bg-glass-bg">
          <span className="font-display text-base text-content-bright tabular-nums">
            {formatPct(w.cacheHitRate)}
          </span>
        </div>
      </div>
      <div className="min-w-0">
        <span className="eyebrow">Cache hit</span>
        <p className="mt-1 text-sm text-content-mute">
          Prompt cache reuse across the {w.rangeLabel.toLowerCase()} window.
        </p>
      </div>
    </div>
  );
}
