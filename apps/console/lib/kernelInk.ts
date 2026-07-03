/**
 * Per-kernel typographic identity + legibility registry.
 *
 * Every backdrop kernel renders dark-themed over the engine's deep ink base
 * (`palette.ts` DARK.bg = [7,8,15]), so the page ink is ALWAYS light and the
 * scrim ALWAYS darkens — one theme-independent legibility solution.
 *
 * Each entry pairs a kernel with:
 *  - `lum`/`busy`  — measured mean luminance + high-frequency busyness of the
 *                    hero band, the inputs to the contrast math below.
 *  - `scrim`       — hero/reading-band black-scrim alphas derived from the math.
 *  - `haloTier`    — the per-glyph dark text-shadow tier (the second, local AA
 *                    backstop that the flat scrim average can't guarantee).
 *  - `accent`      — an accent hue pulled from the kernel's character.
 *  - `motion`/`timing` — the hero's kinetic entrance.
 *
 * Legibility contract (ink fg #F4F6FF, L_fg ≈ 0.93; AA body ≥ 4.5:1):
 *   L_bg ≤ 0.98/4.5 − 0.05 ≈ 0.168
 *   peak       = clamp(lum + 0.55·busy, 0, 1)
 *   scrim.hero = clamp(1 − 0.168/peak, 0.16, 0.60)
 *   scrim.read = clamp(1 − 0.120/peak, 0.30, 0.74)   (reading band is stricter)
 * Each scrim below is computed from this kernel's lum/busy, then hand-rounded.
 *
 * `scrim.nav` (optional) is an EXTRA top-anchored darken (top ~6vh, fading out
 * by ~15vh) layered above the flat hero band, ONLY for kernels whose bright/
 * busy field lifts the local backdrop behind the small inactive nav labels
 * (0.66-alpha) below the 4.5:1 floor. It is additive over scrim.hero and is
 * confined to the nav strip, so it rescues the nav WITHOUT muddying the hero
 * headline below it. Kernels that pass nav legibility omit it (default 0).
 *
 * `Record<KernelId, KernelInk>` makes coverage of all 30 kernels a COMPILE-TIME
 * invariant: add a kernel id and this file fails to type-check until it has ink.
 */

import type { KernelId } from "@/lib/gl/engine/types";

/** Named entrance characters for the hero (per-word/glyph). */
export type InkMotion =
  | "shatter" // marks assemble from scattered fragments
  | "drift" // lateral slow glide in on a current
  | "pulse" // energy throb: scale + glow swell
  | "rise" // settle upward into place (growth/bloom/fold)
  | "marble" // skew/rotate swirl in (ink-on-water, oil)
  | "ripple" // concentric wave passes word→word
  | "bleed" // wick in: heavy blur → ink sharpens
  | "condense" // out-of-focus → snap to focus (volumetric/fluid)
  | "beam"; // wipe of light sweeps the line (searchlight)

export interface InkTiming {
  /** Total entrance per glyph/word (ms). */
  dur: number;
  /** Stagger between successive units (ms). */
  stagger: number;
  /** CSS easing. */
  ease: string;
  /** Granularity the motion staggers over. */
  unit: "word" | "glyph";
}

export interface KernelInk {
  /** Mean perceived backdrop luminance in the hero band, dark-themed (0..1). */
  lum: number;
  /** Spatial high-frequency contrast / "busyness" that locally spikes (0..1). */
  busy: number;
  /** Scrim alphas: hero band (light) and reading band (strict). 0..1.
   *  `nav` (optional) is an extra additive top-strip darken for kernels whose
   *  bright field washes out the small inactive nav labels; omit when nav passes. */
  scrim: { hero: number; read: number; nav?: number };
  /** Halo strength tier for ink (1 calm .. 3 turbulent). */
  haloTier: 1 | 2 | 3;
  /** Accent hue pulled from this kernel's character (hex). Drives --ink-accent. */
  accent: string;
  /** Entrance character for the hero. */
  motion: InkMotion;
  timing: InkTiming;
}

/** Constant ink foreground + muted ramp shared by all kernels (legibility math). */
export const INK_FG = "#F4F6FF";
export const INK_MUTE = "rgba(244,246,255,0.66)";
export const INK_DIM = "rgba(244,246,255,0.44)";

/** Halo (dark blurred text-shadow) by tier — the per-glyph AA backstop. */
export const INK_HALO: Record<1 | 2 | 3, string> = {
  1: "0 1px 2px rgba(5,6,12,.55), 0 0 10px rgba(5,6,12,.40)",
  2: "0 1px 2px rgba(5,6,12,.70), 0 0 14px rgba(5,6,12,.55), 0 0 28px rgba(5,6,12,.35)",
  3: "0 1px 3px rgba(5,6,12,.82), 0 0 16px rgba(5,6,12,.68), 0 0 34px rgba(5,6,12,.50), 0 0 64px rgba(5,6,12,.30)",
};

// Tuned: snappy = storms, languid = ink/marble, springy = bloom/shatter.
const T = {
  drift: (): InkTiming => ({ dur: 900, stagger: 60, ease: "cubic-bezier(.22,.61,.36,1)", unit: "word" }),
  shatter: (): InkTiming => ({ dur: 760, stagger: 26, ease: "cubic-bezier(.16,.84,.34,1)", unit: "glyph" }),
  pulse: (): InkTiming => ({ dur: 680, stagger: 70, ease: "cubic-bezier(.34,1.56,.64,1)", unit: "word" }),
  rise: (): InkTiming => ({ dur: 820, stagger: 52, ease: "cubic-bezier(.2,.8,.2,1)", unit: "word" }),
  marble: (): InkTiming => ({ dur: 1040, stagger: 70, ease: "cubic-bezier(.4,.14,.2,1)", unit: "word" }),
  ripple: (): InkTiming => ({ dur: 740, stagger: 44, ease: "cubic-bezier(.36,.07,.19,.97)", unit: "glyph" }),
  bleed: (): InkTiming => ({ dur: 1180, stagger: 88, ease: "cubic-bezier(.45,.05,.25,1)", unit: "word" }),
  condense: (): InkTiming => ({ dur: 880, stagger: 64, ease: "cubic-bezier(.2,.7,.2,1)", unit: "word" }),
  beam: (): InkTiming => ({ dur: 700, stagger: 50, ease: "cubic-bezier(.3,.0,.0,1)", unit: "glyph" }),
};

export const KERNEL_INK: Record<KernelId, KernelInk> = {
  // id                 lum   busy  scrim{hero,read}            halo  accent       motion       timing
  constellation: { lum: 0.1, busy: 0.35, scrim: { hero: 0.2, read: 0.34 }, haloTier: 1, accent: "#838EFF", motion: "shatter", timing: T.shatter() },
  flow: { lum: 0.16, busy: 0.4, scrim: { hero: 0.24, read: 0.4 }, haloTier: 1, accent: "#7FB0F0", motion: "drift", timing: T.drift() },
  aurora: { lum: 0.26, busy: 0.3, scrim: { hero: 0.34, read: 0.5 }, haloTier: 1, accent: "#9A86FF", motion: "drift", timing: T.drift() },
  mesh: { lum: 0.3, busy: 0.6, scrim: { hero: 0.4, read: 0.54, nav: 0.5 }, haloTier: 3, accent: "#B08EFF", motion: "shatter", timing: T.shatter() },
  moire: { lum: 0.3, busy: 0.85, scrim: { hero: 0.52, read: 0.66 }, haloTier: 3, accent: "#78DCE8", motion: "shatter", timing: T.shatter() },
  volumetric: { lum: 0.2, busy: 0.3, scrim: { hero: 0.28, read: 0.44 }, haloTier: 1, accent: "#9FB4FF", motion: "condense", timing: T.condense() },
  lic: { lum: 0.18, busy: 0.42, scrim: { hero: 0.28, read: 0.44 }, haloTier: 1, accent: "#838EFF", motion: "drift", timing: T.drift() },
  "fluid-aurora": { lum: 0.3, busy: 0.4, scrim: { hero: 0.38, read: 0.54 }, haloTier: 2, accent: "#6FD6E8", motion: "drift", timing: T.drift() },
  cloudfield: { lum: 0.34, busy: 0.45, scrim: { hero: 0.44, read: 0.58 }, haloTier: 2, accent: "#9AB4FF", motion: "drift", timing: T.drift() },
  "plasma-orbs": { lum: 0.34, busy: 0.72, scrim: { hero: 0.5, read: 0.64, nav: 0.5 }, haloTier: 3, accent: "#8FB6FF", motion: "pulse", timing: T.pulse() },
  "blobs-mesh": { lum: 0.28, busy: 0.3, scrim: { hero: 0.36, read: 0.52 }, haloTier: 1, accent: "#C68EFF", motion: "drift", timing: T.drift() },
  "retro-plasma": { lum: 0.42, busy: 0.8, scrim: { hero: 0.58, read: 0.72 }, haloTier: 3, accent: "#6CE0E8", motion: "pulse", timing: T.pulse() },
  "inversion-lattice": { lum: 0.24, busy: 0.75, scrim: { hero: 0.46, read: 0.62 }, haloTier: 3, accent: "#7CE0E8", motion: "shatter", timing: T.shatter() },
  "vogel-bloom": { lum: 0.12, busy: 0.4, scrim: { hero: 0.22, read: 0.38 }, haloTier: 1, accent: "#FFC46A", motion: "rise", timing: T.rise() },
  "crystal-drift": { lum: 0.3, busy: 0.7, scrim: { hero: 0.52, read: 0.64, nav: 0.42 }, haloTier: 3, accent: "#76E0D0", motion: "shatter", timing: T.shatter() },
  "ripple-lattice": { lum: 0.22, busy: 0.6, scrim: { hero: 0.4, read: 0.58, nav: 0.4 }, haloTier: 3, accent: "#8FA0FF", motion: "ripple", timing: T.ripple() },
  "liquid-lumen": { lum: 0.46, busy: 0.6, scrim: { hero: 0.58, read: 0.7, nav: 0.46 }, haloTier: 3, accent: "#B884FF", motion: "pulse", timing: T.pulse() },
  "spectral-drift": { lum: 0.18, busy: 0.55, scrim: { hero: 0.32, read: 0.48 }, haloTier: 2, accent: "#9AA8C8", motion: "drift", timing: T.drift() },
  "mycelium-mesh": { lum: 0.14, busy: 0.55, scrim: { hero: 0.28, read: 0.44 }, haloTier: 2, accent: "#6FD0B0", motion: "rise", timing: T.rise() },
  oilfield: { lum: 0.4, busy: 0.6, scrim: { hero: 0.52, read: 0.66, nav: 0.5 }, haloTier: 3, accent: "#7AD6C0", motion: "marble", timing: T.marble() },
  "suminagashi-drift": { lum: 0.36, busy: 0.6, scrim: { hero: 0.5, read: 0.64, nav: 0.48 }, haloTier: 3, accent: "#78C4E0", motion: "marble", timing: T.marble() },
  "kinetic-stipple": { lum: 0.12, busy: 0.5, scrim: { hero: 0.26, read: 0.42 }, haloTier: 2, accent: "#8FA0FF", motion: "drift", timing: T.drift() },
  "neural-bloom": { lum: 0.26, busy: 0.4, scrim: { hero: 0.36, read: 0.52 }, haloTier: 1, accent: "#C28EFF", motion: "rise", timing: T.rise() },
  agent1: { lum: 0.28, busy: 0.35, scrim: { hero: 0.36, read: 0.52 }, haloTier: 1, accent: "#9A86FF", motion: "condense", timing: T.condense() },
  "aether-lattice": { lum: 0.24, busy: 0.65, scrim: { hero: 0.42, read: 0.58 }, haloTier: 3, accent: "#8FC0FF", motion: "shatter", timing: T.shatter() },
  "bat-signal": { lum: 0.22, busy: 0.45, scrim: { hero: 0.32, read: 0.48 }, haloTier: 2, accent: "#BFD0FF", motion: "beam", timing: T.beam() },
  "storm-signal": { lum: 0.16, busy: 0.55, scrim: { hero: 0.3, read: 0.46 }, haloTier: 2, accent: "#9AA8C8", motion: "pulse", timing: T.pulse() },
  origami: { lum: 0.2, busy: 0.25, scrim: { hero: 0.3, read: 0.46 }, haloTier: 1, accent: "#FFC49A", motion: "rise", timing: T.rise() },
  "ink-diffusion": { lum: 0.3, busy: 0.6, scrim: { hero: 0.46, read: 0.62, nav: 0.5 }, haloTier: 3, accent: "#8FB0E0", motion: "bleed", timing: T.bleed() },
  "petroleum-sheen": { lum: 0.34, busy: 0.65, scrim: { hero: 0.5, read: 0.66, nav: 0.46 }, haloTier: 3, accent: "#7AD6D0", motion: "marble", timing: T.marble() },
  boids: { lum: 0.12, busy: 0.45, scrim: { hero: 0.24, read: 0.4 }, haloTier: 1, accent: "#8FA0FF", motion: "drift", timing: T.drift() },
};

/** Resolve the ink for a kernel, falling back to the calm default. */
export function inkFor(id: KernelId): KernelInk {
  return KERNEL_INK[id] ?? KERNEL_INK.constellation;
}
