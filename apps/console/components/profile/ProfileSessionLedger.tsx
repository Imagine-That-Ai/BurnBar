"use client";

/**
 * Session ledger for the explorer: time, harness, model, provider, tokens,
 * spend, duration. Sortable columns; clicking a row focuses the inspector on
 * that event's day. Paged from the event path (100/page, "load more").
 */

import * as React from "react";

import {
  formatCompact,
  formatUsd,
} from "@/components/dashboard/cards/primitives";
import { modelDisplayName, providerDisplayName } from "@/lib/providerBrand";
import type { ProfileUsageEvent } from "@/lib/profile/profileEvents";
import { cn } from "@/lib/utils";

type SortKey = "time" | "tokens" | "cost" | "duration";
type SortDir = "asc" | "desc";

function dayTime(iso: string | null): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  const day = iso.slice(0, 10);
  const hh = String(d.getUTCHours()).padStart(2, "0");
  const mm = String(d.getUTCMinutes()).padStart(2, "0");
  return `${day} ${hh}:${mm}`;
}

function fmtDuration(secs: number | null): string {
  if (secs == null) return "—";
  if (secs < 60) return `${secs}s`;
  const m = Math.floor(secs / 60);
  if (m < 60) return `${m}m ${secs % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

export function ProfileSessionLedger({
  events,
  loading,
  error,
  hasMore,
  capped,
  enabledHint,
  onLoadMore,
  onFocusEvent,
}: {
  events: ProfileUsageEvent[];
  loading: boolean;
  error: string | null;
  hasMore: boolean;
  capped: boolean;
  /** Shown when the event path is off (no bounded range / no facets). */
  enabledHint: string | null;
  onLoadMore: () => void;
  onFocusEvent: (e: ProfileUsageEvent) => void;
}) {
  const [sortKey, setSortKey] = React.useState<SortKey>("time");
  const [sortDir, setSortDir] = React.useState<SortDir>("desc");

  const sorted = React.useMemo(() => {
    const val = (e: ProfileUsageEvent): number => {
      switch (sortKey) {
        case "time":
          return e.startedAt ? Date.parse(e.startedAt) : 0;
        case "tokens":
          return e.totalTokens;
        case "cost":
          return e.costUsd;
        case "duration":
          return e.durationSeconds ?? -1;
      }
    };
    return [...events].sort((a, b) => {
      const d = val(a) - val(b);
      return sortDir === "asc" ? d : -d;
    });
  }, [events, sortKey, sortDir]);

  const toggleSort = (key: SortKey) => {
    if (key === sortKey) {
      setSortDir((d) => (d === "asc" ? "desc" : "asc"));
    } else {
      setSortKey(key);
      setSortDir("desc");
    }
  };

  const Head = ({ label, k }: { label: string; k: SortKey }) => (
    <th className="px-2 py-1 text-left font-normal">
      <button
        type="button"
        onClick={() => toggleSort(k)}
        aria-label={`Sort by ${label}${sortKey === k ? ` (${sortDir === "asc" ? "ascending" : "descending"})` : ""}`}
        className={cn(
          "underline-offset-2 hover:text-content-bright hover:underline",
          sortKey === k ? "text-content-bright" : "text-content-dim",
        )}
      >
        {label}
        {sortKey === k && <span aria-hidden>{sortDir === "asc" ? " ▲" : " ▼"}</span>}
      </button>
    </th>
  );

  return (
    <section aria-label="Session ledger">
      <div className="mb-token-1 flex items-baseline justify-between gap-token-4">
        <h2 className="eyebrow">Session ledger</h2>
        <span className="text-xs text-content-dim">
          {loading && events.length === 0
            ? "reading events…"
            : error
              ? "event read failed"
              : events.length > 0
                ? `${events.length} runs${capped ? " (capped)" : ""}`
                : ""}
        </span>
      </div>
      {enabledHint ? (
        <p className="rounded-lg border border-glass-line px-token-3 py-token-4 text-sm text-content-dim">
          {enabledHint}
        </p>
      ) : error ? (
        <p className="rounded-lg border border-glass-line px-token-3 py-token-4 text-sm text-content-dim">
          Could not read usage events ({error}). If this mentions an index, the
          Firestore console link in the error builds it in one click.
        </p>
      ) : events.length === 0 && !loading ? (
        <p className="rounded-lg border border-glass-line px-token-3 py-token-4 text-sm text-content-dim">
          No runs in this range with these filters.
        </p>
      ) : (
        <>
          <div className="overflow-x-auto rounded-lg border border-glass-line">
            <table className="w-full min-w-[640px] text-sm">
              <thead className="eyebrow border-b border-glass-line">
                <tr>
                  <Head label="Time" k="time" />
                  <th className="px-2 py-1 text-left font-normal">Harness</th>
                  <th className="px-2 py-1 text-left font-normal">Model</th>
                  <th className="px-2 py-1 text-left font-normal">Provider</th>
                  <Head label="Tokens" k="tokens" />
                  <Head label="Spend" k="cost" />
                  <Head label="Duration" k="duration" />
                </tr>
              </thead>
              <tbody className="divide-y divide-glass-line">
                {sorted.map((e) => (
                  <tr key={e.id}>
                    <td className="whitespace-nowrap px-2 py-1.5">
                      <button
                        type="button"
                        onClick={() => onFocusEvent(e)}
                        title="Focus this run in the inspector"
                        className="font-mono text-xs text-content-mute underline-offset-2 hover:text-content-bright hover:underline"
                      >
                        {dayTime(e.startedAt)}
                      </button>
                    </td>
                    <td className="max-w-32 truncate px-2 py-1.5 text-content-bright">
                      {e.harnessName ?? "—"}
                    </td>
                    <td className="max-w-40 truncate px-2 py-1.5 text-content-bright" title={e.model}>
                      {e.model ? modelDisplayName(e.model) : "—"}
                    </td>
                    <td className="max-w-28 truncate px-2 py-1.5 text-content-mute">
                      {providerDisplayName(e.provider)}
                    </td>
                    <td className="whitespace-nowrap px-2 py-1.5 text-right text-content-bright tabular-nums">
                      {formatCompact(e.totalTokens)}
                    </td>
                    <td className="whitespace-nowrap px-2 py-1.5 text-right text-content-mute tabular-nums">
                      {formatUsd(e.costUsd)}
                    </td>
                    <td className="whitespace-nowrap px-2 py-1.5 text-right text-content-mute tabular-nums">
                      {fmtDuration(e.durationSeconds)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="mt-token-2 flex items-center gap-token-3">
            {loading && <span className="text-xs text-content-dim">Reading…</span>}
            {hasMore && !loading && (
              <button
                type="button"
                onClick={onLoadMore}
                className="text-xs text-content-dim underline-offset-2 hover:text-content-bright hover:underline"
              >
                Load more runs
              </button>
            )}
            {capped && (
              <span className="text-xs text-content-dim">
                Capped at 2,000 events — narrow the range for the full ledger.
              </span>
            )}
          </div>
        </>
      )}
    </section>
  );
}
