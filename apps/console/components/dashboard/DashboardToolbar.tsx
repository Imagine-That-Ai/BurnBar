"use client";

import * as React from "react";
import { Check, Pencil, Plus, RotateCcw, RotateCw, Sparkles } from "lucide-react";

import { KERNEL_SPECS, type KernelId } from "@/lib/gl/kernels";
import { USAGE_WINDOWS, type UsageWindowKey } from "@/lib/usage";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { CARD_DEFS, type CardId } from "./cardRegistry";

const WINDOW_SHORT: Record<UsageWindowKey, string> = {
  today: "Today",
  "7d": "7d",
  "30d": "30d",
  "90d": "90d",
  all_time: "All",
};

/** Coarse "updated 3m ago" from an ISO timestamp (client-only; never SSR). */
function relativeTime(iso: string, now: number): string {
  const then = Date.parse(iso);
  if (!Number.isFinite(then)) return "";
  const secs = Math.max(0, Math.round((now - then) / 1000));
  if (secs < 60) return "just now";
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.round(hrs / 24)}d ago`;
}

export interface DashboardToolbarProps {
  window: UsageWindowKey;
  setWindow: (w: UsageWindowKey) => void;
  source: "live" | "empty";
  computedAt: string | null;
  loading: boolean;
  onRefresh: () => void;
  placedIds: ReadonlySet<string>;
  addCard: (id: CardId) => void;
  removeCard: (id: string) => void;
  editable: boolean;
  setEditable: (v: boolean) => void;
  kernelId: KernelId;
  setKernel: (id: KernelId) => void;
  frost: number;
  setFrost: (n: number) => void;
  reset: () => void;
}

export function DashboardToolbar(props: DashboardToolbarProps) {
  const [wizardOpen, setWizardOpen] = React.useState(false);
  const [appearanceOpen, setAppearanceOpen] = React.useState(false);

  return (
    <div className="flex flex-wrap items-center gap-token-2">
      {/* Usage window segmented control */}
      <div
        className="flex items-center gap-0.5 rounded-pill p-0.5"
        style={{ border: "1px solid var(--color-glass-line)" }}
        role="group"
        aria-label="Usage window"
      >
        {USAGE_WINDOWS.map((w) => {
          const active = props.window === w;
          return (
            <button
              key={w}
              type="button"
              onClick={() => props.setWindow(w)}
              aria-pressed={active}
              className="rounded-pill px-3 py-1 text-xs font-medium transition-colors"
              style={{
                color: active ? "#fff" : "var(--color-text-mute)",
                background: active ? "var(--accent)" : "transparent",
              }}
            >
              {WINDOW_SHORT[w]}
            </button>
          );
        })}
      </div>

      <div className="flex-1" />

      <FreshnessLabel source={props.source} computedAt={props.computedAt} loading={props.loading} />

      <Button
        variant="ghost"
        size="sm"
        onClick={props.onRefresh}
        disabled={props.loading}
        aria-label="Refresh usage"
      >
        <RotateCw aria-hidden className={props.loading ? "animate-spin" : undefined} /> Refresh
      </Button>
      <Button variant="secondary" size="sm" onClick={() => setWizardOpen(true)}>
        <Plus aria-hidden /> Add cards
      </Button>
      <Button
        variant={props.editable ? "primary" : "ghost"}
        size="sm"
        onClick={() => props.setEditable(!props.editable)}
        aria-pressed={props.editable}
      >
        <Pencil aria-hidden /> {props.editable ? "Done" : "Edit layout"}
      </Button>
      <Button variant="ghost" size="sm" onClick={() => setAppearanceOpen(true)}>
        <Sparkles aria-hidden /> Appearance
      </Button>

      {/* Add-cards wizard */}
      <Dialog open={wizardOpen} onOpenChange={setWizardOpen}>
        <DialogContent className="max-w-xl">
          <DialogHeader>
            <DialogTitle>Add cards</DialogTitle>
            <DialogDescription>
              Choose what your dashboard shows. Toggle a card to add or remove it.
            </DialogDescription>
          </DialogHeader>
          <ul className="grid max-h-[60vh] gap-2 overflow-y-auto sm:grid-cols-2">
            {CARD_DEFS.map((def) => {
              const placed = props.placedIds.has(def.id);
              const Icon = def.icon;
              return (
                <li key={def.id}>
                  <button
                    type="button"
                    onClick={() => (placed ? props.removeCard(def.id) : props.addCard(def.id))}
                    aria-pressed={placed}
                    className="flex w-full items-start gap-token-3 rounded-md p-token-3 text-left transition-colors hover:bg-mercury-wash"
                    style={{
                      border: placed
                        ? "1px solid var(--accent)"
                        : "1px solid var(--color-glass-line)",
                    }}
                  >
                    <span className="mt-0.5 text-content-mute">
                      <Icon size={18} aria-hidden />
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="flex items-center gap-2 font-display text-sm text-content-bright">
                        {def.title}
                        {placed && (
                          <Check size={14} aria-hidden className="text-[color:var(--accent-deep)]" />
                        )}
                      </span>
                      <span className="mt-0.5 block text-xs text-content-mute">{def.blurb}</span>
                    </span>
                  </button>
                </li>
              );
            })}
          </ul>
        </DialogContent>
      </Dialog>

      {/* Appearance: backdrop kernel + frost */}
      <Dialog open={appearanceOpen} onOpenChange={setAppearanceOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Appearance</DialogTitle>
            <DialogDescription>
              The living backdrop behind your glass cards.
            </DialogDescription>
          </DialogHeader>

          <div>
            <span className="eyebrow">Backdrop</span>
            <div className="mt-2 grid grid-cols-2 gap-2">
              {KERNEL_SPECS.map((spec) => {
                const active = props.kernelId === spec.id;
                return (
                  <button
                    key={spec.id}
                    type="button"
                    onClick={() => props.setKernel(spec.id)}
                    aria-pressed={active}
                    className="flex items-center gap-token-2 rounded-md p-token-2 text-left text-sm transition-colors hover:bg-mercury-wash"
                    style={{
                      border: active ? "1px solid var(--accent)" : "1px solid var(--color-glass-line)",
                    }}
                  >
                    <span
                      aria-hidden
                      className="size-6 shrink-0 rounded-md"
                      style={{
                        background: `linear-gradient(135deg, ${spec.palette.accents[1]}, ${spec.palette.accents[2]} 60%, ${spec.palette.accents[3]})`,
                      }}
                    />
                    <span className="truncate text-content-base">{spec.label}</span>
                  </button>
                );
              })}
            </div>
          </div>

          <div className="mt-token-2">
            <label htmlFor="lg-frost" className="eyebrow">
              Frost — {Math.round(props.frost * 100)}% clear
            </label>
            <input
              id="lg-frost"
              type="range"
              min={0}
              max={1}
              step={0.01}
              value={props.frost}
              onChange={(e) => props.setFrost(Number(e.target.value))}
              className="mt-2 w-full accent-[color:var(--accent)]"
            />
          </div>

          <div className="mt-token-2 flex justify-end">
            <Button variant="ghost" size="sm" onClick={props.reset}>
              <RotateCcw aria-hidden /> Reset dashboard
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function FreshnessLabel({
  source,
  computedAt,
  loading,
}: {
  source: "live" | "empty";
  computedAt: string | null;
  loading: boolean;
}) {
  // Recompute the relative label on a 30s tick (client-only).
  const [now, setNow] = React.useState<number | null>(null);
  React.useEffect(() => {
    setNow(Date.now());
    const id = window.setInterval(() => setNow(Date.now()), 30_000);
    return () => window.clearInterval(id);
  }, []);

  let text: string;
  if (loading) text = "Loading…";
  else if (source === "empty") text = "No usage synced yet";
  else if (computedAt && now != null) text = `Updated ${relativeTime(computedAt, now)}`;
  else text = "Live";

  return (
    <span
      className="font-mono text-[0.62rem] uppercase tracking-[0.14em] text-content-dim"
      title={computedAt ?? undefined}
    >
      {text}
    </span>
  );
}
