"use client";

/**
 * Provider mix + activity insights for the explorer rail. The mix bar is the
 * graphic anchor (brand-hue segments, full-metric hovers); provider rows and
 * the "most used model" insight are filter controls under the active metric.
 */

import { BrandLogo } from "@/components/BrandLogo";
import {
  formatCompact,
  formatUsd,
} from "@/components/dashboard/cards/primitives";
import {
  modelDisplayName,
  providerBarFill,
  providerDisplayName,
} from "@/lib/providerBrand";
import type {
  ModelSummary,
  ProviderSummary,
} from "@/lib/usage";
import type { ProfileMetric } from "@/lib/profile/profileFilters";

function InsightRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-token-4 py-token-2">
      <span className="text-sm text-content-mute">{label}</span>
      <span className="text-right text-sm text-content-bright tabular-nums">{value}</span>
    </div>
  );
}

/**
 * Honest empty state: the SHAPE of what's coming (bar + logo tiles), dimmed —
 * a preview of the layout, never invented numbers.
 */
export function GhostRows({ rows = 3 }: { rows?: number }) {
  return (
    <div aria-hidden className="space-y-token-3 opacity-40">
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} className="flex items-center gap-2">
          <span className="size-[18px] shrink-0 rounded-[5px] border border-glass-line bg-mercury-wash" />
          <span
            className="h-1.5 rounded-pill bg-mercury-wash"
            style={{ width: `${86 - i * 18}%` }}
          />
        </div>
      ))}
    </div>
  );
}

export function ProfileProviderMix({
  providers,
  metric,
  pending,
  activeProviders,
  onToggleProvider,
  onInspectProvider,
  eventSourced,
}: {
  providers: ProviderSummary[];
  metric: ProfileMetric;
  pending: boolean;
  activeProviders: readonly string[];
  onToggleProvider: (id: string) => void;
  onInspectProvider: (id: string) => void;
  eventSourced?: boolean;
}) {
  const pv = (p: ProviderSummary) =>
    metric === "tokens" ? p.totalTokens : metric === "runs" ? p.totalRequests : p.totalCost;
  const ranked = [...providers].sort((a, b) => pv(b) - pv(a));
  const top = ranked.slice(0, 5);
  const total = providers.reduce((n, p) => n + pv(p), 0);
  const shown = top.reduce((n, p) => n + pv(p), 0);
  const other = Math.max(0, total - shown);
  const fmt = (v: number): string =>
    metric === "spend" ? formatUsd(v) : `${formatCompact(v)}${metric === "runs" ? " runs" : " tok"}`;

  return (
    <div>
      <h2 className="eyebrow mb-token-3">Provider mix</h2>
      {!pending && top.length > 0 && total > 0 ? (
        <>
          <div
            role="img"
            aria-label={[
              ...top.map(
                (p) =>
                  `${providerDisplayName(p.provider)} ${Math.round((pv(p) / total) * 100)}%`,
              ),
              ...(other > 0 ? [`Other ${Math.round((other / total) * 100)}%`] : []),
            ].join(", ")}
            className="flex h-2.5 gap-[3px] overflow-hidden rounded-pill"
          >
            {top.map((p) => (
              <span
                key={p.provider}
                title={`${providerDisplayName(p.provider)} — ${Math.round((pv(p) / total) * 100)}% — click to filter`}
                className="h-full transition-[width] duration-500 ease-out motion-reduce:transition-none"
                style={{
                  width: `${(pv(p) / total) * 100}%`,
                  background: providerBarFill(p.provider),
                }}
              />
            ))}
            {other > 0 ? (
              <span
                key="__other"
                title={`Other — ${Math.round((other / total) * 100)}%`}
                className="h-full"
                style={{
                  width: `${(other / total) * 100}%`,
                  background: "var(--content-dim)",
                  opacity: 0.35,
                }}
              />
            ) : null}
          </div>
          <ul className="mt-token-3 space-y-token-2">
            {top.map((p) => (
              <li key={p.provider}>
                <div className="group flex w-full min-w-0 items-center gap-token-1">
                  <button
                    type="button"
                    onClick={() => onToggleProvider(p.provider)}
                    aria-pressed={activeProviders.includes(p.provider)}
                    className="flex min-w-0 flex-1 items-center gap-2 rounded-md px-1 py-0.5 text-left text-sm transition-colors outline-none hover:bg-mercury-wash focus-visible:ring-2 focus-visible:ring-[color:var(--accent)]"
                    title={`${formatCompact(p.totalTokens)} tok · ${formatCompact(p.totalRequests)} runs · ${formatUsd(p.totalCost)}${eventSourced ? " (bounded events)" : ""} — click to filter`}
                  >
                    <BrandLogo id={p.provider} label={p.provider} size={18} />
                    <span className="truncate text-content-bright">
                      {providerDisplayName(p.provider)}
                    </span>
                    <span className="ml-auto shrink-0 text-content-mute tabular-nums">
                      {fmt(pv(p))}
                    </span>
                  </button>
                  <button
                    type="button"
                    onClick={() => onInspectProvider(p.provider)}
                    title={`Inspect ${providerDisplayName(p.provider)} in the inspector`}
                    aria-label={`Inspect ${providerDisplayName(p.provider)} in the inspector`}
                    className="shrink-0 rounded border border-glass-line px-token-2 py-0.5 text-[0.68rem] text-content-mute transition-colors hover:border-accent hover:text-content-bright focus-visible:ring-2 focus-visible:ring-[color:var(--accent)]"
                  >
                    Inspect
                  </button>
                </div>
              </li>
            ))}
            {other > 0 ? (
              <li className="flex items-center gap-2 text-sm">
                <span
                  aria-hidden
                  className="h-[18px] w-[18px] rounded-pill"
                  style={{ background: "var(--content-dim)", opacity: 0.35 }}
                />
                <span className="truncate text-content-mute">Other</span>
                <span className="ml-auto shrink-0 text-content-mute tabular-nums">
                  {fmt(other)}
                </span>
              </li>
            ) : null}
          </ul>
        </>
      ) : (
        <>
          <div aria-hidden className="h-2.5 rounded-pill bg-mercury-wash opacity-40" />
          <div className="mt-token-3">
            <GhostRows rows={3} />
          </div>
          {!pending && (
            <p className="mt-token-3 text-sm text-content-dim">
              Your provider mix lands here after the first synced runs.
            </p>
          )}
        </>
      )}
    </div>
  );
}

export function ProfileInsightsPanel({
  pending,
  activeDays,
  avgPerActiveDay,
  topModel,
  spendInView,
  freshness,
  onToggleModel,
  onInspectModel,
  eventSourced,
}: {
  pending: boolean;
  activeDays: number;
  avgPerActiveDay: number;
  topModel: ModelSummary | null;
  spendInView: number;
  freshness: string;
  onToggleModel: (id: string) => void;
  onInspectModel: (id: string) => void;
  eventSourced?: boolean;
}) {
  const num = (v: number) => (pending ? "—" : formatCompact(v));
  return (
    <div>
      <h2 className="eyebrow mb-token-3">Activity insights</h2>
      <div className="divide-y divide-glass-line border-y border-glass-line">
        <InsightRow label="Active days" value={pending ? "—" : activeDays} />
        <InsightRow label="Avg tokens per active day" value={num(avgPerActiveDay)} />
        <InsightRow
          label="Most used model"
          value={
            !pending && topModel ? (
              <span className="inline-flex items-center gap-1 whitespace-nowrap">
                <button
                  type="button"
                  onClick={() => onToggleModel(topModel.model)}
                  title={`Filter by this model${eventSourced ? " (bounded events)" : ""}`}
                  className="inline-flex items-center gap-2 rounded-sm underline-offset-2 outline-none hover:underline focus-visible:ring-2 focus-visible:ring-[color:var(--accent)]"
                >
                  <BrandLogo
                    id={topModel.provider}
                    label={topModel.provider}
                    size={18}
                  />
                  {modelDisplayName(topModel.model)}
                </button>
                <button
                  type="button"
                  onClick={() => onInspectModel(topModel.model)}
                  title={`Inspect ${modelDisplayName(topModel.model)} in the inspector`}
                  aria-label={`Inspect ${modelDisplayName(topModel.model)} in the inspector`}
                  className="rounded border border-glass-line px-token-2 py-0.5 text-[0.68rem] text-content-mute transition-colors hover:border-accent hover:text-content-bright focus-visible:ring-2 focus-visible:ring-[color:var(--accent)]"
                >
                  Inspect
                </button>
              </span>
            ) : (
              "—"
            )
          }
        />
        <InsightRow label="Spend in view" value={pending ? "—" : formatUsd(spendInView)} />
        <InsightRow label="Freshness" value={freshness} />
      </div>
    </div>
  );
}
