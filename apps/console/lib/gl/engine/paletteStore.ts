/**
 * paletteStore — the single source of truth for the user's custom color scheme,
 * applied to EVERY world at once.
 *
 * Color in this app has exactly two consumers:
 *   1. the 34 WebGL/2D kernels (backgrounds), which read {@link resolvePalette};
 *   2. the glyphs + glass UI, which read CSS custom properties.
 * Both now resolve through THIS store, so one override recolors the entire site
 * — every background, every glyph, every glass surface — in light and dark.
 *
 * The override is a partial {@link KernelPalette} per mode (dark/light): any
 * subset of `{ bg, accents[0..3], ink, intensity }`. Absent channels fall back
 * to the house palette (palette.ts), so a user can nudge a single accent or
 * apply a full preset. Pure + framework-agnostic (a tiny pub/sub) so the engine,
 * React, and tests all read the same state with zero coupling.
 */

import type { KernelPalette, RGB, ThemeName } from "./types";
import { getPreset } from "./palettePresets";

/** A per-mode partial override. Undefined channels inherit the house palette. */
export interface PaletteOverride {
  bg?: RGB;
  accents?: (RGB | null)[]; // sparse: index i overrides accent i; null = inherit
  ink?: RGB;
  intensity?: number;
}

export interface CustomPalette {
  /** Preset id this state derived from (for UI highlight), or null if hand-tuned. */
  presetId: string | null;
  dark: PaletteOverride;
  light: PaletteOverride;
}

const STORAGE_KEY = "studio.customPalette";

function emptyOverride(): PaletteOverride {
  return {};
}

function emptyState(): CustomPalette {
  return { presetId: null, dark: emptyOverride(), light: emptyOverride() };
}

let state: CustomPalette = emptyState();
const listeners = new Set<(s: CustomPalette) => void>();
let hydrated = false;

function clampByte(n: number): number {
  return Math.max(0, Math.min(255, Math.round(n)));
}

function sanitizeRgb(v: unknown): RGB | undefined {
  if (!Array.isArray(v) || v.length !== 3) return undefined;
  const out = v.map((c) => (typeof c === "number" && Number.isFinite(c) ? clampByte(c) : NaN));
  if (out.some((c) => Number.isNaN(c))) return undefined;
  return out as RGB;
}

function sanitizeOverride(raw: unknown): PaletteOverride {
  if (!raw || typeof raw !== "object") return {};
  const r = raw as Record<string, unknown>;
  const out: PaletteOverride = {};
  const bg = sanitizeRgb(r.bg);
  if (bg) out.bg = bg;
  const ink = sanitizeRgb(r.ink);
  if (ink) out.ink = ink;
  if (typeof r.intensity === "number" && Number.isFinite(r.intensity)) {
    out.intensity = Math.max(0, Math.min(1, r.intensity));
  }
  if (Array.isArray(r.accents)) {
    out.accents = r.accents.slice(0, 4).map((a) => sanitizeRgb(a) ?? null);
  }
  return out;
}

function hydrate(): void {
  if (hydrated || typeof window === "undefined") return;
  hydrated = true;
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return;
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    state = {
      presetId: typeof parsed.presetId === "string" ? parsed.presetId : null,
      dark: sanitizeOverride(parsed.dark),
      light: sanitizeOverride(parsed.light),
    };
  } catch {
    state = emptyState();
  }
}

function persist(): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch {
    /* storage unavailable — non-fatal, state still lives in memory */
  }
}

function emit(): void {
  for (const fn of listeners) fn(state);
}

/** Current custom-palette state (hydrated from storage on first read). */
export function getCustomPalette(): CustomPalette {
  hydrate();
  return state;
}

/** Subscribe to changes; returns an unsubscribe fn. Fires on every mutation. */
export function subscribeCustomPalette(fn: (s: CustomPalette) => void): () => void {
  hydrate();
  listeners.add(fn);
  return () => listeners.delete(fn);
}

/** Apply a full preset (both modes), or clear to the house default ("studio"). */
export function applyPreset(presetId: string): void {
  hydrate();
  const preset = getPreset(presetId);
  if (!preset) return;
  state = {
    presetId,
    dark: {
      bg: [...preset.dark.bg] as RGB,
      accents: preset.dark.accents.map((a) => [...a] as RGB),
      ink: [...preset.dark.ink] as RGB,
      intensity: preset.dark.intensity,
    },
    light: {
      bg: [...preset.light.bg] as RGB,
      accents: preset.light.accents.map((a) => [...a] as RGB),
      ink: [...preset.light.ink] as RGB,
      intensity: preset.light.intensity,
    },
  };
  persist();
  emit();
}

/** Override one accent slot (0..3) for a mode. Marks state as hand-tuned. */
export function setAccent(mode: ThemeName, index: number, rgb: RGB): void {
  hydrate();
  if (index < 0 || index > 3) return;
  const ov = { ...state[mode] };
  const accents = (ov.accents ? [...ov.accents] : [null, null, null, null]).slice(0, 4);
  while (accents.length < 4) accents.push(null);
  accents[index] = [...rgb] as RGB;
  ov.accents = accents;
  state = { ...state, presetId: null, [mode]: ov };
  persist();
  emit();
}

/** Override the background (canvas base) for a mode. Marks state as hand-tuned. */
export function setBg(mode: ThemeName, rgb: RGB): void {
  hydrate();
  state = { ...state, presetId: null, [mode]: { ...state[mode], bg: [...rgb] as RGB } };
  persist();
  emit();
}

/** Override the ink (foreground) for a mode. Marks state as hand-tuned. */
export function setInk(mode: ThemeName, rgb: RGB): void {
  hydrate();
  state = { ...state, presetId: null, [mode]: { ...state[mode], ink: [...rgb] as RGB } };
  persist();
  emit();
}

/** Override the global effect intensity (0..1) for a mode. */
export function setIntensity(mode: ThemeName, value: number): void {
  hydrate();
  const v = Math.max(0, Math.min(1, value));
  state = { ...state, presetId: null, [mode]: { ...state[mode], intensity: v } };
  persist();
  emit();
}

/** Clear all overrides → the house default palette. */
export function resetCustomPalette(): void {
  hydrate();
  state = emptyState();
  persist();
  emit();
}

/**
 * Restore a full {@link CustomPalette} snapshot (e.g. a saved "favorite
 * background" from the Library). Sanitized through the same path as hydration,
 * so corrupt/partial snapshots degrade to the house palette instead of throwing.
 * Pass null to clear back to the default.
 */
export function restoreCustomPalette(snapshot: CustomPalette | null): void {
  hydrate();
  if (!snapshot) {
    state = emptyState();
  } else {
    state = {
      presetId: typeof snapshot.presetId === "string" ? snapshot.presetId : null,
      dark: sanitizeOverride(snapshot.dark),
      light: sanitizeOverride(snapshot.light),
    };
  }
  persist();
  emit();
}

/** True when no overrides are active (the house default is in effect). */
export function isDefaultPalette(s: CustomPalette = getCustomPalette()): boolean {
  const empty = (o: PaletteOverride) =>
    o.bg === undefined &&
    o.ink === undefined &&
    o.intensity === undefined &&
    (o.accents === undefined || o.accents.every((a) => a == null));
  return s.presetId === null && empty(s.dark) && empty(s.light);
}

/**
 * Merge a base house palette with the active override for its mode. Pure: used
 * by {@link resolvePalette} (backgrounds) AND the CSS-var sync (glyphs/glass),
 * so both stay perfectly in lockstep with one definition of "merged".
 */
export function mergePalette(base: KernelPalette, override: PaletteOverride): KernelPalette {
  const accents = base.accents.map((a, i) => {
    const o = override.accents?.[i];
    return (o ?? a) as RGB;
  });
  return {
    theme: base.theme,
    bg: override.bg ?? base.bg,
    accents,
    ink: override.ink ?? base.ink,
    intensity: override.intensity ?? base.intensity,
  };
}
