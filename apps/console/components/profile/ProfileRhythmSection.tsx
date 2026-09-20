"use client";

/**
 * Burn rhythm — mean tokens by weekday over the active view, Monday first.
 * Denominators are calendar occurrences, not active days, so a weekday you
 * always skip reads as the near-zero it is. Hover titles carry totals.
 */

import type { WeekdayRhythm } from "@/lib/profile/activityStats";
import { formatCompact } from "@/components/dashboard/cards/primitives";

export function ProfileRhythmSection({
  rhythm,
  rhythmMax,
  pending,
}: {
  rhythm: WeekdayRhythm[];
  rhythmMax: number;
  pending: boolean;
}) {
  return (
    <section aria-label="Burn rhythm">
      <div className="mb-token-1 flex items-baseline justify-between gap-token-4">
        <h2 className="eyebrow">Burn rhythm</h2>
        <span className="text-xs text-content-dim">mean tokens by weekday, in view</span>
      </div>
      {rhythm.length === 0 ? (
        <div className="h-36 rounded-lg border border-glass-line" aria-hidden />
      ) : (
        <div
          className="flex h-36 items-end gap-2 sm:gap-3"
          role="img"
          aria-label={`Mean tokens by weekday: ${rhythm.map((r) => `${r.label} ${formatCompact(Math.round(r.avg))}`).join(", ")}`}
        >
          {rhythm.map((r) => {
            const pct = rhythmMax > 0 ? Math.max(2, (r.avg / rhythmMax) * 100) : 2;
            const isMax = rhythmMax > 0 && r.avg >= rhythmMax;
            return (
              <div
                key={r.label}
                className="flex h-full min-w-0 flex-1 flex-col items-center justify-end gap-1"
              >
                <span className="text-[0.62rem] text-content-dim tabular-nums">
                  {pending ? "—" : formatCompact(Math.round(r.avg))}
                </span>
                <div
                  className="w-full max-w-10 rounded-t-[4px] transition-[height] duration-500 ease-out motion-reduce:transition-none"
                  title={`${r.label}: ${formatCompact(Math.round(r.avg))} mean tokens over ${r.days} ${r.days === 1 ? "day" : "days"} — ${formatCompact(r.tokens)} total`}
                  style={{
                    height: `${pct}%`,
                    background: "var(--accent)",
                    opacity: pending ? 0.25 : isMax ? 1 : 0.55,
                  }}
                />
                <span className="text-[0.62rem] text-content-mute">{r.label}</span>
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}
