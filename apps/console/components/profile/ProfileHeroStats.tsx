"use client";

/**
 * Lifetime stat row for the explorer — a divided bar on sm+, individual
 * tiles on mobile. Totals follow the active window slice (All = lifetime).
 */

import { cn } from "@/lib/utils";

function HeaderStat({
  value,
  label,
  sub,
  className,
}: {
  value: React.ReactNode;
  label: string;
  sub?: React.ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-col items-center gap-1 px-token-4 py-token-4 text-center",
        className,
      )}
    >
      <span className="font-display text-2xl leading-none text-content-bright tabular-nums">
        {value}
      </span>
      <span className="eyebrow">{label}</span>
      {sub != null && <span className="text-xs text-content-dim">{sub}</span>}
    </div>
  );
}

const TILE = "rounded-lg border border-glass-line sm:rounded-none sm:border-0";

export function ProfileHeroStats({
  pending,
  lifetime,
  lifetimeLabel,
  peak,
  peakLabel,
  activeDays,
  avgPerDay,
  currentStreak,
  longestStreak,
}: {
  pending: boolean;
  lifetime: string;
  lifetimeLabel: string;
  peak: string;
  peakLabel?: string;
  activeDays: string;
  avgPerDay?: string;
  currentStreak: string;
  longestStreak: string;
}) {
  return (
    <section
      aria-label="Usage statistics"
      className="grid grid-cols-2 gap-2 sm:grid-cols-5 sm:gap-0 sm:divide-x sm:divide-glass-line sm:rounded-lg sm:border sm:border-glass-line"
    >
      <HeaderStat value={lifetime} label={lifetimeLabel} className={TILE} />
      <HeaderStat
        value={peak}
        label="Peak tokens"
        sub={!pending ? peakLabel : undefined}
        className={TILE}
      />
      <HeaderStat
        value={activeDays}
        label="Active days"
        sub={!pending ? avgPerDay : undefined}
        className={TILE}
      />
      <HeaderStat value={currentStreak} label="Current streak" className={TILE} />
      <HeaderStat
        value={longestStreak}
        label="Longest streak"
        className={`col-span-2 sm:col-span-1 ${TILE}`}
      />
    </section>
  );
}
