"use client";

import * as React from "react";

import { createKernelRenderer, type KernelRenderer } from "@/lib/gl/createKernelRenderer";
import { getKernelSpec, type KernelId } from "@/lib/gl/kernels";

/**
 * The dashboard's deep backdrop: a full-viewport WebGL2 kernel rendered behind
 * the page's global 2D provider swarm (DotCrestField, z-index -1) and all
 * content. Mounted only on the dashboard route.
 *
 * Lifecycle mirrors DotCrestField's proven shape: DPR-aware sizing, a single
 * rAF loop, debounced resize, prefers-reduced-motion (one settled frame, no
 * loop), pause-when-hidden, and full teardown. If WebGL2 is unavailable it
 * renders a static gradient in the active kernel's base color so the glass
 * cards still float over a dark field.
 */

const FROZEN_FRAME_SECONDS = 7.5; // a pleasing settled moment for reduced-motion

export function KernelBackdrop({ kernelId }: { kernelId: KernelId }) {
  const canvasRef = React.useRef<HTMLCanvasElement>(null);
  const rendererRef = React.useRef<KernelRenderer | null>(null);
  const [unsupported, setUnsupported] = React.useState(false);

  // Create renderer + drive the loop. Runs once; kernel switches are applied
  // via the separate effect below so we never tear down the GL context.
  React.useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const renderer = createKernelRenderer(canvas, kernelId);
    if (!renderer) {
      setUnsupported(true);
      return;
    }
    rendererRef.current = renderer;
    setUnsupported(false);

    const motionQuery =
      typeof window !== "undefined" && window.matchMedia
        ? window.matchMedia("(prefers-reduced-motion: reduce)")
        : null;
    let reduced = motionQuery?.matches ?? false;

    const resize = () => renderer.resize(window.innerWidth, window.innerHeight);
    resize();

    let raf = 0;
    let start = 0; // frame-clock anchor of the current run
    let elapsed = 0; // animation seconds banked across pauses
    let lastT = 0; // last rendered time (also used to redraw frozen frames)
    let paused = false;

    const frame = (now: number) => {
      if (!start) start = now;
      lastT = elapsed + (now - start) / 1000;
      renderer.render(lastT);
      raf = requestAnimationFrame(frame);
    };
    const startLoop = () => {
      start = 0; // re-anchored on the next frame; `elapsed` carries continuity
      raf = requestAnimationFrame(frame);
    };
    const drawFrozen = () => {
      lastT = FROZEN_FRAME_SECONDS;
      renderer.render(FROZEN_FRAME_SECONDS);
    };

    if (reduced) drawFrozen();
    else startLoop();

    let resizeTimer: number | undefined;
    const onResize = () => {
      window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(() => {
        resize();
        if (reduced) drawFrozen();
      }, 150);
    };

    const onPointerMove = (e: PointerEvent) => {
      renderer.setPointer(e.clientX / window.innerWidth, e.clientY / window.innerHeight);
    };
    // relatedTarget is null only when the pointer genuinely left the window —
    // `pointerout` otherwise fires on every element boundary crossing.
    const onPointerOut = (e: PointerEvent) => {
      if (!e.relatedTarget) renderer.clearPointer();
    };

    const onVisibility = () => {
      if (reduced) return;
      if (document.hidden && !paused) {
        paused = true;
        elapsed = lastT; // bank elapsed time so resume continues smoothly
        cancelAnimationFrame(raf);
      } else if (!document.hidden && paused) {
        paused = false;
        startLoop();
      }
    };

    // The OS reduced-motion setting can change while mounted.
    const onMotionChange = (e: MediaQueryListEvent) => {
      reduced = e.matches;
      if (reduced) {
        cancelAnimationFrame(raf);
        paused = false;
        drawFrozen();
      } else if (!paused) {
        elapsed = lastT;
        startLoop();
      }
    };

    // In reduced-motion there is no loop, so a GPU context restore would leave a
    // blank field — redraw the settled frame once the renderer has rebuilt.
    const onContextRestored = () => {
      if (!reduced) return;
      window.setTimeout(() => {
        resize();
        drawFrozen();
      }, 0);
    };

    window.addEventListener("resize", onResize);
    window.addEventListener("pointermove", onPointerMove, { passive: true });
    window.addEventListener("pointerout", onPointerOut);
    document.addEventListener("visibilitychange", onVisibility);
    motionQuery?.addEventListener?.("change", onMotionChange);
    canvas.addEventListener("webglcontextrestored", onContextRestored, false);

    return () => {
      cancelAnimationFrame(raf);
      window.clearTimeout(resizeTimer);
      window.removeEventListener("resize", onResize);
      window.removeEventListener("pointermove", onPointerMove);
      window.removeEventListener("pointerout", onPointerOut);
      document.removeEventListener("visibilitychange", onVisibility);
      motionQuery?.removeEventListener?.("change", onMotionChange);
      canvas.removeEventListener("webglcontextrestored", onContextRestored, false);
      renderer.dispose();
      rendererRef.current = null;
    };
    // Renderer is created once; kernel switches are handled by the effect below.
  }, []);

  // Apply kernel switches without recreating the context.
  React.useEffect(() => {
    rendererRef.current?.setKernel(kernelId);
  }, [kernelId]);

  if (unsupported) {
    const base = getKernelSpec(kernelId).palette.base;
    return (
      <div
        aria-hidden
        style={{
          position: "fixed",
          inset: 0,
          zIndex: -2,
          pointerEvents: "none",
          background: `radial-gradient(120% 120% at 50% 0%, ${base} 0%, #04060b 100%)`,
        }}
      />
    );
  }

  return (
    <canvas
      ref={canvasRef}
      aria-hidden
      style={{
        position: "fixed",
        inset: 0,
        width: "100%",
        height: "100%",
        zIndex: -2,
        pointerEvents: "none",
        display: "block",
      }}
    />
  );
}
