"use client";

/**
 * Slide-over inspector for the explorer: a day view (that day's events,
 * provider/model/harness mix, token mix, spend, prev/next-day jump) or an
 * entity view (one provider / model / harness / account / device / session
 * focused from the ledger). Overlays the right column; Esc closes.
 *
 * Hover cards stay as previews; this is the click destination — every number,
 * bar, day, and record on the page lands here or sets a filter.
 */

import * as React from "react";

import { BrandLogo } from "@/components/BrandLogo";
import {
  formatCompact,
  formatUsd,
  ProportionBar,
} from "@/components/dashboard/cards/primitives";
import { formatDayLabel } from "@/lib/profile/activityStats";
import {
  eventsOnDay,
  rankShares,
  tokenMix,
} from "@/lib/profile/profileAggregates";
import type { ProfileUsageEvent } from "@/lib/profile/profileEvents";
import type { ProfileFilters } from "@/lib/profile/profileFilters";
import { modelDisplayName, providerDisplayName } from "@/lib/providerBrand";
import { cn } from "@/lib/utils";

export type InspectorSelection =
  | { kind: "day"; day: string }
  | {
      kind: "entity";
      entity: NonNullable<ProfileFilters["entity"]>;
    };

function MixList({
  title,
  rows,
  max,
}: {
  title: string;
  rows: { key: string; label: string; tokens: number; events: number; cost: number }[];
  max: number;
}) {
  if (rows.length === 0) return null;
  return (
    <div>
      <h3 className="eyebrow mb-token-2">{title}</h3>
      <ul className="space-y-token-2">
        {rows.map((r) => (
          <li key={r.key} className="flex items-center gap-2 text-sm">
            <span className="w-28 shrink-0 truncate text-content-bright" title={r.key}>
              {r.label}
            </span>
            <span className="min-w-0 flex-1">
              <ProportionBar value={max > 0 ? r.tokens / max : 0} />
            </span>
            <span className="min-w-[4rem] shrink-0 text-right text-content-mute tabular-nums">
              {formatCompact(r.tokens)}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

export function ProfileInspector({
  selection,
  events,
  loading,
  error,
  onRetry,
  onClose,
  onPinDay,
  onPrevDay,
  onNextDay,
}: {
  selection: InspectorSelection | null;
  /** Events for the pinned day (day query) or the active range (entity focus). */
  events: ProfileUsageEvent[];
  loading: boolean;
  /** Stable member-facing failure copy (never raw Firebase text), or null. */
  error: string | null;
  onRetry: () => void;
  onClose: () => void;
  onPinDay: (day: string) => void;
  onPrevDay: () => void;
  onNextDay: () => void;
}) {
  React.useEffect(() => {
    if (!selection) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [selection, onClose]);

  if (!selection) return null;

  if (selection.kind === "entity") {
    const { entity } = selection;
    const focused = events.filter((e) => {
      switch (entity.kind) {
        case "provider":
          return e.provider === entity.id || e.providerID === entity.id;
        case "model":
          return e.model === entity.id;
        case "harness":
          return e.harnessId === entity.id;
        case "account":
          return e.accountId === entity.id;
        case "device":
          return e.deviceId === entity.id;
        case "session":
          return e.sessionId === entity.id || e.id === entity.id;
      }
    });
    const tokens = focused.reduce((n, e) => n + e.totalTokens, 0);
    const cost = focused.reduce((n, e) => n + e.costUsd, 0);
    return (
      <InspectorShell
        eyebrow="Inspector · run"
        title={entityLabel(entity.kind, entity.id)}
        onClose={onClose}
      >
        {loading ? (
          <p className="text-sm text-content-dim">Reading events…</p>
        ) : error && focused.length === 0 ? (
          <div className="text-sm text-content-dim">
            <p>{error}</p>
            <button
              type="button"
              onClick={onRetry}
              className="mt-2 underline-offset-2 hover:text-content-bright hover:underline"
            >
              Retry
            </button>
          </div>
        ) : (
          <>
            <div className="flex items-baseline gap-token-4">
              <span className="font-display text-2xl text-content-bright tabular-nums">
                {formatCompact(tokens)}
              </span>
              <span className="text-sm text-content-dim">
                tokens · {focused.length} runs · {formatUsd(cost)}
              </span>
            </div>
            {focused.length > 0 && (
              <ul className="mt-token-4 space-y-token-2">
                {focused.slice(0, 20).map((e) => (
                  <li
                    key={e.id}
                    className="flex items-center gap-2 rounded-md border border-glass-line px-2 py-1.5 text-sm"
                  >
                    <BrandLogo id={e.provider} label={e.provider} size={16} />
                    <span className="min-w-0 flex-1 truncate text-content-bright">
                      {e.model ? modelDisplayName(e.model) : providerDisplayName(e.provider)}
                    </span>
                    <span className="shrink-0 font-mono text-xs text-content-dim">
                      {(e.startedAt ?? "").slice(0, 10)}
                    </span>
                    <span className="shrink-0 text-content-mute tabular-nums">
                      {formatCompact(e.totalTokens)}
                    </span>
                  </li>
                ))}
              </ul>
            )}
            {focused.length === 0 && (
              <p className="text-sm text-content-dim">
                No events in the loaded range match. Widen the window or load more runs.
              </p>
            )}
          </>
        )}
      </InspectorShell>
    );
  }

  const day = selection.day;
  const dayEvents = eventsOnDay(events, day);
  const tokens = dayEvents.reduce((n, e) => n + e.totalTokens, 0);
  const cost = dayEvents.reduce((n, e) => n + e.costUsd, 0);
  const mix = tokenMix(dayEvents);
  const byProvider = rankShares(dayEvents, "provider").slice(0, 5);
  const byModel = rankShares(dayEvents, "model").slice(0, 5);
  const byHarness = rankShares(dayEvents, "harness").slice(0, 5);
  const mixTotal = mix.total || 1;

  return (
    <InspectorShell
      eyebrow="Inspector · day"
      title={formatDayLabel(day)}
      onClose={onClose}
      nav={
        <div className="flex items-center gap-1">
          <button
            type="button"
            onClick={onPrevDay}
            aria-label="Previous day"
            className="rounded-md border border-glass-line px-2 py-0.5 text-xs text-content-dim hover:text-content-bright"
          >
            ←
          </button>
          <button
            type="button"
            onClick={onNextDay}
            aria-label="Next day"
            className="rounded-md border border-glass-line px-2 py-0.5 text-xs text-content-dim hover:text-content-bright"
          >
            →
          </button>
        </div>
      }
    >
      {loading && dayEvents.length === 0 ? (
        <p className="text-sm text-content-dim">Reading that day&apos;s events…</p>
      ) : error && dayEvents.length === 0 ? (
        <div className="text-sm text-content-dim">
          <p>{error}</p>
          <button
            type="button"
            onClick={onRetry}
            className="mt-2 underline-offset-2 hover:text-content-bright hover:underline"
          >
            Retry
          </button>
        </div>
      ) : dayEvents.length === 0 ? (
        <div className="text-sm text-content-dim">
          <p>No usage events loaded for this day.</p>
          <button
            type="button"
            onClick={() => onPinDay(day)}
            className={cn(
              "mt-2 underline-offset-2 hover:text-content-bright hover:underline",
            )}
          >
            Keep it pinned while the range loads
          </button>
        </div>
      ) : (
        <>
          <div className="flex items-baseline gap-token-4">
            <span className="font-display text-2xl text-content-bright tabular-nums">
              {formatCompact(tokens)}
            </span>
            <span className="text-sm text-content-dim">
              tokens · {dayEvents.length} runs · {formatUsd(cost)}
            </span>
          </div>
          <div className="mt-token-4 grid gap-token-4">
            <div>
              <h3 className="eyebrow mb-token-2">Token mix</h3>
              <p className="text-sm text-content-mute tabular-nums">
                in {formatCompact(mix.input)} · out {formatCompact(mix.output)} · cache{" "}
                {formatCompact(mix.cacheRead + mix.cacheWrite)} · reasoning{" "}
                {formatCompact(mix.reasoning)}
              </p>
              <div
                className="mt-2 flex h-2 gap-[3px] overflow-hidden rounded-pill"
                role="img"
                aria-label={`Input ${Math.round((mix.input / mixTotal) * 100)}%, output ${Math.round((mix.output / mixTotal) * 100)}%, cache ${Math.round(((mix.cacheRead + mix.cacheWrite) / mixTotal) * 100)}%, reasoning ${Math.round((mix.reasoning / mixTotal) * 100)}%`}
              >
                {(
                  [
                    ["var(--accent)", mix.input],
                    ["#CC785C", mix.output],
                    ["#38D898", mix.cacheRead + mix.cacheWrite],
                    ["#8B7FE8", mix.reasoning],
                  ] as const
                ).map(([color, v]) =>
                  v > 0 ? (
                    <span
                      key={color}
                      className="h-full"
                      style={{ width: `${(v / mixTotal) * 100}%`, background: color }}
                    />
                  ) : null,
                )}
              </div>
            </div>
            <MixList
              title="Providers"
              rows={byProvider}
              max={Math.max(...byProvider.map((r) => r.tokens), 0)}
            />
            <MixList
              title="Models"
              rows={byModel.map((r) => ({
                ...r,
                label: modelDisplayName(r.label === "Unknown model" ? undefined : r.label),
              }))}
              max={Math.max(...byModel.map((r) => r.tokens), 0)}
            />
            <MixList
              title="Harnesses"
              rows={byHarness}
              max={Math.max(...byHarness.map((r) => r.tokens), 0)}
            />
          </div>
        </>
      )}
    </InspectorShell>
  );
}

function entityLabel(kind: string, id: string): string {
  if (kind === "model") return modelDisplayName(id);
  if (kind === "provider") return providerDisplayName(id);
  return id;
}

function InspectorShell({
  eyebrow,
  title,
  onClose,
  nav,
  children,
}: {
  eyebrow: string;
  title: string;
  onClose: () => void;
  nav?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <div
      role="dialog"
      aria-label={`${eyebrow}: ${title}`}
      className="glass-pane fixed right-4 top-20 z-40 max-h-[75vh] w-[min(24rem,calc(100vw-2rem))] overflow-y-auto px-token-4 py-token-4"
    >
      <div className="flex items-start justify-between gap-token-2">
        <div className="min-w-0">
          <p className="eyebrow">{eyebrow}</p>
          <h2 className="mt-1 truncate font-display text-xl text-content-bright" title={title}>
            {title}
          </h2>
        </div>
        <button
          type="button"
          onClick={onClose}
          aria-label="Close inspector (reopen from any day, record, row, or ledger time)"
          title="Close — reopen from any day, record, row, or ledger time"
          className="shrink-0 rounded-md border border-glass-line px-2 py-0.5 text-xs text-content-dim hover:text-content-bright"
        >
          Esc
        </button>
      </div>
      {nav && <div className="mt-token-2">{nav}</div>}
      <div className="mt-token-3">{children}</div>
    </div>
  );
}
