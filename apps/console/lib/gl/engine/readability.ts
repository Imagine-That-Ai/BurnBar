import type { KernelPalette, RGB } from "./types";

export type AdaptiveForegroundTone = "light" | "dark";
export type ReadabilitySource = "canvas" | "palette" | "css-fallback";

export interface AdaptiveForegroundFamily {
  primary: RGB;
  secondary: RGB;
  muted: RGB;
  accent: RGB;
  icon: RGB;
  focus: RGB;
  shadow: RGB;
  scrim: RGB;
}

export interface BackdropReadabilityProfile {
  tone: AdaptiveForegroundTone;
  primary: string;
  secondary: string;
  muted: string;
  accent: string;
  icon: string;
  focus: string;
  shadow: string;
  scrim: string;
  scrimOpacity: number;
  minLuminance: number;
  maxLuminance: number;
  contrastRatio: number;
  sampleCount: number;
  samplingDurationMs: number;
  source: ReadabilitySource;
}

export interface ReadabilityUpdate {
  samples: readonly RGB[];
  source: ReadabilitySource;
  nowMs: number;
}

export const NORMAL_TEXT_CONTRAST = 4.5;
export const LARGE_TEXT_CONTRAST = 3;

const LIGHT_FOREGROUND: AdaptiveForegroundFamily = {
  primary: [255, 255, 255],
  secondary: [235, 239, 246],
  muted: [218, 224, 234],
  accent: [255, 226, 166],
  icon: [242, 246, 252],
  focus: [255, 255, 255],
  shadow: [0, 0, 0],
  scrim: [5, 7, 11],
};

const DARK_FOREGROUND: AdaptiveForegroundFamily = {
  primary: [13, 17, 23],
  secondary: [31, 41, 55],
  muted: [55, 65, 81],
  accent: [91, 52, 0],
  icon: [24, 33, 45],
  focus: [13, 17, 23],
  shadow: [255, 255, 255],
  scrim: [248, 250, 252],
};

export const ADAPTIVE_FOREGROUND_FAMILIES: Readonly<
  Record<AdaptiveForegroundTone, AdaptiveForegroundFamily>
> = {
  light: LIGHT_FOREGROUND,
  dark: DARK_FOREGROUND,
};

function clamp01(value: number): number {
  return Math.min(1, Math.max(0, value));
}

/** One 8-bit sRGB channel to linear light, per WCAG 2.x. */
export function srgbChannelToLinear(channel: number): number {
  const normalized = clamp01(channel / 255);
  return normalized <= 0.04045
    ? normalized / 12.92
    : Math.pow((normalized + 0.055) / 1.055, 2.4);
}

/** WCAG relative luminance for an 8-bit sRGB triple. */
export function relativeLuminance(rgb: RGB): number {
  return (
    0.2126 * srgbChannelToLinear(rgb[0]) +
    0.7152 * srgbChannelToLinear(rgb[1]) +
    0.0722 * srgbChannelToLinear(rgb[2])
  );
}

export function contrastRatio(a: number | RGB, b: number | RGB): number {
  const luminanceA = typeof a === "number" ? a : relativeLuminance(a);
  const luminanceB = typeof b === "number" ? b : relativeLuminance(b);
  const lighter = Math.max(luminanceA, luminanceB);
  const darker = Math.min(luminanceA, luminanceB);
  return (lighter + 0.05) / (darker + 0.05);
}

/** Source-over sRGB compositing. Alpha belongs to `foreground`. */
export function compositeRgb(foreground: RGB, background: RGB, alpha: number): RGB {
  const a = clamp01(alpha);
  return [
    foreground[0] * a + background[0] * (1 - a),
    foreground[1] * a + background[1] * (1 - a),
    foreground[2] * a + background[2] * (1 - a),
  ];
}

export function rgbToCss(rgb: RGB): string {
  return `rgb(${Math.round(rgb[0])} ${Math.round(rgb[1])} ${Math.round(rgb[2])})`;
}

interface ToneEvaluation {
  tone: AdaptiveForegroundTone;
  scrimOpacity: number;
  contrastRatio: number;
}

function minimumContrast(
  samples: readonly RGB[],
  foreground: RGB,
  scrim: RGB,
  scrimOpacity: number,
): number {
  let minimum = Number.POSITIVE_INFINITY;
  for (const sample of samples) {
    const effectiveBackground = compositeRgb(scrim, sample, scrimOpacity);
    minimum = Math.min(minimum, contrastRatio(foreground, effectiveBackground));
  }
  return Number.isFinite(minimum) ? minimum : 1;
}

function evaluateTone(
  samples: readonly RGB[],
  tone: AdaptiveForegroundTone,
  targetRatio = NORMAL_TEXT_CONTRAST,
): ToneEvaluation {
  const family = ADAPTIVE_FOREGROUND_FAMILIES[tone];
  const withoutScrim = minimumContrast(samples, family.muted, family.scrim, 0);
  if (withoutScrim >= targetRatio) {
    return { tone, scrimOpacity: 0, contrastRatio: withoutScrim };
  }

  let low = 0;
  let high = 1;
  for (let index = 0; index < 14; index += 1) {
    const midpoint = (low + high) / 2;
    if (minimumContrast(samples, family.muted, family.scrim, midpoint) >= targetRatio) {
      high = midpoint;
    } else {
      low = midpoint;
    }
  }
  return {
    tone,
    scrimOpacity: high,
    contrastRatio: minimumContrast(samples, family.muted, family.scrim, high),
  };
}

function preferredEvaluation(samples: readonly RGB[], preferred?: AdaptiveForegroundTone): ToneEvaluation {
  const light = evaluateTone(samples, "light");
  const dark = evaluateTone(samples, "dark");
  const difference = Math.abs(light.scrimOpacity - dark.scrimOpacity);
  if (preferred && difference < 0.045) return preferred === "light" ? light : dark;
  return light.scrimOpacity <= dark.scrimOpacity ? light : dark;
}

function buildProfile(
  samples: readonly RGB[],
  evaluation: ToneEvaluation,
  source: ReadabilitySource,
  scrimOpacity = evaluation.scrimOpacity,
): BackdropReadabilityProfile {
  const family = ADAPTIVE_FOREGROUND_FAMILIES[evaluation.tone];
  const luminances = samples.map(relativeLuminance);
  const effectiveContrast = minimumContrast(samples, family.muted, family.scrim, scrimOpacity);
  return {
    tone: evaluation.tone,
    primary: rgbToCss(family.primary),
    secondary: rgbToCss(family.secondary),
    muted: rgbToCss(family.muted),
    accent: rgbToCss(family.accent),
    icon: rgbToCss(family.icon),
    focus: rgbToCss(family.focus),
    shadow: rgbToCss(family.shadow),
    scrim: rgbToCss(family.scrim),
    scrimOpacity,
    minLuminance: luminances.length > 0 ? Math.min(...luminances) : 0,
    maxLuminance: luminances.length > 0 ? Math.max(...luminances) : 0,
    contrastRatio: effectiveContrast,
    sampleCount: samples.length,
    samplingDurationMs: 0,
    source,
  };
}

/**
 * Stabilizes light/dark foreground selection while raising contrast protection
 * immediately. A pending tone must remain preferable for 900 ms; the current
 * tone receives any stronger scrim synchronously, so the dwell never creates a
 * low-contrast frame.
 */
export class BackdropReadabilityStabilizer {
  private tone: AdaptiveForegroundTone | undefined;
  private pendingTone: AdaptiveForegroundTone | undefined;
  private pendingSince = 0;
  private lastScrimOpacity = 0;

  update(update: ReadabilityUpdate): BackdropReadabilityProfile {
    const samples = update.samples.length > 0 ? update.samples : ([[7, 8, 15]] as RGB[]);
    const preferred = preferredEvaluation(samples, this.tone);

    if (!this.tone) {
      this.tone = preferred.tone;
      this.pendingTone = undefined;
    } else if (preferred.tone !== this.tone) {
      const current = evaluateTone(samples, this.tone);
      const urgent = current.scrimOpacity > 0.72 && preferred.scrimOpacity + 0.2 < current.scrimOpacity;
      if (urgent) {
        this.tone = preferred.tone;
        this.pendingTone = undefined;
      } else if (this.pendingTone !== preferred.tone) {
        this.pendingTone = preferred.tone;
        this.pendingSince = update.nowMs;
      } else if (update.nowMs - this.pendingSince >= 900) {
        this.tone = preferred.tone;
        this.pendingTone = undefined;
      }
    } else {
      this.pendingTone = undefined;
    }

    const selected = evaluateTone(samples, this.tone);
    const requiredOpacity = selected.scrimOpacity;
    const stabilizedOpacity = requiredOpacity >= this.lastScrimOpacity
      ? requiredOpacity
      : Math.max(requiredOpacity, this.lastScrimOpacity - 0.08);
    this.lastScrimOpacity = stabilizedOpacity;
    return buildProfile(samples, selected, update.source, stabilizedOpacity);
  }

  reset(): void {
    this.tone = undefined;
    this.pendingTone = undefined;
    this.pendingSince = 0;
    this.lastScrimOpacity = 0;
  }
}

/** Conservative profile used until a rendered frame can be sampled. */
export function fallbackReadabilityProfile(
  palette: KernelPalette,
  source: ReadabilitySource = "palette",
): BackdropReadabilityProfile {
  const samples = [palette.bg, ...palette.accents, palette.ink];
  const evaluation = preferredEvaluation(samples, palette.theme === "dark" ? "light" : "dark");
  return buildProfile(samples, evaluation, source);
}

export function profileMeetsWcag(profile: BackdropReadabilityProfile): boolean {
  return profile.contrastRatio + 0.0001 >= NORMAL_TEXT_CONTRAST;
}
