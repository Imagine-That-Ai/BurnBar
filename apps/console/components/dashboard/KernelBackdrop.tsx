"use client";

import * as React from "react";

import { BackdropEngine } from "@/lib/gl/engine/BackdropEngine";
import { toCss } from "@/lib/gl/engine/palette";
import { housePalette } from "@/lib/gl/engine/palette";
import type { KernelId } from "@/lib/gl/engine/types";

/**
 * The deep backdrop: the vendored imaginethat-llc BackdropEngine rendering a
 * full-viewport animated kernel behind the page. Used by the dashboard's glass
 * cards AND, console-wide, by {@link GlobalBackdrop} behind the ink scrim.
 *
 * The engine (a framework-agnostic class) owns the entire runtime — per-slot
 * canvas creation, the rAF clock, DPR sizing, resize/visibility/pointer routing,
 * crossfade between kernels, prefers-reduced-motion, capability-gated fallback
 * (a WebGL2 kernel degrades to the 2D `constellation` when WebGL2 is absent, so
 * the field is never black), and teardown. This component just hands it a host
 * <div> on mount and forwards kernel switches.
 *
 * `onResolve` reports the kernel actually shown (post GL-fallback) so callers
 * (the ink layer) can publish the resolved id + its legibility ink.
 */

// A dark base behind the engine's canvases so the field is never white, even
// for the (vanishingly rare) no-canvas case. Matches the engine's dark bg.
const DARK_BASE = toCss(housePalette("dark").bg);

export function KernelBackdrop({
  kernelId,
  className,
  onResolve,
}: {
  kernelId: KernelId;
  className?: string;
  onResolve?: (id: KernelId) => void;
}) {
  const hostRef = React.useRef<HTMLDivElement>(null);
  const engineRef = React.useRef<BackdropEngine | null>(null);
  // Hold the latest onResolve so the engine (built once) always calls current.
  const onResolveRef = React.useRef(onResolve);
  onResolveRef.current = onResolve;

  // Construct the engine once (client-only — it touches window/document).
  React.useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const engine = new BackdropEngine(host, {
      theme: "dark",
      initialKernel: kernelId,
      onResolve: (id) => onResolveRef.current?.(id),
    });
    engineRef.current = engine;
    return () => {
      engine.destroy();
      engineRef.current = null;
    };
    // Mount once; kernel switches flow through the effect below.
  }, []);

  // Switch kernels without recreating the engine (engine crossfades internally).
  React.useEffect(() => {
    engineRef.current?.setKernel(kernelId);
  }, [kernelId]);

  return (
    <div
      ref={hostRef}
      aria-hidden
      className={className}
      style={{
        position: "fixed",
        inset: 0,
        zIndex: -2,
        pointerEvents: "none",
        background: DARK_BASE,
        overflow: "hidden",
      }}
    />
  );
}
