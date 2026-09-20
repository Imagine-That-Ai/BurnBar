"use client";

/**
 * Session ledger for the explorer. Runs group by session (unkeyed events
 * stand alone); each row expands inline to its runs. Sortable by start,
 * tokens, spend, runs, duration. Session and run buttons focus the
 * inspector; every control is visible and keyboard-reachable.
 */

import * as React from "react";

import { BrandLogo } from "@/components/BrandLogo";
import {
  formatCompact,
  formatUsd,
} from "@/components/dashboard/cards/primitives";
import { modelDisplayName } from "@/lib/providerBrand";
import type { ProfileUsageEvent } from "@/lib/profile/profileEvents";
import { cn } from "@/lib/utils";

export interface LedgerSession {
  key: string;
  sessionId: string | null;
  startedAt: string | null;
  endedAt: string | null;
  harnessName: string | null;
  models: string[];
  providers: string[];
  tokens: number;
  cost: number;
  runs: number;
  durationSeconds: number | null;
  events: ProfileUsageEvent[];
}

/**
 * Group raw usage events into sessions. Events sharing a sessionId merge;
 * events without one stand alone (keyed by event id) so nothing vanishes.
 */
export function groupLedgerSessions(events: readonly ProfileUsageEvent[]): LedgerSession[] {
  const bySession = new Map<string, ProfileUsageEvent[]>();
  for (const e of events) {
    const key = e.sessionId ? `session:${e.sessionId}` : `event:${e.id}`;
    const list = bySession.get(key) ?? [];
    list.push(e);
    bySession.set(key, list);
  }
  const sessions: LedgerSession[] = [];
  for (const [key, list] of bySession) {
    const timed = list.filter((e) => e.startedAt).map((e) => e.startedAt as string).sort();
    const models: string[] = [];
    const providers: string[] = [];
    let harnessName: string | null = null;
    let tokens = 0;
    let cost = 0;
    // Session span: earliest start → latest END (start + run duration).
    // A run without a duration ends when it starts; a session with no timed
    // runs at all has no span. Max-of-runs understates multi-run sessions.
    let spanStart: number | null = null;
    let spanEnd: number | null = null;
    for (const e of list) {
      tokens += e.totalTokens;
      cost += e.costUsd;
      if (e.harnessName && !harnessName) harnessName = e.harnessName;
      const model = e.model ?? "unknown";
      if (!models.includes(model)) models.push(model);
      const provider = e.providerID ?? e.provider;
      if (!providers.includes(provider)) providers.push(provider);
      if (e.startedAt) {
        const start = Date.parse(e.startedAt);
        if (Number.isFinite(start)) {
          spanStart = spanStart == null ? start : Math.min(spanStart, start);
          const end = e.durationSeconds != null ? start + e.durationSeconds * 1000 : start;
          spanEnd = spanEnd == null ? end : Math.max(spanEnd, end);
        }
      }
    }
    const durationSeconds =
      spanStart != null && spanEnd != null ? Math.max(0, Math.round((spanEnd - spanStart) / 1000)) : null;
    sessions.push({
      key,
      sessionId: list[0]?.sessionId ?? null,
      startedAt: timed[0] ?? null,
      endedAt: timed[timed.length - 1] ?? null,
      harnessName,
      models,
      providers,
      tokens,
      cost,
      runs: list.length,
      durationSeconds,
      events: [...list].sort((a, b) => (b.startedAt ?? "").localeCompare(a.startedAt ?? "")),
    });
  }
  return sessions;
}

type SortKey = "time" | "tokens" | "cost" | "runs" | "duration";
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

function dayOnly(iso: string | null): string {
  return iso ? iso.slice(0, 10) : "—";
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
  onFocusSession,
}: {
  events: ProfileUsageEvent[];
  loading: boolean;
  error: string | null;
  hasMore: boolean;
  capped: boolean;
  enabledHint: string | null;
  onLoadMore: () => void;
  onFocusEvent: (e: ProfileUsageEvent) => void;
  onFocusSession: (s: LedgerSession) => void;
}) {
  const [sortKey, setSortKey] = React.useState<SortKey>("time");
  const [sortDir, setSortDir] = React.useState<SortDir>("desc");
  const [expanded, setExpanded] = React.useState<ReadonlySet<string>>(() => new Set());

  const sessions = React.useMemo(() => {
    const grouped = groupLedgerSessions(events);
    const val = (s: LedgerSession): number => {
      switch (sortKey) {
        case "time":
          return s.startedAt ? Date.parse(s.startedAt) : 0;
        case "tokens":
          return s.tokens;
        case "cost":
          return s.cost;
        case "runs":
          return s.runs;
        case "duration":
          return s.durationSeconds ?? -1;
      }
    };
    return grouped.sort((a, b) => {
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

  const toggleExpanded = (key: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
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
                ? `${sessions.length} sessions · ${events.length} runs${capped ? " (capped)" : ""}`
                : ""}
        </span>
      </div>
      {enabledHint ? (
        <p className="rounded-lg border border-glass-line px-token-3 py-token-4 text-sm text-content-dim">
          {enabledHint}
        </p>
      ) : error ? (
        <p className="rounded-lg border border-glass-line px-token-3 py-token-4 text-sm text-content-dim">
          {error}{" "}
          <button
            type="button"
            onClick={onLoadMore}
            className="underline-offset-2 hover:text-content-bright hover:underline"
          >
            Retry
          </button>
        </p>
      ) : events.length === 0 && !loading ? (
        <p className="rounded-lg border border-glass-line px-token-3 py-token-4 text-sm text-content-dim">
          No runs in this range with these filters.
        </p>
      ) : (
        <>
          <div className="overflow-x-auto rounded-lg border border-glass-line">
            <table className="w-full min-w-[720px] text-sm">
              <thead className="eyebrow border-b border-glass-line">
                <tr>
                  <th className="w-8 px-2 py-1" aria-label="Expand" />
                  <Head label="Session" k="time" />
                  <th className="px-2 py-1 text-left font-normal">Harness</th>
                  <th className="px-2 py-1 text-left font-normal">Models</th>
                  <Head label="Runs" k="runs" />
                  <Head label="Tokens" k="tokens" />
                  <Head label="Spend" k="cost" />
                  <Head label="Duration" k="duration" />
                </tr>
              </thead>
              <tbody className="divide-y divide-glass-line">
                {sessions.map((s) => {
                  const open = expanded.has(s.key);
                  return (
                    <React.Fragment key={s.key}>
                      <tr className="align-top">
                        <td className="px-2 py-1.5">
                          <button
                            type="button"
                            onClick={() => toggleExpanded(s.key)}
                            aria-expanded={open}
                            aria-label={`${open ? "Collapse" : "Expand"} session ${s.sessionId ?? dayOnly(s.startedAt)} (${s.runs} runs)`}
                            className="rounded px-1 font-mono text-xs text-content-dim hover:text-content-bright"
                          >
                            <span aria-hidden>{open ? "▾" : "▸"}</span>
                          </button>
                        </td>
                        <td className="whitespace-nowrap px-2 py-1.5">
                          <button
                            type="button"
                            onClick={() => onFocusSession(s)}
                            title="Focus this session in the inspector"
                            className="text-left font-mono text-xs text-content-mute underline-offset-2 hover:text-content-bright hover:underline"
                          >
                            {dayTime(s.startedAt)}
                            {s.runs > 1 && (
                              <span className="ml-1 text-content-dim">→ {dayOnly(s.endedAt)}</span>
                            )}
                          </button>
                          {s.sessionId && (
                            <div className="mt-0.5 max-w-36 truncate font-mono text-[0.65rem] text-content-dim" title={s.sessionId}>
                              {s.sessionId.slice(0, 8)}
                            </div>
                          )}
                        </td>
                        <td className="max-w-32 truncate px-2 py-1.5 text-content-bright">
                          {s.harnessName ?? "—"}
                        </td>
                        <td className="max-w-44 px-2 py-1.5 text-content-bright">
                          <span className="flex flex-wrap items-center gap-1">
                            {s.providers.slice(0, 1).map((p) => (
                              <BrandLogo key={p} id={p} label={p} size={16} />
                            ))}
                            <span className="truncate" title={s.models.join(", ")}>
                              {s.models.slice(0, 2).map((m) => modelDisplayName(m)).join(" · ")}
                              {s.models.length > 2 && (
                                <span className="text-content-dim"> +{s.models.length - 2}</span>
                              )}
                            </span>
                          </span>
                        </td>
                        <td className="whitespace-nowrap px-2 py-1.5 text-right text-content-mute tabular-nums">
                          {s.runs}
                        </td>
                        <td className="whitespace-nowrap px-2 py-1.5 text-right text-content-bright tabular-nums">
                          {formatCompact(s.tokens)}
                        </td>
                        <td className="whitespace-nowrap px-2 py-1.5 text-right text-content-mute tabular-nums">
                          {formatUsd(s.cost)}
                        </td>
                        <td className="whitespace-nowrap px-2 py-1.5 text-right text-content-mute tabular-nums">
                          {fmtDuration(s.durationSeconds)}
                        </td>
                      </tr>
                      {open &&
                        s.events.map((e) => (
                          <tr key={e.id} className="bg-mercury-wash/40">
                            <td />
                            <td className="whitespace-nowrap py-1 pl-6 pr-2">
                              <button
                                type="button"
                                onClick={() => onFocusEvent(e)}
                                title="Focus this run in the inspector"
                                className="font-mono text-[0.68rem] text-content-mute underline-offset-2 hover:text-content-bright hover:underline"
                              >
                                {dayTime(e.startedAt)}
                              </button>
                            </td>
                            <td className="px-2 py-1 text-xs text-content-mute">
                              {e.harnessName ?? "—"}
                            </td>
                            <td className="max-w-44 truncate px-2 py-1 text-xs text-content-mute" title={e.model}>
                              {e.model ? modelDisplayName(e.model) : "—"}
                            </td>
                            <td />
                            <td className="whitespace-nowrap px-2 py-1 text-right text-xs text-content-bright tabular-nums">
                              {formatCompact(e.totalTokens)}
                            </td>
                            <td className="whitespace-nowrap px-2 py-1 text-right text-xs text-content-mute tabular-nums">
                              {formatUsd(e.costUsd)}
                            </td>
                            <td className="whitespace-nowrap px-2 py-1 text-right text-xs text-content-mute tabular-nums">
                              {fmtDuration(e.durationSeconds)}
                            </td>
                          </tr>
                        ))}
                    </React.Fragment>
                  );
                })}
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
