"use client";

import * as React from "react";
import { Check, Pencil, Plus, RotateCcw, Sparkles } from "lucide-react";

import { KERNEL_SPECS, type KernelId } from "@/lib/gl/kernels";
import type { DashboardRange, DashboardSource } from "@/lib/dashboard/types";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { CARD_DEFS } from "./cardRegistry";
import { DemoBadge } from "./cards/primitives";

const RANGES: { id: DashboardRange; label: string }[] = [
  { id: "today", label: "Today" },
  { id: "7d", label: "7d" },
  { id: "30d", label: "30d" },
];

export interface DashboardToolbarProps {
  range: DashboardRange;
  setRange: (r: DashboardRange) => void;
  source: DashboardSource;
  placedIds: ReadonlySet<string>;
  addCard: (id: import("./cardRegistry").CardId) => void;
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
      {/* Range segmented control */}
      <div
        className="flex items-center gap-0.5 rounded-pill p-0.5"
        style={{ border: "1px solid var(--color-glass-line)" }}
        role="group"
        aria-label="Time range"
      >
        {RANGES.map((r) => {
          const active = props.range === r.id;
          return (
            <button
              key={r.id}
              type="button"
              onClick={() => props.setRange(r.id)}
              aria-pressed={active}
              className="rounded-pill px-3 py-1 text-xs font-medium transition-colors"
              style={{
                color: active ? "#fff" : "var(--color-text-mute)",
                background: active ? "var(--accent)" : "transparent",
              }}
            >
              {r.label}
            </button>
          );
        })}
      </div>

      <div className="flex-1" />

      {props.source === "mock" && <DemoBadge />}

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
