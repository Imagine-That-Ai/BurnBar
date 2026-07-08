/**
 * Constellation kernel — a slow, beautiful NEBULA sky.
 *
 * Replaces the earlier dense star-swarm (which competed with the foreground
 * glyphs) with soft, slowly-drifting nebula clouds: a handful of large,
 * low-opacity radial gradients in the accent palette that breathe and drift,
 * over a sparse scatter of faint distant stars. The foreground brand glyphs
 * (drawn by GlyphStage) now read cleanly against it.
 *
 * No SwarmSim, no logo actors — the foreground layer owns all glyph summoning.
 * Pointer + wake still part the nebula gently; click blooms a soft ripple.
 */

import { mixRgb, toCss } from "../palette";
import type {
  Kernel,
  KernelFrameContext,
  KernelPalette,
  KernelRenderingContext,
  RGB,
  ThemeName,
} from "../types";

const TAU = Math.PI * 2;

interface NebulaCloud {
  /** normalized home position [0,1]² */
  hx: number;
  hy: number;
  /** slow drift velocity (normalized units / second) */
  vx: number;
  vy: number;
  /** radius in CSS px (scaled by viewport at render) */
  r: number;
  /** palette accent index this cloud draws from */
  accent: number;
  /** phase offset for the breathing pulse */
  phase: number;
  /** per-cloud opacity scale (so siblings differ in weight) */
  weight: number;
}

interface Star {
  /** normalized position [0,1]² */
  nx: number;
  ny: number;
  /** base radius px */
  r: number;
  /** twinkle phase */
  phase: number;
  /** twinkle rate */
  rate: number;
  /** accent ramp index */
  accent: number;
  /** base alpha */
  a: number;
}

interface PointerState {
  x: number;
  y: number;
  active: boolean;
}

/** how the nebula's soft clouds map to the cohesive accent ramp. */
function cloudColor(p: KernelPalette, idx: number): RGB {
  const ramp = p.accents;
  return ramp[idx % ramp.length]!;
}

export function createConstellationKernel(): Kernel {
  let ctx: CanvasRenderingContext2D | null = null;
  let width = 0;
  let height = 0;
  let dpr = 1;
  let palette: KernelPalette | null = null;
  let reducedMotion = false;

  // drifting nebula clouds (kept small in count — quality over density).
  let clouds: NebulaCloud[] = [];
  // a sparse field of distant stars (the "nebula's dust"), much fainter than the
  // old swarm so it never competes with the foreground glyphs.
  let stars: Star[] = [];

  const pointer: PointerState = { x: 0, y: 0, active: false };
  let tNow = 0; // seconds since init

  function applyTransform(): void {
    if (ctx) ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  /** Cloud count + radius scale with viewport, but stay restrained. */
  function budget(): { clouds: number; stars: number } {
    const area = width * height;
    // ~3–6 nebula clouds across the whole viewport — soft, sparse, calm.
    const nc = Math.max(3, Math.min(6, Math.round(area / 380000)));
    // a fine, faint dusting — far fewer than the old 1400–3400 swarm.
    const ns = Math.max(60, Math.min(160, Math.round(area / 9000)));
    return { clouds: nc, stars: ns };
  }

  function rebuildField(): void {
    const b = budget();
    clouds = [];
    for (let i = 0; i < b.clouds; i++) {
      const r = (Math.min(width, height) * 0.32) * (0.7 + Math.random() * 0.55);
      clouds.push({
        hx: Math.random(),
        hy: Math.random(),
        vx: (Math.random() - 0.5) * 0.004, // very slow drift
        vy: (Math.random() - 0.5) * 0.003,
        r,
        accent: i % 4,
        phase: Math.random() * TAU,
        weight: 0.6 + Math.random() * 0.5,
      });
    }
    stars = [];
    for (let i = 0; i < b.stars; i++) {
      stars.push({
        nx: Math.random(),
        ny: Math.random(),
        r: 0.5 + Math.random() * 1.1,
        phase: Math.random() * TAU,
        rate: 0.4 + Math.random() * 1.2,
        accent: Math.floor(Math.random() * 4),
        a: 0.18 + Math.random() * 0.32,
      });
    }
  }

  function paintBase(alpha: number): void {
    if (!ctx || !palette) return;
    ctx.globalCompositeOperation = "source-over";
    ctx.fillStyle = toCss(palette.bg, alpha);
    ctx.fillRect(0, 0, width, height);
  }

  /**
   * A soft radial nebula bloom at (x,y): a low-opacity accent gradient, blended
   * additively on dark / source-over on light, scaled by the breathing pulse.
   */
  function drawCloud(c: NebulaCloud, x: number, y: number, pulse: number): void {
    if (!ctx || !palette) return;
    const light = palette.theme === "light";
    const col = cloudColor(palette, c.accent);
    // breathing radius/opacity so each cloud swells + fades on its own phase.
    const r = c.r * (0.9 + 0.12 * pulse);
    const baseA = (light ? 0.10 : 0.14) * c.weight * (0.7 + 0.3 * pulse) * palette.intensity;
    const grad = ctx.createRadialGradient(x, y, 0, x, y, r);
    // dark mode: brighter core that falls off; light mode: a tinted wash.
    const core = light ? mixRgb(col, palette.bg, 0.35) : col;
    grad.addColorStop(0, toCss(core, baseA));
    grad.addColorStop(0.55, toCss(col, baseA * 0.45));
    grad.addColorStop(1, toCss(col, 0));
    ctx.globalCompositeOperation = light ? "source-over" : "lighter";
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.arc(x, y, r, 0, TAU);
    ctx.fill();
  }

  function drawStar(s: Star, pulse: number): void {
    if (!ctx || !palette) return;
    const light = palette.theme === "light";
    const col = cloudColor(palette, s.accent);
    const tw = 0.55 + 0.45 * pulse; // twinkle
    const a = s.a * tw * palette.intensity;
    const x = s.nx * width;
    const y = s.ny * height;
    const r = s.r * tw;
    if (light) {
      // light canvas: tiny ink-tinted pinpricks, no glow halo (keeps it calm).
      ctx.globalCompositeOperation = "source-over";
      ctx.fillStyle = toCss(mixRgb(col, palette.ink, 0.5), a * 0.7);
      ctx.beginPath();
      ctx.arc(x, y, r, 0, TAU);
      ctx.fill();
      return;
    }
    // dark canvas: additive faint core + soft halo so a star reads as light.
    ctx.globalCompositeOperation = "lighter";
    if (r > 1.0) {
      const halo = ctx.createRadialGradient(x, y, 0, x, y, r * 3.2);
      halo.addColorStop(0, toCss(col, a * 0.5));
      halo.addColorStop(1, toCss(col, 0));
      ctx.fillStyle = halo;
      ctx.beginPath();
      ctx.arc(x, y, r * 3.2, 0, TAU);
      ctx.fill();
    }
    ctx.fillStyle = toCss(mixRgb(col, [255, 255, 255], 0.45), a);
    ctx.beginPath();
    ctx.arc(x, y, r, 0, TAU);
    ctx.fill();
  }

  function render(): void {
    if (!ctx || !palette) return;
    const light = palette.theme === "light";
    // faint trail wash so the nebula persists a touch + the field gathers softly.
    paintBase(light ? 0.32 : 0.26);
    // nebula clouds: drift slowly, wrap at the edges, breathe.
    for (const c of clouds) {
      const pulse = 0.5 + 0.5 * Math.sin(tNow * 0.18 + c.phase);
      let x = c.hx * width;
      let y = c.hy * height;
      // pointer/wake nudges the nearest clouds gently (a soft parting).
      if (pointer.active) {
        const dx = x - pointer.x;
        const dy = y - pointer.y;
        const d = Math.hypot(dx, dy);
        const reach = Math.min(width, height) * 0.45;
        if (d < reach) {
          const k = (1 - d / reach) * 14;
          x += (dx / (d || 1)) * k;
          y += (dy / (d || 1)) * k;
        }
      }
      drawCloud(c, x, y, pulse);
    }
    // distant stars: twinkle on independent phases, far fainter than the old swarm.
    for (const s of stars) {
      const pulse = 0.5 + 0.5 * Math.sin(tNow * s.rate + s.phase);
      drawStar(s, pulse);
    }
    ctx.globalCompositeOperation = "source-over";
  }

  function renderStaticFrame(): void {
    // a single calm, fully-painted frame (no drift), so reduced-motion still
    // reads as a beautiful static nebula.
    if (!ctx || !palette) return;
    paintBase(1);
    for (const c of clouds) drawCloud(c, c.hx * width, c.hy * height, 0.6);
    for (const s of stars) drawStar(s, 0.7);
    ctx.globalCompositeOperation = "source-over";
  }

  return {
    id: "constellation",
    label: "Constellation",
    substrate: "2d",

    init(rc: KernelRenderingContext, frame: KernelFrameContext) {
      ctx = rc as CanvasRenderingContext2D;
      width = frame.width;
      height = frame.height;
      dpr = frame.dpr;
      palette = frame.palette;
      reducedMotion = frame.reducedMotion;
      applyTransform();
      rebuildField();
      paintBase(1);
      if (reducedMotion) renderStaticFrame();
    },

    frame(_tMs: number, dtMs: number) {
      if (!ctx || !palette) return;
      const dt = Math.min(dtMs, 32) / 1000;
      tNow += dt;
      // advance the slow cloud drift; wrap softly at the edges.
      for (const c of clouds) {
        c.hx += c.vx * dt * 60;
        c.hy += c.vy * dt * 60;
        if (c.hx > 1.15) c.hx = -0.15;
        if (c.hx < -0.15) c.hx = 1.15;
        if (c.hy > 1.15) c.hy = -0.15;
        if (c.hy < -0.15) c.hy = 1.15;
      }
      render();
    },

    resize(frame: KernelFrameContext) {
      width = frame.width;
      height = frame.height;
      dpr = frame.dpr;
      applyTransform();
      paintBase(1);
      rebuildField();
      if (reducedMotion) renderStaticFrame();
    },

    setTheme(_theme: ThemeName, next: KernelPalette) {
      palette = next;
      paintBase(1);
      if (reducedMotion) renderStaticFrame();
    },

    pointer(x: number, y: number, active: boolean) {
      pointer.x = x;
      pointer.y = y;
      pointer.active = active;
    },

    click(x: number, y: number) {
      // a soft ripple bloom at the cursor — a single expanding, fading accent
      // ring, gentle so it never competes with a spawned foreground glyph.
      if (!ctx || !palette) return;
      const col = palette.accents[0]!;
      ctx.globalCompositeOperation = palette.theme === "light" ? "source-over" : "lighter";
      const r0 = 8;
      const grad = ctx.createRadialGradient(x, y, r0, x, y, 90);
      grad.addColorStop(0, toCss(col, 0));
      grad.addColorStop(0.6, toCss(col, 0.12 * palette.intensity));
      grad.addColorStop(1, toCss(col, 0));
      ctx.fillStyle = grad;
      ctx.beginPath();
      ctx.arc(x, y, 90, 0, TAU);
      ctx.fill();
      ctx.globalCompositeOperation = "source-over";
    },

    wake(x: number, y: number, dx: number, dy: number, radius: number, _strength: number) {
      // a dragged glyph parts the nearest clouds: nudge the closest ones along
      // the drag vector, area-relative to the glyph's size. Soft, no burst.
      const reach = radius * 2.4;
      for (const c of clouds) {
        const cx = c.hx * width;
        const cy = c.hy * height;
        const d = Math.hypot(cx - x, cy - y);
        if (d < reach) {
          const k = (1 - d / reach) * 0.0009;
          c.vx += dx * k;
          c.vy += dy * k;
          // damp back toward a calm drift so the field settles.
          c.vx *= 0.985;
          c.vy *= 0.985;
        }
      }
    },

    obstacles(_rects: { x: number; y: number; w: number; h: number }[]) {
      // the nebula is a diffuse field; it doesn't flow around page geometry.
    },

    renderStatic() {
      renderStaticFrame();
    },

    dispose() {
      ctx = null;
      clouds = [];
      stars = [];
    },
  };
}
