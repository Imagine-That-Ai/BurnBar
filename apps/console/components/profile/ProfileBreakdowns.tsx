"use client";

/**
 * Searchable, clickable breakdown lists for the explorer rail: providers,
 * models, harnesses, combos, devices, and accounts. Every row is a control —
 * click toggles that facet chip; shift/alt-click (or the row's inspect
 * affordance) ALSO focuses the entity in the inspector, so a dismissed
 * inspector is one click away from anywhere. The Pensieve search-box idiom
 * keeps long catalogs scannable.
 */

import * as React from "react";

import { BrandLogo } from "@/components/BrandLogo";
import {
  ProportionBar,
  formatCompact,
  formatUsd,
} from "@/components/dashboard/cards/primitives";
import {
  comboModelShortName,
  modelDisplayName,
  providerBarFill,
  providerDisplayName,
} from "@/lib/providerBrand";
import type {
  AccountSummary,
  ComboSummary,
  DeviceSummary,
  ExecutionSourceSummary,
  ModelSummary,
  ProviderSummary,
} from "@/lib/usage";
import type { ProfileMetric } from "@/lib/profile/profileFilters";
import { cn } from "@/lib/utils";

export type BreakdownFacet =
  | { kind: "provider"; id: string }
  | { kind: "model"; id: string }
  | { kind: "harness"; id: string }
  | { kind: "account"; id: string }
  | { kind: "device"; id: string };

function fmtMetric(metric: ProfileMetric, v: number): string {
  return metric === "spend" ? formatUsd(v) : `${formatCompact(v)}${metric === "runs" ? " runs" : " tok"}`;
}

function ClickRow({
  active,
  logoId,
  logoLabel,
  name,
  nameTitle,
  barValue,
  barColor,
  barLabel,
  value,
  onClick,
  onInspect,
  inspectLabel,
}: {
  active: boolean;
  logoId: string;
  logoLabel: string;
  name: React.ReactNode;
  nameTitle?: string;
  barValue: number;
  barColor: string;
  barLabel: string;
  value: string;
  onClick: () => void;
  /** Entity drill-in (facet + inspector focus, one update). */
  onInspect: () => void;
  inspectLabel: string;
}) {
  return (
    <li>
      <div
        className={cn(
          "group flex w-full min-w-0 items-center gap-token-2 rounded-md px-token-2 py-token-2 text-left text-sm transition-colors hover:bg-mercury-wash",
          active && "bg-mercury-wash ring-1 ring-[color:var(--accent)]",
        )}
      >
        <button
          type="button"
          onClick={onClick}
          aria-pressed={active}
          title={nameTitle}
          className="flex min-w-0 flex-1 items-center gap-2 rounded-sm text-left outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--accent)]"
        >
          <BrandLogo id={logoId} label={logoLabel} size={18} />
          <span className="w-28 shrink-0 truncate text-content-bright sm:w-32">{name}</span>
          <span className="min-w-0 flex-1" role="img" aria-label={barLabel}>
            <ProportionBar value={barValue} color={barColor} />
          </span>
          <span className="min-w-[4rem] shrink-0 whitespace-nowrap text-right text-content-mute tabular-nums">
            {value}
          </span>
        </button>
        <button
          type="button"
          onClick={onInspect}
          title={inspectLabel}
          aria-label={inspectLabel}
          className="shrink-0 rounded border border-glass-line px-token-2 py-0.5 text-[0.68rem] text-content-mute transition-colors hover:border-accent hover:text-content-bright focus-visible:opacity-100 focus-visible:ring-2 focus-visible:ring-[color:var(--accent)]"
        >
          Inspect
        </button>
      </div>
    </li>
  );
}

function SearchableList({
  title,
  items,
  renderItem,
  emptyHint,
}: {
  title: string;
  items: React.ReactNode[];
  renderItem: (q: string) => React.ReactNode[];
  emptyHint: string;
}) {
  const [q, setQ] = React.useState("");
  const query = q.trim().toLowerCase();
  const shown = query ? renderItem(query) : items;
  return (
    <div>
      <h2 className="eyebrow mb-token-3">{title}</h2>
      {items.length === 0 ? (
        <p className="text-sm text-content-dim">{emptyHint}</p>
      ) : (
        <>
          {items.length > 5 && (
            <input
              type="search"
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder={`Search ${title.toLowerCase()}…`}
              aria-label={`Search ${title}`}
              className="mb-token-2 w-full rounded-md bg-mercury-wash px-token-3 py-1.5 text-sm text-content-base outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--accent)]"
              style={{ border: "1px solid var(--color-glass-line)" }}
            />
          )}
          <ul className="max-h-64 space-y-token-1 overflow-y-auto pr-1">
            {shown.length > 0 ? (
              shown
            ) : (
              <li className="py-2 text-center text-sm text-content-dim">No matches.</li>
            )}
          </ul>
        </>
      )}
    </div>
  );
}

export interface BreakdownData {
  providers: ProviderSummary[];
  models: ModelSummary[];
  harnesses: ExecutionSourceSummary[];
  combos: ComboSummary[];
  devices: DeviceSummary[];
  accounts: AccountSummary[];
}

export function ProfileBreakdowns({
  data,
  metric,
  activeFacets,
  onToggle,
  onInspect,
}: {
  data: BreakdownData;
  metric: ProfileMetric;
  activeFacets: {
    providers: readonly string[];
    models: readonly string[];
    harnesses: readonly string[];
    accounts: readonly string[];
    devices: readonly string[];
  };
  onToggle: (f: BreakdownFacet) => void;
  onInspect: (f: BreakdownFacet) => void;
}) {
  const pv = (p: ProviderSummary) =>
    metric === "tokens" ? p.totalTokens : metric === "runs" ? p.totalRequests : p.totalCost;
  const mv = (m: ModelSummary) =>
    metric === "tokens" ? m.tokens : metric === "runs" ? m.requests : m.cost;
  const hv = (h: ExecutionSourceSummary) =>
    metric === "tokens" ? h.totalTokens : metric === "runs" ? h.totalRequests : h.totalCost;
  const cv = (c: ComboSummary) =>
    metric === "tokens" ? c.tokens : metric === "runs" ? c.requests : c.cost;
  const dv = (d: DeviceSummary) =>
    metric === "spend" ? 0 : metric === "runs" ? d.requests : d.tokens;
  const av = (a: AccountSummary) =>
    metric === "tokens" ? a.totalTokens : metric === "runs" ? a.totalRequests : a.totalCost;

  const byDesc = <T,>(items: readonly T[], value: (item: T) => number): T[] =>
    [...items].sort((a, b) => value(b) - value(a));

  const providers = byDesc(data.providers, pv);
  const models = byDesc(data.models, mv);
  const harnesses = byDesc(data.harnesses, hv);
  const combos = byDesc(data.combos, cv);
  const devices = byDesc(data.devices, dv);
  const accounts = byDesc(data.accounts, av);

  const modelMax = models.length ? Math.max(...models.map(mv)) : 0;
  const harnessMax = harnesses.length ? Math.max(...harnesses.map(hv)) : 0;
  const comboMax = combos.length ? Math.max(...combos.map(cv)) : 0;
  const deviceMax = devices.length ? Math.max(...devices.map(dv)) : 0;
  const accountMax = accounts.length ? Math.max(...accounts.map(av)) : 0;

  const matchQ = (text: string, q: string) => text.toLowerCase().includes(q);

  return (
    <div className="grid content-start gap-token-8">
      {providers.length > 0 && (
        <div>
          <h2 className="eyebrow mb-token-3">Providers</h2>
          <ul className="space-y-token-1">
            {providers.map((p) => (
              <ClickRow
                key={p.provider}
                active={activeFacets.providers.includes(p.provider)}
                logoId={p.provider}
                logoLabel={p.provider}
                name={providerDisplayName(p.provider)}
                nameTitle={`${p.provider} · ${formatCompact(p.totalTokens)} tok · ${formatCompact(p.totalRequests)} runs · ${formatUsd(p.totalCost)}`}
                barValue={pv(p) / Math.max(1, Math.max(...providers.map(pv)))}
                barColor={providerBarFill(p.provider)}
                barLabel={`${providerDisplayName(p.provider)} ${fmtMetric(metric, pv(p))}`}
                value={fmtMetric(metric, pv(p))}
                onClick={() => onToggle({ kind: "provider", id: p.provider })}
                onInspect={() => onInspect({ kind: "provider", id: p.provider })}
                inspectLabel={`Inspect ${providerDisplayName(p.provider)} in the inspector`}
              />
            ))}
          </ul>
        </div>
      )}

      <SearchableList
        title="Models"
        emptyHint="No models in this view yet."
        items={models.map((m) => (
          <ClickRow
            key={`${m.provider}/${m.model}`}
            active={activeFacets.models.includes(m.model)}
            logoId={m.provider}
            logoLabel={m.provider}
            name={modelDisplayName(m.model)}
            nameTitle={`${m.model} · ${formatCompact(m.tokens)} tok · ${formatCompact(m.requests)} runs · ${formatUsd(m.cost)}`}
            barValue={modelMax > 0 ? mv(m) / modelMax : 0}
            barColor={providerBarFill(m.provider)}
            barLabel={`${modelDisplayName(m.model)} ${fmtMetric(metric, mv(m))}`}
            value={fmtMetric(metric, mv(m))}
            onClick={() => onToggle({ kind: "model", id: m.model })}
            onInspect={() => onInspect({ kind: "model", id: m.model })}
            inspectLabel={`Inspect ${modelDisplayName(m.model)} in the inspector`}
          />
        ))}
        renderItem={(q) =>
          models
            .filter((m) => matchQ(modelDisplayName(m.model), q) || matchQ(m.model, q))
            .map((m) => (
              <ClickRow
                key={`${m.provider}/${m.model}`}
                active={activeFacets.models.includes(m.model)}
                logoId={m.provider}
                logoLabel={m.provider}
                name={modelDisplayName(m.model)}
                nameTitle={m.model}
                barValue={modelMax > 0 ? mv(m) / modelMax : 0}
                barColor={providerBarFill(m.provider)}
                barLabel={`${modelDisplayName(m.model)} ${fmtMetric(metric, mv(m))}`}
                value={fmtMetric(metric, mv(m))}
                onClick={() => onToggle({ kind: "model", id: m.model })}
                onInspect={() => onInspect({ kind: "model", id: m.model })}
                inspectLabel={`Inspect ${modelDisplayName(m.model)} in the inspector`}
              />
            ))
        }
      />

      {harnesses.length > 0 && (
        <SearchableList
          title="Harnesses"
          emptyHint="No harnesses in this view yet."
          items={harnesses.map((h) => (
            <ClickRow
              key={h.sourceId}
              active={activeFacets.harnesses.includes(h.sourceId)}
              logoId={h.sourceId}
              logoLabel={h.sourceName}
              name={h.sourceName}
              nameTitle={`${h.sourceId} · ${formatCompact(h.totalTokens)} tok · ${formatCompact(h.totalRequests)} runs · ${formatUsd(h.totalCost)}`}
              barValue={harnessMax > 0 ? hv(h) / harnessMax : 0}
              barColor={providerBarFill(h.sourceId)}
              barLabel={`${h.sourceName} ${fmtMetric(metric, hv(h))}`}
              value={fmtMetric(metric, hv(h))}
              onClick={() => onToggle({ kind: "harness", id: h.sourceId })}
              onInspect={() => onInspect({ kind: "harness", id: h.sourceId })}
              inspectLabel={`Inspect ${h.sourceName} in the inspector`}
            />
          ))}
          renderItem={(q) =>
            harnesses
              .filter((h) => matchQ(h.sourceName, q) || matchQ(h.sourceId, q))
              .map((h) => (
                <ClickRow
                  key={h.sourceId}
                  active={activeFacets.harnesses.includes(h.sourceId)}
                  logoId={h.sourceId}
                  logoLabel={h.sourceName}
                  name={h.sourceName}
                  nameTitle={h.sourceId}
                  barValue={harnessMax > 0 ? hv(h) / harnessMax : 0}
                  barColor={providerBarFill(h.sourceId)}
                  barLabel={`${h.sourceName} ${fmtMetric(metric, hv(h))}`}
                  value={fmtMetric(metric, hv(h))}
                  onClick={() => onToggle({ kind: "harness", id: h.sourceId })}
                  onInspect={() => onInspect({ kind: "harness", id: h.sourceId })}
                  inspectLabel={`Inspect ${h.sourceName} in the inspector`}
                />
              ))
          }
        />
      )}

      {combos.length > 0 && (
        <div>
          <h2 className="eyebrow mb-token-3">Combos</h2>
          <ul className="max-h-64 space-y-token-1 overflow-y-auto pr-1">
            {combos.map((c) => (
              <li key={`${c.sourceId}/${c.provider}/${c.model}`}>
                <div className="group flex w-full min-w-0 items-center gap-token-2 rounded-md px-token-2 py-token-2 text-left text-sm transition-colors hover:bg-mercury-wash">
                  <button
                    type="button"
                    onClick={() => onToggle({ kind: "harness", id: c.sourceId })}
                    title={`${c.sourceName} × ${c.model} · ${formatCompact(c.tokens)} tok — click to filter by ${c.sourceName}`}
                    className="flex min-w-0 flex-1 items-center gap-2 rounded-sm text-left outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--accent)]"
                  >
                    <BrandLogo id={c.sourceId} label={c.sourceName} size={18} />
                    <span className="w-40 shrink-0 truncate text-content-bright sm:w-44">
                      {c.sourceName} <span className="text-content-dim">×</span>{" "}
                      {comboModelShortName(c.sourceName, c.model)}
                    </span>
                    <span
                      className="min-w-0 flex-1"
                      role="img"
                      aria-label={`${c.sourceName} ${modelDisplayName(c.model)} ${fmtMetric(metric, cv(c))}`}
                    >
                      <ProportionBar
                        value={comboMax > 0 ? cv(c) / comboMax : 0}
                        color={providerBarFill(c.provider)}
                      />
                    </span>
                    <span className="min-w-[4rem] shrink-0 whitespace-nowrap text-right text-content-mute tabular-nums">
                      {fmtMetric(metric, cv(c))}
                    </span>
                  </button>
                  <button
                    type="button"
                    onClick={() => onInspect({ kind: "harness", id: c.sourceId })}
                    title={`Inspect ${c.sourceName} in the inspector`}
                    aria-label={`Inspect ${c.sourceName} in the inspector`}
                    className="shrink-0 rounded border border-glass-line px-token-2 py-0.5 text-[0.68rem] text-content-mute transition-colors hover:border-accent hover:text-content-bright focus-visible:ring-2 focus-visible:ring-[color:var(--accent)]"
                  >
                    Inspect
                  </button>
                </div>
              </li>
            ))}
          </ul>
        </div>
      )}

      {devices.length > 0 && (
        <div>
          <h2 className="eyebrow mb-token-3">Devices</h2>
          <ul className="space-y-token-1">
            {devices.map((d) => (
              <ClickRow
                key={d.deviceId}
                active={activeFacets.devices.includes(d.deviceId)}
                logoId={d.deviceId}
                logoLabel={d.deviceId}
                name={d.deviceId}
                nameTitle={`${d.deviceId} · ${formatCompact(d.tokens)} tok · ${formatCompact(d.requests)} runs`}
                barValue={deviceMax > 0 ? dv(d) / deviceMax : 0}
                barColor="var(--accent)"
                barLabel={`${d.deviceId} ${fmtMetric(metric, dv(d))}`}
                value={fmtMetric(metric, dv(d))}
                onClick={() => onToggle({ kind: "device", id: d.deviceId })}
                onInspect={() => onInspect({ kind: "device", id: d.deviceId })}
                inspectLabel={`Inspect ${d.deviceId} in the inspector`}
              />
            ))}
          </ul>
        </div>
      )}

      {accounts.length > 0 && (
        <SearchableList
          title="Accounts"
          emptyHint="No linked accounts in this view yet."
          items={accounts.map((a) => (
            <ClickRow
              key={a.id}
              active={activeFacets.accounts.includes(a.id)}
              logoId={a.providerID}
              logoLabel={a.providerID}
              name={a.accountLabel}
              nameTitle={`${a.id} · ${formatCompact(a.totalTokens)} tok · ${formatCompact(a.totalRequests)} runs · ${formatUsd(a.totalCost)}`}
              barValue={accountMax > 0 ? av(a) / accountMax : 0}
              barColor={providerBarFill(a.providerID)}
              barLabel={`${a.accountLabel} ${fmtMetric(metric, av(a))}`}
              value={fmtMetric(metric, av(a))}
              onClick={() => onToggle({ kind: "account", id: a.id })}
              onInspect={() => onInspect({ kind: "account", id: a.id })}
              inspectLabel={`Inspect ${a.accountLabel} in the inspector`}
            />
          ))}
          renderItem={(q) =>
            accounts
              .filter((a) => matchQ(a.accountLabel, q) || matchQ(a.id, q))
              .map((a) => (
                <ClickRow
                  key={a.id}
                  active={activeFacets.accounts.includes(a.id)}
                  logoId={a.providerID}
                  logoLabel={a.providerID}
                  name={a.accountLabel}
                  nameTitle={a.id}
                  barValue={accountMax > 0 ? av(a) / accountMax : 0}
                  barColor={providerBarFill(a.providerID)}
                  barLabel={`${a.accountLabel} ${fmtMetric(metric, av(a))}`}
                  value={fmtMetric(metric, av(a))}
                  onClick={() => onToggle({ kind: "account", id: a.id })}
                  onInspect={() => onInspect({ kind: "account", id: a.id })}
                  inspectLabel={`Inspect ${a.accountLabel} in the inspector`}
                />
              ))
          }
        />
      )}

      <p className="text-xs text-content-dim">
        Click a row to filter. Hover a row for Inspect → to reopen the inspector.
      </p>
    </div>
  );
}
