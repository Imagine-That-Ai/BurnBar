/**
 * Flow Field kernel — "Luminous Silk".
 *
 * Thousands of fine tracers advected by a divergence-free curl-noise wind,
 * drawn as glass-smooth quadratic silk strands. The whole field breathes on a
 * slow ~14s lung (gathers + brightens on the inhale, releases + thins on the
 * exhale), a single bright light-bead visibly runs the length of every strand
 * from birth to death (phase-offset per strand → a standing wave of light), and
 * two decorrelated depth strata give parallax. Canvas2D, trail-wash composited.
 *
 * Reactive layers (all PRESERVED, layered multiplicatively on top of the breath
 * so a scroll reads as a forced gust over natural breathing):
 *  - Pointer: a soft tangential swirl around the cursor (bow wave).
 *  - Scroll:  scroll position scrubs the wind's time axis; scroll velocity
 *             drives a vertical gust, lateral shear, speed boost, line-width
 *             pulse, brightness bloom, and accelerated accent cycling.
 */

import { curl2 } from "../noise/simplex";
import { toCss, mixRgb } from "../palette";
import type {
  Kernel,
  KernelFrameContext,
  KernelPalette,
  KernelRenderingContext,
  RGB,
  ThemeName,
} from "../types";

// ── Wind field tuning ────────────────────────────────────────────────────
const FIELD_SCALE = 0.0016; // spatial frequency of the wind
const TIME_SCALE = 0.00006; // how fast the wind reorganizes (per ms)
const SPEED = 1.35; // px per ~16ms at unit curl

// ── Breath LFO — the slow lung the whole field rides ─────────────────────
// Irrational 14s/31s ratio so it never visibly loops.
const BREATH_A = 14000;
const BREATH_B = 31000;
function breathAt(tMs: number): number {
  return (
    0.5 +
    0.5 *
      (0.62 * Math.sin((2 * Math.PI * tMs) / BREATH_A) +
        0.38 * Math.sin((2 * Math.PI * tMs) / BREATH_B + 1.3))
  );
}

const NEAR_WHITE: RGB = [248, 250, 255];

// ── Pointer swirl ─────────────────────────────────────────────────────────
const POINTER = {
  R: 280, // influence radius (css px)
  STRENGTH: 2.4, // peak tangential velocity added at cursor
  FALLOFF: 1.4, // exponent; higher = tighter, softer edge
};

// ── Scroll reactivity ─────────────────────────────────────────────────────
const SCROLL = {
  TIME_SCRUB: 9, // scroll-position multiplier on the wind time axis
  GUST: 3.6, // max vertical velocity injected in the scroll direction
  GUST_K: 26, // velocity divisor before clamping (lower = punchier gust)
  SPEED_BOOST: 1.6, // max tracer speed multiplier while scrolling
  LINE_WIDTH: 1.9, // max added line width while scrolling (px)
  ALPHA_BOOST: 0.5, // max alpha added while scrolling (glow)
  ACCENT_ACCEL: 2.2, // how much scroll velocity accelerates color cycling
  SHEAR: 0.9, // max horizontal velocity injected while scrolling
  COLOR_SHIFT_PX: 220, // scroll px per accent-ramp step
};

function smoothstep01(x: number, a: number, b: number): number {
  const t = Math.min(Math.max((x - a) / (b - a), 0), 1);
  return t * t * (3 - 2 * t);
}

interface Tracer {
  x: number;
  y: number;
  px: number;
  py: number;
  px2: number; // one extra history point → 3-point quadratic silk tail
  py2: number;
  age: number;
  life: number;
  accent: number;
  bright: number;
  seed: number; // bead phase offset (stable per index)
  layer: 0 | 1; // depth stratum
}

export function createFlowFieldKernel(): Kernel {
  let ctx: CanvasRenderingContext2D | null = null;
  let width = 0;
  let height = 0;
  let dpr = 1;
  let palette: KernelPalette | null = null;
  let reducedMotion = false;
  let tracers: Tracer[] = [];
  let pointer: { x: number; y: number; active: boolean } = { x: 0, y: 0, active: false };
  let scroll = { y: 0, vy: 0, yMax: 0 };
  let trailRgb: RGB = [7, 8, 15];

  function count(): number {
    const area = width * height;
    return Math.max(380, Math.min(1500, Math.round(area / 1100)));
  }

  function spawn(t: Tracer, randomAge: boolean, i: number): void {
    t.x = Math.random() * width;
    t.y = Math.random() * height;
    t.px = t.x;
    t.py = t.y;
    t.px2 = t.x; // collapse history so a fresh strand never streaks across screen
    t.py2 = t.y;
    t.life = 120 + Math.random() * 260;
    // Golden-ratio initial age distributes birth/death evenly → no clumpy flicker.
    t.age = randomAge ? ((i * 0.618034) % 1) * t.life : 0;
    t.accent = Math.floor(Math.random() * (palette?.accents.length ?? 4));
    t.bright = 0.6 + Math.random() * 0.4;
    // Stable-per-index bead phase + depth stratum (~40% back, ~60% front).
    t.seed = (i * 0.754877) % 1;
    t.layer = ((i * 0.381966) % 1) < 0.4 ? 0 : 1;
  }

  function build(): void {
    const n = count();
    tracers = new Array(n);
    for (let i = 0; i < n; i++) {
      const t: Tracer = {
        x: 0, y: 0, px: 0, py: 0, px2: 0, py2: 0,
        age: 0, life: 0, accent: 0, bright: 1, seed: 0, layer: 1,
      };
      spawn(t, true, i);
      tracers[i] = t;
    }
  }

  function applyTransform(): void {
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function paintBase(alpha: number): void {
    if (!ctx) return;
    ctx.fillStyle = toCss(trailRgb, alpha);
    ctx.fillRect(0, 0, width, height);
  }

  function syncPalette(p: KernelPalette): void {
    palette = p;
    trailRgb = p.bg;
  }

  function renderStaticFrame(): void {
    if (!ctx || !palette) return;
    paintBase(1);
    for (let step = 0; step < 30; step++) advance(step * 16, 16, false);
    advance(3500, 16, true); // frozen near-peak inhale for a rich still
  }

  /** One integration + optional draw step. */
  const v: [number, number] = [0, 0];
  function advance(tMs: number, dtMs: number, draw: boolean): void {
    if (!ctx || !palette) return;
    const dt = Math.min(dtMs, 32) / 16;

    // Breath couples field speed + time-scale; scroll scrub stays unscaled so
    // raking still reads.
    const b = breathAt(tMs);
    const speedMulBreath = 0.82 + 0.3 * b;
    const timeScaleBreath = 0.7 + 0.6 * b;
    const tz = tMs * TIME_SCALE * timeScaleBreath + scroll.y * TIME_SCALE * SCROLL.TIME_SCRUB;

    const accents = palette.accents;
    const ink = palette.ink;
    const light = palette.theme === "light";
    const beadIntensity = light ? 0.9 : 1.4;
    const baseAlpha = light ? 0.5 : 0.42;
    const intensity = palette.intensity;

    // Scroll energy is constant across tracers this frame.
    const sV = scroll.vy;
    const energy = Math.min(Math.abs(sV) / 120, 1);
    const bloom = draw ? energy : 0;
    const colorShift = scroll.y / SCROLL.COLOR_SHIFT_PX + sV * SCROLL.ACCENT_ACCEL * 0.01;
    const n = accents.length || 1;

    for (let i = 0; i < tracers.length; i++) {
      const tr = tracers[i]!;
      // Roll the 3-point history before integrating.
      tr.px2 = tr.px;
      tr.py2 = tr.py;
      tr.px = tr.x;
      tr.py = tr.y;

      // Two decorrelated depth strata: back = broad slow current, front = fine
      // fast eddies. Same noise-sample count, just different sample coords.
      const layerScale = tr.layer ? 1.55 : 0.7;
      const layerTz = tr.layer ? tz : tz * 0.47 + 90;
      curl2(tr.x * FIELD_SCALE * layerScale, tr.y * FIELD_SCALE * layerScale, layerTz, v);
      let vx = v[0];
      let vy = v[1];

      // Pointer swirl: tangential curl around the cursor (bow wave).
      if (pointer.active) {
        const dx = tr.x - pointer.x;
        const dy = tr.y - pointer.y;
        const d2 = dx * dx + dy * dy;
        if (d2 < POINTER.R * POINTER.R) {
          const d = Math.sqrt(d2) || 1;
          const f = Math.pow((POINTER.R - d) / POINTER.R, POINTER.FALLOFF);
          vx += (-dy / d) * f * POINTER.STRENGTH;
          vy += (dx / d) * f * POINTER.STRENGTH;
        }
      }

      // Scroll reactions layered on top of the breath.
      const speedMul = 1 + energy * SCROLL.SPEED_BOOST;
      if (sV !== 0) {
        const dir = Math.sign(sV);
        vy += dir * Math.min(Math.abs(sV) / SCROLL.GUST_K, SCROLL.GUST);
        vx += dir * energy * SCROLL.SHEAR;
      }

      tr.x += vx * SPEED * speedMul * speedMulBreath * dt;
      tr.y += vy * SPEED * speedMul * speedMulBreath * dt;
      tr.age += dt * 16;

      const off = tr.x < -4 || tr.x > width + 4 || tr.y < -4 || tr.y > height + 4;
      if (off || tr.age > tr.life) {
        spawn(tr, false, i);
        continue;
      }

      if (draw) {
        const lifeT = tr.age / tr.life;
        // Asymmetric envelope: flare in fast, linger, soft fade out.
        const fade =
          smoothstep01(lifeT, 0, 0.12) *
          (0.4 +
            0.6 * (0.5 + 0.5 * Math.cos(Math.min(Math.max((lifeT - 0.6) / 0.4, 0), 1) * Math.PI)));

        // Traveling light-bead: a bright window crosses each strand, offset per
        // strand by its seed → a standing wave of light through the field.
        const beadPhase = ((lifeT + tr.seed) % 1) - 0.5;
        const bead = Math.exp(-(beadPhase * beadPhase) / 0.018);
        const glow = bead * beadIntensity;
        const glowC = Math.min(glow, 1);

        const accentIdx = (((Math.trunc(tr.accent + colorShift) % n) + n) % n);
        const base = accents[accentIdx] ?? ink;
        let rgb = light ? mixRgb(base, ink, 0.25) : base;
        // Bead lerps toward near-white on dark (a hot point) / toward ink on
        // light (a dark luminous node — white would vanish on pearl).
        if (glowC > 0.01) rgb = mixRgb(rgb, light ? ink : NEAR_WHITE, (light ? 0.4 : 0.45) * glowC);

        const alpha =
          (baseAlpha + bloom * SCROLL.ALPHA_BOOST) *
          fade *
          tr.bright *
          intensity *
          (tr.layer ? 1 : 0.7) * // back stratum dimmer
          (1 + glow);

        ctx.lineWidth = (tr.layer ? 1 : 1.3) * (1.15 + bloom * SCROLL.LINE_WIDTH);
        ctx.strokeStyle = toCss(rgb, Math.min(alpha, 1));
        ctx.beginPath();
        ctx.moveTo((tr.px2 + tr.px) / 2, (tr.py2 + tr.py) / 2);
        ctx.quadraticCurveTo(tr.px, tr.py, (tr.px + tr.x) / 2, (tr.py + tr.y) / 2);
        ctx.stroke();
      }
    }
  }

  return {
    id: "flow",
    label: "Flow Field",
    substrate: "2d",

    init(rc: KernelRenderingContext, frame: KernelFrameContext) {
      ctx = rc as CanvasRenderingContext2D;
      width = frame.width;
      height = frame.height;
      dpr = frame.dpr;
      reducedMotion = frame.reducedMotion;
      syncPalette(frame.palette);
      applyTransform();
      ctx.lineCap = "round";
      paintBase(1);
      build();
      if (reducedMotion) renderStaticFrame();
    },

    frame(tMs: number, dtMs: number) {
      if (!ctx) return;
      const b = breathAt(tMs);
      const light = palette?.theme === "light";
      // Trails persist longer at peak inhale → the field gathers density.
      paintBase(light ? 0.1 - 0.02 * b : 0.095 - 0.03 * b);
      advance(tMs, dtMs, true);
    },

    resize(frame: KernelFrameContext) {
      width = frame.width;
      height = frame.height;
      dpr = frame.dpr;
      applyTransform();
      ctx!.lineCap = "round";
      paintBase(1);
      build();
      if (reducedMotion) renderStaticFrame();
    },

    setTheme(_theme: ThemeName, next: KernelPalette) {
      syncPalette(next);
      paintBase(1);
    },

    pointer(x: number, y: number, active: boolean) {
      pointer = { x, y, active };
    },

    scroll(y: number, vy: number, yMax: number) {
      scroll = { y, vy, yMax };
    },

    renderStatic() {
      renderStaticFrame();
    },

    dispose() {
      ctx = null;
      tracers = [];
    },
  };
}
