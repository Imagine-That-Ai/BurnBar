/**
 * Boids kernel — "Boids".
 *
 * A living starling murmuration: a dense cloud of many small birds that flows
 * and folds as ONE organism. Three forces combine:
 *
 *  1. A slow curl-noise wind field (same idea as the flow-field kernel) gives
 *     the large-scale wheeling and folding — the sweeping sheets a real
 *     murmuration draws across the sky. Without a field, pure boids settle into
 *     a dull uniform drift; the field is what makes it *dance*.
 *  2. Classic Reynolds steering (separation + alignment + weak cohesion) over a
 *     uniform spatial grid gives the coherent, grainy flock texture — birds
 *     bank together and hold their spacing. Grid cell = perception radius, so
 *     neighbor cost is O(n·k), never O(n²).
 *  3. A soft boundary steers birds back inside a margin so the flock wheels and
 *     turns instead of leaving frame.
 *
 * The birds are deliberately near-monochrome — a whole-flock silvery tint that
 * drifts slowly through the palette accents over ~44s (NOT a per-bird rainbow,
 * which reads as confetti, not a flock). Each bird is a tiny velocity-aligned
 * streak at low alpha, so density does the work: where birds pack tight the
 * murmuration brightens into ribbons; where they thin it fades to sky.
 *
 * Reactive layers:
 *  - Breath: the shared 14s/31s lung swells top speed + wind on the inhale.
 *  - Pointer: a predator — birds within ~230px flee the cursor, opening a hole.
 *  - Scroll:  a vertical gust in the scroll direction plus a speed boost.
 */

import { curl2 } from "../noise/simplex";
import { toCss } from "../palette";
import type {
  Kernel,
  KernelFrameContext,
  KernelPalette,
  KernelRenderingContext,
  RGB,
  ThemeName,
} from "../types";

// ── Flock tuning ──────────────────────────────────────────────────────────
const NEIGHBOR_R = 78; // alignment/cohesion perception (css px) — also grid cell
const SEPARATION_R = 13; // personal-space radius (css px)
const MAX_NEIGHBORS = 16; // cap per-bird neighbor work → O(n·k) guaranteed
const BIRD_DIVISOR = 340; // one bird per ~340 px² of canvas
const BIRD_MIN = 520;
const BIRD_MAX = 1600;

// Steering weights (accel per ~16ms step). Alignment dominates → coherent flow
// without collapse; cohesion is deliberately faint so the flock never balls up.
const W_SEPARATION = 0.9;
const W_ALIGNMENT = 0.09;
const W_COHESION = 0.0006;
const W_WIND = 0.75; // how hard birds fall into the curl-field streamlines
const WANDER = 0.03; // tiny per-step jitter so the flock never crystallizes

// ── Curl-noise wind field — the large-scale wheel/fold ───────────────────
// Finer than the flow field so several swirl cells span the frame at once,
// spreading the murmuration into folding sheets across the whole sky rather
// than one corner vortex.
const WIND_SCALE = 0.0014; // spatial frequency (larger = more, smaller swirls)
const WIND_TIME = 0.00005; // how fast the field reorganizes (per ms)

// ── Motion envelope ───────────────────────────────────────────────────────
const SPEED = { MIN: 0.9, MAX: 2.35 }; // px per ~16ms; MAX is breath-modulated
const STEER_MAX = 0.3; // clamp on total steering accel per unit step

// ── Edges: steer away within a soft margin — no hard wrap. ───────────────
const EDGE = { MARGIN: 90, TURN: 0.16 };

// ── Breath LFO — the slow lung the whole flock rides (shared w/ flow field). ─
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

// ── Pointer = predator ────────────────────────────────────────────────────
const POINTER = { R: 230, STRENGTH: 0.6, FALLOFF: 1.25 };

// ── Scroll reactivity (mirrors the flow-field SCROLL idiom) ──────────────
const SCROLL = { GUST: 0.5, GUST_K: 70, SPEED_BOOST: 0.55 };

// Whole-flock tint cycles through the accent ramp once per ~44s.
const TINT_PERIOD = 44000;

interface Bird {
  x: number;
  y: number;
  vx: number;
  vy: number;
  bright: number; // per-bird brightness + length variation (subtle)
}

export function createBoidsKernel(): Kernel {
  let ctx: CanvasRenderingContext2D | null = null;
  let width = 0;
  let height = 0;
  let dpr = 1;
  let palette: KernelPalette | null = null;
  let reducedMotion = false;
  let birds: Bird[] = [];
  let pointer: { x: number; y: number; active: boolean } = { x: 0, y: 0, active: false };
  let scroll = { y: 0, vy: 0, yMax: 0 };
  let trailRgb: RGB = [7, 8, 15];

  // Uniform spatial grid: linked buckets in flat typed arrays (zero per-frame
  // allocation). `gridHead[cell]` → first bird index, `gridNext[i]` → chain.
  let cols = 1;
  let rows = 1;
  let gridHead = new Int32Array(1);
  let gridNext = new Int32Array(0);

  const wind: [number, number] = [0, 0];

  function count(): number {
    const area = width * height;
    return Math.max(BIRD_MIN, Math.min(BIRD_MAX, Math.round(area / BIRD_DIVISOR)));
  }

  function spawn(b: Bird): void {
    b.x = Math.random() * width;
    b.y = Math.random() * height;
    const ang = Math.random() * Math.PI * 2;
    const speed = SPEED.MIN + Math.random() * (SPEED.MAX - SPEED.MIN);
    b.vx = Math.cos(ang) * speed;
    b.vy = Math.sin(ang) * speed;
    b.bright = 0.5 + Math.random() * 0.5;
  }

  function build(): void {
    const n = count();
    birds = new Array(n);
    for (let i = 0; i < n; i++) {
      const b: Bird = { x: 0, y: 0, vx: 0, vy: 0, bright: 1 };
      spawn(b);
      birds[i] = b;
    }
    cols = Math.max(1, Math.ceil(width / NEIGHBOR_R));
    rows = Math.max(1, Math.ceil(height / NEIGHBOR_R));
    gridHead = new Int32Array(cols * rows);
    gridNext = new Int32Array(n);
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

  /** Whole-flock silvery tint: ink pulled a little toward the currently-active
   *  accent, which lerps slowly around the ramp. One tone for the entire flock. */
  function flockColor(tMs: number): RGB {
    const p = palette!;
    const accents = p.accents;
    const n = accents.length || 1;
    const phase = ((tMs / TINT_PERIOD) % 1) * n;
    const k = Math.floor(phase) % n;
    const f = phase - Math.floor(phase);
    const a = accents[k] ?? p.ink;
    const bnext = accents[(k + 1) % n] ?? p.ink;
    const accent: RGB = [
      a[0] + (bnext[0] - a[0]) * f,
      a[1] + (bnext[1] - a[1]) * f,
      a[2] + (bnext[2] - a[2]) * f,
    ];
    // mix(ink, accent, 0.3): in dark themes ink is near-white → silvery birds
    // against night sky; in light themes ink is near-black → dark birds on paper.
    const ink = p.ink;
    return [
      ink[0] + (accent[0] - ink[0]) * 0.3,
      ink[1] + (accent[1] - ink[1]) * 0.3,
      ink[2] + (accent[2] - ink[2]) * 0.3,
    ];
  }

  function renderStaticFrame(): void {
    if (!ctx || !palette) return;
    paintBase(1);
    // Let the flock organize into a real murmuration shape, then draw once.
    for (let step = 0; step < 90; step++) advance(step * 16, 16, false);
    advance(90 * 16, 16, true);
  }

  /** Rebuild the spatial grid for the current bird positions. */
  function fillGrid(): void {
    gridHead.fill(-1);
    for (let i = 0; i < birds.length; i++) {
      const b = birds[i]!;
      let cx = (b.x / NEIGHBOR_R) | 0;
      let cy = (b.y / NEIGHBOR_R) | 0;
      if (cx < 0) cx = 0;
      else if (cx >= cols) cx = cols - 1;
      if (cy < 0) cy = 0;
      else if (cy >= rows) cy = rows - 1;
      const cell = cy * cols + cx;
      gridNext[i] = gridHead[cell]!;
      gridHead[cell] = i;
    }
  }

  /** One integration + optional draw step. */
  function advance(tMs: number, dtMs: number, draw: boolean): void {
    if (!ctx || !palette) return;
    const dt = Math.min(dtMs, 32) / 16;

    // Breath swells top speed + wind on the inhale (flock gathers + quickens).
    const br = breathAt(tMs);
    const windW = W_WIND * (0.7 + 0.6 * br);
    const speedMulBreath = 0.9 + 0.2 * br;

    // Scroll energy is constant across birds this frame.
    const sV = scroll.vy;
    const energy = Math.min(Math.abs(sV) / 120, 1);
    const gust = sV !== 0 ? Math.sign(sV) * Math.min(Math.abs(sV) / SCROLL.GUST_K, SCROLL.GUST) : 0;
    const maxSpeed = SPEED.MAX * speedMulBreath * (1 + energy * SCROLL.SPEED_BOOST);
    const minSpeed = SPEED.MIN;

    const light = palette.theme === "light";
    const intensity = palette.intensity;
    const baseAlpha = light ? 0.44 : 0.46;
    const windTz = tMs * WIND_TIME;
    const r2 = NEIGHBOR_R * NEIGHBOR_R;
    const sep2 = SEPARATION_R * SEPARATION_R;

    let rgb: RGB = trailRgb;
    if (draw) {
      rgb = flockColor(tMs);
      ctx.lineCap = "round";
    }

    fillGrid();

    for (let i = 0; i < birds.length; i++) {
      const bd = birds[i]!;

      // ── Reynolds accumulation over the 3×3 grid neighborhood ──
      let sepX = 0;
      let sepY = 0;
      let aliX = 0;
      let aliY = 0;
      let cohX = 0;
      let cohY = 0;
      let neighbors = 0;

      const cx = Math.min(cols - 1, Math.max(0, (bd.x / NEIGHBOR_R) | 0));
      const cy = Math.min(rows - 1, Math.max(0, (bd.y / NEIGHBOR_R) | 0));
      const gx0 = cx > 0 ? cx - 1 : 0;
      const gx1 = cx < cols - 1 ? cx + 1 : cols - 1;
      const gy0 = cy > 0 ? cy - 1 : 0;
      const gy1 = cy < rows - 1 ? cy + 1 : rows - 1;

      for (let gy = gy0; gy <= gy1 && neighbors < MAX_NEIGHBORS; gy++) {
        for (let gx = gx0; gx <= gx1 && neighbors < MAX_NEIGHBORS; gx++) {
          for (let j = gridHead[gy * cols + gx]!; j !== -1; j = gridNext[j]!) {
            if (j === i) continue;
            const other = birds[j]!;
            const dx = other.x - bd.x;
            const dy = other.y - bd.y;
            const d2 = dx * dx + dy * dy;
            if (d2 >= r2 || d2 === 0) continue;
            neighbors++;
            aliX += other.vx;
            aliY += other.vy;
            cohX += dx;
            cohY += dy;
            if (d2 < sep2) {
              // Push away, harder when closer (1/d falloff, normalized).
              const inv = 1 / Math.sqrt(d2);
              sepX -= dx * inv;
              sepY -= dy * inv;
            }
            if (neighbors >= MAX_NEIGHBORS) break;
          }
        }
      }

      let ax = 0;
      let ay = 0;
      if (neighbors > 0) {
        const inv = 1 / neighbors;
        // Alignment: steer toward the local average heading (the flock's grain).
        ax += (aliX * inv - bd.vx) * W_ALIGNMENT;
        ay += (aliY * inv - bd.vy) * W_ALIGNMENT;
        // Cohesion: a faint pull toward the local center of mass.
        ax += cohX * inv * W_COHESION;
        ay += cohY * inv * W_COHESION;
        // Separation: personal space (sepX/Y already summed unit vectors).
        ax += sepX * W_SEPARATION;
        ay += sepY * W_SEPARATION;
      }

      // Curl-noise wind: the large-scale sweep the whole flock rides. Steer the
      // bird's heading toward the local field direction (scaled to cruise speed).
      curl2(bd.x * WIND_SCALE, bd.y * WIND_SCALE, windTz, wind);
      ax += (wind[0] * SPEED.MAX - bd.vx) * W_ALIGNMENT * windW;
      ay += (wind[1] * SPEED.MAX - bd.vy) * W_ALIGNMENT * windW;

      // Soft steering limit — birds bank, they don't snap.
      const aMag = Math.sqrt(ax * ax + ay * ay);
      if (aMag > STEER_MAX) {
        const s = STEER_MAX / aMag;
        ax *= s;
        ay *= s;
      }

      // Pointer = predator: flee the cursor, strength falling off with distance.
      if (pointer.active) {
        const dx = bd.x - pointer.x;
        const dy = bd.y - pointer.y;
        const d2 = dx * dx + dy * dy;
        if (d2 < POINTER.R * POINTER.R && d2 > 0) {
          const d = Math.sqrt(d2);
          const f = Math.pow((POINTER.R - d) / POINTER.R, POINTER.FALLOFF);
          ax += (dx / d) * f * POINTER.STRENGTH;
          ay += (dy / d) * f * POINTER.STRENGTH;
        }
      }

      // Edges: gently steer back inside the margin (no hard wrap) so the flock
      // wheels at the frame instead of teleporting.
      if (bd.x < EDGE.MARGIN) ax += EDGE.TURN * (1 - bd.x / EDGE.MARGIN);
      else if (bd.x > width - EDGE.MARGIN) ax -= EDGE.TURN * (1 - (width - bd.x) / EDGE.MARGIN);
      if (bd.y < EDGE.MARGIN) ay += EDGE.TURN * (1 - bd.y / EDGE.MARGIN);
      else if (bd.y > height - EDGE.MARGIN) ay -= EDGE.TURN * (1 - (height - bd.y) / EDGE.MARGIN);

      // Scroll gust + tiny wander.
      ay += gust;
      ax += (Math.random() - 0.5) * WANDER;
      ay += (Math.random() - 0.5) * WANDER;

      bd.vx += ax * dt;
      bd.vy += ay * dt;

      // Min/max speed clamp — birds never stall, never rocket.
      const sp = Math.sqrt(bd.vx * bd.vx + bd.vy * bd.vy) || 1e-6;
      if (sp > maxSpeed) {
        const s = maxSpeed / sp;
        bd.vx *= s;
        bd.vy *= s;
      } else if (sp < minSpeed) {
        const s = minSpeed / sp;
        bd.vx *= s;
        bd.vy *= s;
      }

      bd.x += bd.vx * dt;
      bd.y += bd.vy * dt;

      if (draw) {
        // Tiny velocity-aligned streak. Density does the work — many faint
        // birds accumulate into the bright ribbons of the murmuration.
        const speed = Math.sqrt(bd.vx * bd.vx + bd.vy * bd.vy) || 1e-6;
        const dirX = bd.vx / speed;
        const dirY = bd.vy / speed;
        const len = 2.0 + bd.bright * 1.8 + (speed / maxSpeed) * 1.4;
        const alpha = Math.min(baseAlpha * bd.bright * intensity, 1);

        const tailX = bd.x - dirX * len * 0.45;
        const tailY = bd.y - dirY * len * 0.45;
        const headX = bd.x + dirX * len * 0.55;
        const headY = bd.y + dirY * len * 0.55;

        ctx.lineWidth = 0.9 + bd.bright * 0.5;
        ctx.strokeStyle = toCss(rgb, alpha);
        ctx.beginPath();
        ctx.moveTo(tailX, tailY);
        ctx.lineTo(headX, headY);
        ctx.stroke();
      }
    }
  }

  return {
    id: "boids",
    label: "Boids",
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
      ctx.lineJoin = "round";
      paintBase(1);
      build();
      if (reducedMotion) renderStaticFrame();
    },

    frame(tMs: number, dtMs: number) {
      if (!ctx) return;
      const light = palette?.theme === "light";
      // A gentle trail wash: fast enough not to haze over, slow enough that the
      // wake reads as motion blur behind each ribbon.
      paintBase(light ? 0.22 : 0.19);
      advance(tMs, dtMs, true);
    },

    resize(frame: KernelFrameContext) {
      width = frame.width;
      height = frame.height;
      dpr = frame.dpr;
      applyTransform();
      ctx!.lineCap = "round";
      ctx!.lineJoin = "round";
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
      birds = [];
    },
  };
}
