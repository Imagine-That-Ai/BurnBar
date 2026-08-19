"use client";

import type { KernelId } from "@/lib/gl/engine/types";
import { LiveKernelCanvas } from "./LiveKernelCanvas";

/**
 * A clickable, selectable live kernel preview. Clicking sets it as the global
 * backdrop — the gallery's own page background becomes the selection instantly;
 * the active one is ringed + badged.
 */
export function KernelTile({
  id,
  label,
  blurb,
  active = false,
  onSelect,
}: {
  id: KernelId;
  label: string;
  blurb: string;
  active?: boolean;
  onSelect?: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      aria-pressed={active}
      aria-label={`Use ${label} as your backdrop`}
      className="group relative block overflow-hidden rounded-lg text-left outline-none transition-transform focus-visible:scale-[1.01]"
      style={{
        aspectRatio: "16 / 10",
        border: active ? "2px solid var(--accent)" : "1px solid var(--color-glass-line)",
        boxShadow: active ? "0 0 0 3px var(--accent-wash)" : undefined,
      }}
    >
      <LiveKernelCanvas id={id} gateVisibility className="absolute inset-0" />

      {active ? (
        <span
          className="absolute right-2 top-2 rounded-pill px-2 py-0.5 text-[0.62rem] font-semibold uppercase tracking-[0.1em] text-white"
          style={{ background: "var(--accent)" }}
        >
          ✓ Backdrop
        </span>
      ) : (
        <span className="absolute right-2 top-2 rounded-pill bg-black/55 px-2 py-0.5 text-[0.62rem] font-semibold uppercase tracking-[0.1em] text-white opacity-0 transition-opacity group-hover:opacity-100">
          Use →
        </span>
      )}

      <div className="pointer-events-none absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/70 to-transparent p-token-3">
        <div className="font-display text-sm text-white">{label}</div>
        <div className="mt-0.5 line-clamp-2 text-xs text-white/70">{blurb}</div>
      </div>
    </button>
  );
}
