/**
 * Theme-resolved palettes for every kernel.
 *
 * One cohesive identity — iris-led, with teal / rose / gold accents — tuned
 * separately for light and dark so both modes are first-class rather than one
 * being an afterthought inversion of the other. Kernels read from this so a
 * theme flip is a single `setTheme()` with no per-kernel color knowledge.
 */

import type { KernelPalette, RGB, ThemeName } from "./types";
import { getCustomPalette, mergePalette } from "./paletteStore";

/**
 * Deep ink canvas — luminous effects pop hardest here. Cool jewel tones
 * (iris → cyan → violet → soft rose); deliberately no warm gold, which muddied
 * the gradient kernels toward orange.
 */
const DARK: KernelPalette = {
  theme: "dark",
  bg: [7, 8, 15],
  accents: [
    [131, 142, 255], // iris
    [120, 220, 232], // cyan
    [176, 142, 255], // violet
    [255, 150, 182], // soft rose
  ],
  ink: [232, 236, 255],
  intensity: 1,
};

/** Pearl / paper canvas — editorial, restrained; effects dialed back. */
const LIGHT: KernelPalette = {
  theme: "light",
  bg: [244, 246, 251],
  accents: [
    [84, 96, 222], // iris (deepened for contrast on pearl)
    [32, 150, 176], // cyan
    [124, 96, 212], // violet
    [212, 104, 140], // rose
  ],
  ink: [38, 42, 70],
  intensity: 0.78,
};

const PALETTES: Record<ThemeName, KernelPalette> = { dark: DARK, light: LIGHT };

/** The house palette for a theme, ignoring any user override (defensive copy). */
export function housePalette(theme: ThemeName): KernelPalette {
  const p = PALETTES[theme];
  return {
    theme: p.theme,
    bg: [...p.bg] as RGB,
    accents: p.accents.map((a) => [...a] as RGB),
    ink: [...p.ink] as RGB,
    intensity: p.intensity,
  };
}

/**
 * Resolve the palette every kernel renders with — the house palette merged with
 * the user's custom override for this mode (see paletteStore). Returns a fresh
 * object each call, so callers can hold it without aliasing the source.
 */
export function resolvePalette(theme: ThemeName): KernelPalette {
  return mergePalette(housePalette(theme), getCustomPalette()[theme]);
}

/** `[r,g,b]` (0–255) → normalized `[r,g,b]` (0–1) for GL uniforms. */
export function toUnit(rgb: RGB): RGB {
  return [rgb[0] / 255, rgb[1] / 255, rgb[2] / 255];
}

/** `[r,g,b]` → `"rgb(r,g,b)"`; optional alpha → `"rgba(...)"`. */
export function toCss(rgb: RGB, alpha?: number): string {
  const [r, g, b] = rgb;
  return alpha === undefined
    ? `rgb(${r | 0},${g | 0},${b | 0})`
    : `rgba(${r | 0},${g | 0},${b | 0},${alpha})`;
}

/** Linear blend between two RGB triples; `t` in 0–1. */
export function mixRgb(a: RGB, b: RGB, t: number): RGB {
  return [
    a[0] + (b[0] - a[0]) * t,
    a[1] + (b[1] - a[1]) * t,
    a[2] + (b[2] - a[2]) * t,
  ];
}
