"use client";

import type { KernelId } from "@openburnbar/gl-engine/engine/types";
import { LiveKernelCanvas } from "./LiveKernelCanvas";

/**
 * A large live preview of the currently-selected backdrop kernel. Always live
 * while mounted (it sits at the top of the page, in view).
 */
export function KernelHero({
  id,
  label,
  blurb,
}: {
  id: KernelId;
  label: string;
  blurb: string;
}) {
  return (
    <div
      className="relative overflow-hidden rounded-lg"
      style={{ aspectRatio: "16 / 5", border: "1px solid var(--color-glass-line)" }}
    >
      <LiveKernelCanvas id={id} gateVisibility={false} dprCap={1.5} className="absolute inset-0" />
      <div className="pointer-events-none absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/70 to-transparent p-token-4">
        <div className="font-display text-lg text-white">{label}</div>
        <div className="mt-0.5 max-w-xl text-sm text-white/75">{blurb}</div>
      </div>
    </div>
  );
}
