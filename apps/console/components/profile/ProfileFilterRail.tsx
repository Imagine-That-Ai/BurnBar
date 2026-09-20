"use client";

/**
 * Sticky filter rail for the mineable /profile explorer: window presets +
 * custom [from, to] dates, multi-select facet chips (provider / model /
 * harness / account / device), and the Tokens / Runs / Spend metric.
 *
 * Controlled: the page owns the filters (URL is the source of truth) and
 * passes facet options derived from the rollup lists so the pickers are
 * instant. Every change flows back through `onChange`.
 */

import * as React from "react";

import {
  PROFILE_METRICS,
  PROFILE_WINDOWS,
  type ProfileFilters,
  type ProfileMetric,
  type ProfileWindowKey,
} from "@/lib/profile/profileFilters";
import { providerDisplayName } from "@/lib/providerBrand";
import { cn } from "@/lib/utils";

export interface FacetOptions {
  providers: string[];
  models: string[];
  harnesses: { id: string; name: string }[];
  accounts: { id: string; label: string }[];
  devices: string[];
}

const WINDOW_LABEL: Record<ProfileWindowKey, string> = {
  "7d": "7d",
  "30d": "30d",
  "90d": "90d",
  all: "All",
};

const METRIC_LABEL: Record<ProfileMetric, string> = {
  tokens: "Tokens",
  runs: "Runs",
  spend: "Spend",
};

function Chip({
  active,
  label,
  title,
  onClick,
  onClear,
}: {
  active: boolean;
  label: string;
  title?: string;
  onClick: () => void;
  /** When set, the chip renders a × that clears just this value. */
  onClear?: () => void;
}) {
  return (
    <span
      className={cn(
        "inline-flex max-w-44 items-center gap-1 rounded-pill border px-2 py-0.5 text-xs",
        active
          ? "border-accent text-content-bright"
          : "border-glass-line text-content-dim hover:text-content-mute",
      )}
      style={active ? { background: "var(--accent-wash)" } : undefined}
      title={title ?? label}
    >
      <button
        type="button"
        aria-pressed={active}
        onClick={onClick}
        className="min-w-0 flex-1 truncate text-left"
      >
        {label}
      </button>
      {onClear && (
        <button
          type="button"
          onClick={onClear}
          aria-label={`Remove ${label} filter`}
          className="shrink-0 text-content-dim hover:text-content-bright"
        >
          ×
        </button>
      )}
    </span>
  );
}

function FacetGroup({
  label,
  options,
  active,
  onToggle,
}: {
  label: string;
  options: { value: string; label: string }[];
  active: readonly string[];
  onToggle: (value: string) => void;
}) {
  const [open, setOpen] = React.useState(false);
  const [q, setQ] = React.useState("");
  const query = q.trim().toLowerCase();
  const visible = query
    ? options.filter((o) => o.label.toLowerCase().includes(query))
    : options;
  if (options.length === 0) return null;
  return (
    <div className="min-w-0">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className="eyebrow flex items-center gap-1 hover:text-content-mute"
      >
        {label}
        {active.length > 0 && (
          <span className="rounded-pill bg-mercury-wash px-1.5 text-content-bright">
            {active.length}
          </span>
        )}
        <span aria-hidden className="text-content-dim">{open ? "▾" : "▸"}</span>
      </button>
      {open && (
        <div className="mt-token-2 max-h-44 space-y-token-1 overflow-y-auto pr-1">
          {options.length > 6 && (
            <input
              type="search"
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder={`Search ${label.toLowerCase()}…`}
              aria-label={`Search ${label}`}
              className="w-full rounded-md bg-mercury-wash px-2 py-1 text-xs text-content-base outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--accent)]"
              style={{ border: "1px solid var(--color-glass-line)" }}
            />
          )}
          {visible.map((o) => {
            const isActive = active.includes(o.value);
            return (
              <div key={o.value}>
                <Chip
                  active={isActive}
                  label={o.label}
                  title={o.value !== o.label ? o.value : undefined}
                  onClick={() => onToggle(o.value)}
                  onClear={isActive ? () => onToggle(o.value) : undefined}
                />
              </div>
            );
          })}
          {visible.length === 0 && (
            <p className="py-2 text-center text-xs text-content-dim">No matches.</p>
          )}
        </div>
      )}
    </div>
  );
}

export function ProfileFilterRail({
  filters,
  options,
  computedAt,
  snapNotice,
  onChange,
  onClear,
}: {
  filters: ProfileFilters;
  options: FacetOptions;
  /** Rollup freshness ISO timestamp (dashboard FreshnessLabel idiom). */
  computedAt: string | null;
  /** One-shot notice, e.g. the All→90d snap for event facets. */
  snapNotice: string | null;
  onChange: (f: ProfileFilters) => void;
  onClear: () => void;
}) {
  const customActive = filters.from != null || filters.to != null;
  const toggle = (group: "providers" | "models" | "harnesses" | "accounts" | "devices", value: string) => {
    const list = filters.facets[group];
    const next = list.includes(value) ? list.filter((v) => v !== value) : [...list, value];
    onChange({ ...filters, facets: { ...filters.facets, [group]: next } });
  };

  const setWindow = (window: ProfileWindowKey) => {
    onChange({ ...filters, window, from: null, to: null });
  };

  const activeChipCount =
    filters.facets.providers.length +
    filters.facets.models.length +
    filters.facets.harnesses.length +
    filters.facets.accounts.length +
    filters.facets.devices.length;

  return (
    <section
      aria-label="Profile filters"
      className="rounded-lg border border-glass-line px-token-4 py-token-3"
    >
      <div className="flex flex-wrap items-center gap-token-2">
        <div
          role="group"
          aria-label="Window"
          className="flex items-center gap-0.5 rounded-pill border border-glass-line p-0.5"
        >
          {PROFILE_WINDOWS.map((w) => {
            const active = filters.window === w && !customActive;
            return (
              <button
                key={w}
                type="button"
                onClick={() => setWindow(w)}
                aria-pressed={active}
                className={cn(
                  "rounded-pill px-3 py-1 text-xs font-medium transition-colors",
                  active ? "text-content-bright" : "text-content-dim hover:text-content-mute",
                )}
                style={active ? { background: "var(--accent-wash)" } : undefined}
              >
                {WINDOW_LABEL[w]}
              </button>
            );
          })}
        </div>

        <label className="flex items-center gap-1 text-xs text-content-dim">
          From
          <input
            type="date"
            value={filters.from ?? ""}
            max={filters.to ?? undefined}
            onChange={(e) =>
              onChange({ ...filters, from: e.target.value || null })
            }
            aria-label="Custom range start"
            className="rounded-md bg-mercury-wash px-2 py-1 text-xs text-content-base outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--accent)]"
            style={{ border: "1px solid var(--color-glass-line)" }}
          />
        </label>
        <label className="flex items-center gap-1 text-xs text-content-dim">
          To
          <input
            type="date"
            value={filters.to ?? ""}
            min={filters.from ?? undefined}
            onChange={(e) => onChange({ ...filters, to: e.target.value || null })}
            aria-label="Custom range end"
            className="rounded-md bg-mercury-wash px-2 py-1 text-xs text-content-base outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--accent)]"
            style={{ border: "1px solid var(--color-glass-line)" }}
          />
        </label>

        <div className="flex-1" />

        {computedAt && (
          <span
            className="font-mono text-[0.62rem] uppercase tracking-[0.14em] text-content-dim"
            title={computedAt}
          >
            Rollup {computedAt.slice(0, 10)}
          </span>
        )}

        <div
          role="group"
          aria-label="Breakdown metric"
          className="flex items-center gap-token-1 rounded-pill border border-glass-line p-0.5"
        >
          {PROFILE_METRICS.map((m) => (
            <button
              key={m}
              type="button"
              aria-pressed={filters.metric === m}
              onClick={() => onChange({ ...filters, metric: m })}
              className={cn(
                "rounded-pill px-token-2 py-0.5 text-[0.68rem] transition-colors duration-150",
                filters.metric === m
                  ? "text-content-bright"
                  : "text-content-dim hover:text-content-mute",
              )}
              style={filters.metric === m ? { background: "var(--accent-wash)" } : undefined}
            >
              {METRIC_LABEL[m]}
            </button>
          ))}
        </div>

        {activeChipCount > 0 && (
          <button
            type="button"
            onClick={onClear}
            className="text-xs text-content-dim underline-offset-2 hover:text-content-bright hover:underline"
          >
            Clear {activeChipCount}
          </button>
        )}
      </div>

      {snapNotice && (
        <p role="status" className="mt-token-2 text-xs text-content-mute">
          {snapNotice}
        </p>
      )}

      <div className="mt-token-3 grid gap-token-4 sm:grid-cols-2 lg:grid-cols-5">
        <FacetGroup
          label="Providers"
          options={options.providers.map((p) => ({ value: p, label: providerDisplayName(p) }))}
          active={filters.facets.providers}
          onToggle={(v) => toggle("providers", v)}
        />
        <FacetGroup
          label="Models"
          options={options.models.map((m) => ({ value: m, label: m }))}
          active={filters.facets.models}
          onToggle={(v) => toggle("models", v)}
        />
        <FacetGroup
          label="Harnesses"
          options={options.harnesses.map((h) => ({ value: h.id, label: h.name }))}
          active={filters.facets.harnesses}
          onToggle={(v) => toggle("harnesses", v)}
        />
        <FacetGroup
          label="Accounts"
          options={options.accounts.map((a) => ({ value: a.id, label: a.label }))}
          active={filters.facets.accounts}
          onToggle={(v) => toggle("accounts", v)}
        />
        <FacetGroup
          label="Devices"
          options={options.devices.map((d) => ({ value: d, label: d }))}
          active={filters.facets.devices}
          onToggle={(v) => toggle("devices", v)}
        />
      </div>
    </section>
  );
}
