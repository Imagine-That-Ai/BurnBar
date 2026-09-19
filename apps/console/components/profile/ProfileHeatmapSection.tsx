"use client";

/**
 * Clickable heatmap section for the mineable /profile explorer.
 *
 * Wraps the existing `ContributionHeatmap` (hover-card math and grid idiom
 * untouched) with the explorer contract: every day cell pins the inspector
 * (`onPinDay`), provider-only filters recolor through `dailyProviderTokens`,
 * and the Day/Week/Cumulative mode switch stays local.
 */

import * as React from "react";

import {
  ContributionHeatmap,
  type HeatmapMode,
} from "@/components/profile/ContributionHeatmap";
import { addDays, formatDayLabel } from "@/lib/profile/activityStats";
import type { DailyPoint } from "@/lib/usage";
import { cn } from "@/lib/utils";

const HEATMAP_MODES: { key: HeatmapMode; label: string }[] = [
  { key: "daily", label: "Daily" },
  { key: "weekly", label: "Weekly" },
  { key: "cumulative", label: "Cumulative" },
];

export function ProfileHeatmapSection({
  points,
  today,
  dailyProviderTokens,
  pinnedDay,
  onPinDay,
}: {
  points: readonly DailyPoint[];
  today: string;
  dailyProviderTokens?: Record<string, Record<string, number>>;
  pinnedDay: string | null;
  onPinDay: (day: string | null) => void;
}) {
  const [mode, setMode] = React.useState<HeatmapMode>("daily");

  // Click delegation: the SVG rects carry aria-labels starting with the
  // deterministic day label ("Aug 14, 2026 — …" / "Week of Aug 9, 2026 — …").
  // A click pins the matching day in the inspector; clicking it again unpins.
  // Keyboard users get the same drill-in via focusable active-day cells
  // (ContributionHeatmap `onSelectDay`) — Enter/Space pins the exact day.
  const pinDay = React.useCallback(
    (day: string) => {
      onPinDay(pinnedDay === day ? null : day);
    },
    [onPinDay, pinnedDay],
  );
  const onClick = React.useCallback(
    (e: React.MouseEvent<HTMLElement>) => {
      const target = e.target as Element | null;
      const rect = target?.closest?.("rect[aria-label]");
      if (!rect) return;
      const label = rect.getAttribute("aria-label") ?? "";
      const day = dayKeyFromLabel(label, points, today);
      if (!day) return;
      pinDay(day);
    },
    [pinDay, points, today],
  );

  return (
    <section aria-label="Token activity">
      <div className="mb-token-4 flex items-center justify-between gap-token-4">
        <h2 className="eyebrow">Token activity</h2>
        <div
          role="group"
          aria-label="Heatmap mode"
          className="flex items-center gap-token-1 rounded-pill border border-glass-line p-0.5"
        >
          {HEATMAP_MODES.map((m) => (
            <button
              key={m.key}
              type="button"
              aria-pressed={mode === m.key}
              onClick={() => setMode(m.key)}
              className={cn(
                "rounded-pill px-token-3 py-1 text-xs transition-colors duration-150",
                mode === m.key
                  ? "text-content-bright"
                  : "text-content-dim hover:text-content-mute",
              )}
              style={mode === m.key ? { background: "var(--accent-wash)" } : undefined}
            >
              {m.label}
            </button>
          ))}
        </div>
      </div>
      {/* Click delegation over the SVG grid: rects carry deterministic
          day aria-labels (see dayKeyFromLabel). Active-day cells are also
          keyboard-focusable via ContributionHeatmap's onSelectDay. */}
      <div onClick={onClick} title="Click a day to inspect it">
        <ContributionHeatmap
          points={points}
          mode={mode}
          today={today}
          dailyProviderTokens={dailyProviderTokens}
          onSelectDay={pinDay}
        />
      </div>
      {pinnedDay && (
        <p className="mt-token-2 text-xs text-content-mute">
          Inspecting {formatDayLabel(pinnedDay)}.{" "}
          <button
            type="button"
            onClick={() => onPinDay(null)}
            className="underline-offset-2 hover:text-content-bright hover:underline"
          >
            Unpin
          </button>
        </p>
      )}
    </section>
  );
}

/**
 * Resolve a heatmap aria-label back to a day key. Daily/cumulative labels
 * name the day ("Aug 14, 2026 — 100 tokens"); weekly labels name the column
 * ("Week of Aug 9, 2026 — 300 tokens") and resolve to the hottest active day
 * in that week, falling back to the week start.
 */
export function dayKeyFromLabel(
  label: string,
  points: readonly DailyPoint[],
  today: string,
): string | null {
  const monthIndex: Record<string, number> = {
    Jan: 1, Feb: 2, Mar: 3, Apr: 4, May: 5, Jun: 6,
    Jul: 7, Aug: 8, Sep: 9, Oct: 10, Nov: 11, Dec: 12,
  };
  const parseDay = (text: string): string | null => {
    const m = /([A-Z][a-z]{2}) (\d{1,2}), (\d{4})/.exec(text);
    if (!m) return null;
    const month = monthIndex[m[1] ?? ""];
    if (!month) return null;
    const day = String(Number(m[2])).padStart(2, "0");
    return `${m[3]}-${String(month).padStart(2, "0")}-${day}`;
  };
  const weekly = /^Week of /.test(label);
  const key = parseDay(label);
  if (!key) return null;
  if (!weekly) return key;
  // Hottest active day in [weekStart, weekStart + 6d] ∩ (…, today].
  const byDay = new Map(points.map((p) => [p.day, p.tokens]));
  let best: string | null = null;
  let bestTokens = 0;
  for (let i = 0; i < 7; i++) {
    const day = addDays(key, i);
    if (day > today) break;
    const tokens = byDay.get(day) ?? 0;
    if (tokens > bestTokens) {
      bestTokens = tokens;
      best = day;
    }
  }
  return best ?? key;
}
