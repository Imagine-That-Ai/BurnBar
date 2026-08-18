"use client";

import * as React from "react";

import { detectGlCapabilities, NO_FLOAT_CAPS } from "@/lib/gl/engine/gl/glCapabilities";
import { resolvePalette, toCss } from "@/lib/gl/engine/palette";
import { getKernelDescriptor } from "@/lib/gl/engine/registry";
import type { Kernel, KernelFrameContext, KernelId } from "@/lib/gl/engine/types";

/**
 * A self-contained live kernel canvas. Renders one kernel via the engine's
 * low-level factory (NOT the full BackdropEngine — no window-global input).
 *
 * When `gateVisibility` is set, the GPU context + rAF loop exist ONLY while the
 * element is on screen (IntersectionObserver), so a 30-tile grid never exceeds
 * the browser's live-context cap. The canvas ELEMENT is unmounted on scroll-away
 * (not just loseContext()'d): browsers keep counting a lost context against the
 * cap until the canvas is garbage-collected, and `getContext` on a lost canvas
 * returns the same dead context forever — so a reused canvas means scrolled-past
 * tiles would never render again (white tiles). A fresh element per live period
 * gets a fresh, valid context — the same pattern BackdropEngine uses per slot.
 *
 * A failed context degrades to a gradient instead of breaking.
 */
const FROZEN_MS = 2400;

export function LiveKernelCanvas({
  id,
  gateVisibility = true,
  // 1.2 matches BackdropEngine's WebGL2 cap — 1.25 was 8% more pixels for a
  // difference below perception on these soft procedural fields.
  dprCap = 1.2,
  className,
  style,
}: {
  id: KernelId;
  gateVisibility?: boolean;
  dprCap?: number;
  className?: string;
  style?: React.CSSProperties;
}) {
  const wrapRef = React.useRef<HTMLDivElement>(null);
  const canvasRef = React.useRef<HTMLCanvasElement>(null);
  const [live, setLive] = React.useState(false);
  const [failed, setFailed] = React.useState(false);

  // Visibility gate: the canvas element only exists while `live` is true.
  React.useEffect(() => {
    setFailed(false);
    if (!gateVisibility) {
      setLive(true);
      return;
    }
    const wrap = wrapRef.current;
    if (!wrap) return;
    const io = new IntersectionObserver(
      (entries) => setLive(!!entries[0]?.isIntersecting),
      { rootMargin: "150px" },
    );
    io.observe(wrap);
    return () => {
      io.disconnect();
      setLive(false);
    };
  }, [id, gateVisibility]);

  // GL/2D lifecycle: runs only while live, against the freshly-mounted canvas.
  React.useEffect(() => {
    if (!live) return;
    const wrap = wrapRef.current;
    const canvas = canvasRef.current;
    if (!wrap || !canvas) return;

    const reduced =
      typeof window !== "undefined" &&
      window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    const palette = resolvePalette("dark");
    const desc = getKernelDescriptor(id);

    let kernel: Kernel | null = null;
    let glOrCtx: WebGL2RenderingContext | CanvasRenderingContext2D | null = null;
    let caps = NO_FLOAT_CAPS;
    let raf = 0;
    let t0 = 0;

    const dpr = Math.min(
      typeof window !== "undefined" ? window.devicePixelRatio || 1 : 1,
      dprCap,
    );

    const sizeCanvas = () => {
      const r = wrap.getBoundingClientRect();
      const w = Math.max(1, Math.round(r.width * dpr));
      const h = Math.max(1, Math.round(r.height * dpr));
      if (canvas.width !== w) canvas.width = w;
      if (canvas.height !== h) canvas.height = h;
    };

    const frameCtx = (): KernelFrameContext => {
      const r = wrap.getBoundingClientRect();
      return {
        width: r.width,
        height: r.height,
        dpr,
        theme: "dark",
        palette,
        reducedMotion: !!reduced,
        caps,
      };
    };

    try {
      kernel = desc.create();
      if (desc.substrate === "webgl2") {
        const gl = canvas.getContext("webgl2", {
          alpha: false,
          antialias: false,
          depth: false,
          stencil: false,
          premultipliedAlpha: true,
          powerPreference: "low-power",
          preserveDrawingBuffer: false,
        });
        if (!gl) {
          setFailed(true);
          kernel = null;
          return;
        }
        glOrCtx = gl;
        caps = detectGlCapabilities(gl);
      } else {
        const c2d = canvas.getContext("2d", { alpha: true });
        if (!c2d) {
          setFailed(true);
          kernel = null;
          return;
        }
        glOrCtx = c2d;
      }
      sizeCanvas();
      kernel.init(glOrCtx, frameCtx());
      if (reduced) {
        kernel.frame(FROZEN_MS, 16);
      } else {
        const loop = (now: number) => {
          if (!t0) t0 = now;
          kernel?.frame(now - t0, 16);
          raf = requestAnimationFrame(loop);
        };
        raf = requestAnimationFrame(loop);
      }
    } catch {
      setFailed(true);
      kernel = null;
    }

    let resizeTimer: number | undefined;
    const onResize = () => {
      window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(() => {
        if (!kernel) return;
        sizeCanvas();
        kernel.resize(frameCtx());
        if (reduced) kernel.frame(FROZEN_MS, 16);
      }, 150);
    };
    window.addEventListener("resize", onResize);

    return () => {
      window.removeEventListener("resize", onResize);
      window.clearTimeout(resizeTimer);
      if (raf) cancelAnimationFrame(raf);
      try {
        kernel?.dispose();
      } catch {
        /* ignore */
      }
      // Free the context promptly; React then unmounts the canvas element, so
      // the browser can actually reclaim the slot (a lost context on a mounted
      // canvas keeps counting against the live-context cap).
      if (glOrCtx && "getExtension" in glOrCtx) {
        try {
          (glOrCtx as WebGL2RenderingContext).getExtension("WEBGL_lose_context")?.loseContext();
        } catch {
          /* ignore */
        }
      }
      kernel = null;
      glOrCtx = null;
    };
  }, [live, id, dprCap]);

  const base = toCss(resolvePalette("dark").bg);

  return (
    <div ref={wrapRef} className={className} style={{ background: base, ...style }}>
      {live && (
        <canvas
          ref={canvasRef}
          aria-hidden
          style={{ position: "absolute", inset: 0, width: "100%", height: "100%", display: "block" }}
        />
      )}
      {failed && (
        <div
          aria-hidden
          style={{
            position: "absolute",
            inset: 0,
            background: `radial-gradient(120% 120% at 30% 20%, ${toCss(resolvePalette("dark").accents[1])}, ${base} 70%)`,
          }}
        />
      )}
    </div>
  );
}
