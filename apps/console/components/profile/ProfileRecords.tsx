"use client";

/**
 * Clickable all-time records band for the explorer. Every tile pins the
 * inspector or sets the matching facet: biggest day / first burn pin the day,
 * busiest provider / loyal model set the facet chip, streak tiles jump to the
 * rhythm section.
 */

import { formatDayLabel } from "@/lib/profile/activityStats";
import { formatCompact } from "@/components/dashboard/cards/primitives";
import { modelDisplayName } from "@/lib/providerBrand";
import { cn } from "@/lib/utils";

function RecordTile({
  value,
  label,
  sub,
  title,
  onClick,
}: {
  value: React.ReactNode;
  label: string;
  sub?: React.ReactNode;
  title?: string;
  onClick?: () => void;
}) {
  const inner = (
    <span className="flex min-w-0 flex-col items-center gap-1 px-token-3 py-token-4 text-center">
      <span
        className="w-full truncate font-display text-lg leading-tight text-content-bright tabular-nums"
        title={title}
      >
        {value}
      </span>
      <span className="eyebrow">{label}</span>
      {sub != null && <span className="text-xs text-content-dim">{sub}</span>}
    </span>
  );
  if (!onClick) return <div className={tileClass}>{inner}</div>;
  return (
    <button
      type="button"
      onClick={onClick}
      title={title ?? `Inspect ${label}`}
      className={cn(tileClass, "transition-colors hover:bg-mercury-wash")}
    >
      {inner}
    </button>
  );
}

const tileClass =
  "rounded-lg border border-glass-line lg:rounded-none lg:border-0";

export interface RecordsData {
  busiestProvider: { id: string; label: string; share: string; title: string } | null;
  loyalModel: { id: string; label: string; share: string; title: string } | null;
  biggestDay: { day: string; tokens: number } | null;
  longestStreak: number;
  activeDays: number;
  firstBurn: string | null;
  spanDays: number;
  burnRate: string | null;
  pending: boolean;
}

export function ProfileRecords({
  records,
  onPinDay,
  onToggleProvider,
  onToggleModel,
  onJumpToRhythm,
}: {
  records: RecordsData;
  onPinDay: (day: string) => void;
  onToggleProvider: (id: string) => void;
  onToggleModel: (id: string) => void;
  /** Longest-streak drill-in: scrolls to the burn-rhythm strip. */
  onJumpToRhythm: () => void;
}) {
  const v = (node: React.ReactNode) => (records.pending ? "—" : node);
  return (
    <section aria-label="All-time records">
      <div className="mb-token-4 flex items-baseline justify-between gap-token-4">
        <h2 className="eyebrow">Records</h2>
        <span className="text-xs text-content-dim">the all-time hall of fame — tiles dig in</span>
      </div>
      <div className="grid grid-cols-2 gap-2 lg:grid-cols-6 lg:gap-0 lg:divide-x lg:divide-glass-line lg:rounded-lg lg:border lg:border-glass-line">
        <RecordTile
          value={v(records.busiestProvider?.label ?? "—")}
          label="Busiest provider"
          sub={records.pending ? undefined : records.busiestProvider?.share}
          title={records.busiestProvider?.title}
          onClick={
            records.busiestProvider
              ? () => onToggleProvider(records.busiestProvider!.id)
              : undefined
          }
        />
        <RecordTile
          value={v(
            records.loyalModel ? modelDisplayName(records.loyalModel.label) : "—",
          )}
          label="Loyal model"
          sub={records.pending ? undefined : records.loyalModel?.share}
          title={records.loyalModel?.title}
          onClick={
            records.loyalModel ? () => onToggleModel(records.loyalModel!.id) : undefined
          }
        />
        <RecordTile
          value={v(
            records.biggestDay ? formatCompact(records.biggestDay.tokens) : "0",
          )}
          label="Biggest day"
          sub={records.pending ? undefined : records.biggestDay ? formatDayLabel(records.biggestDay.day) : undefined}
          onClick={records.biggestDay ? () => onPinDay(records.biggestDay!.day) : undefined}
        />
        <RecordTile
          value={v(`${records.longestStreak}d`)}
          label="Longest streak"
          sub={records.pending ? undefined : `${records.activeDays} active days`}
          title="Jump to the burn-rhythm strip"
          onClick={records.pending ? undefined : onJumpToRhythm}
        />
        <RecordTile
          value={v(records.firstBurn ? formatDayLabel(records.firstBurn) : "—")}
          label="First burn"
          sub={records.pending ? undefined : records.spanDays > 0 ? `${records.spanDays}d of history` : undefined}
          onClick={records.firstBurn ? () => onPinDay(records.firstBurn!) : undefined}
        />
        <RecordTile
          value={v(records.burnRate ?? "—")}
          label="Burn rate"
          sub={records.pending ? undefined : "of days active"}
        />
      </div>
    </section>
  );
}
