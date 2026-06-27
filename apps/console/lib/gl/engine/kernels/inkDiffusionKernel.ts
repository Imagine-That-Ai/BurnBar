/**
 * Ink Diffusion kernel — ink bleeding into wet fibre, the chromatography way.
 *
 * Where suminagashi-drift floats ink on WATER (closed-form marbling deformation
 * maps), this kernel sinks ink into PAPER: each drop is a capillary diffusion
 * FRONT that wicks outward through the fibres, darkens at its advancing rim (the
 * coffee-ring / chromatography edge where pigment accumulates), and feathers
 * along the paper grain. The pigment also SEPARATES — like a chromatography
 * strip, the fast dye fraction runs ahead in a cooler hue while the slow
 * fraction lags warm — so every bleed blooms a soft spectral halo.
 *
 * MODEL (closed-form, single display pass — no sim target)
 *   • Each of N ink drops contributes a diffusion profile vs distance `r`:
 *       front  = smoothstep(R, R-soft, r)         — the wet wicking boundary
 *       edge   = a darkened ring just inside R     — pigment piled at the front
 *     The boundary radius R breathes and the whole field is FEATHERED by an fbm
 *     "fibre" field added to `r`, so the front ragged-wicks into the paper tooth
 *     instead of being a clean circle.
 *   • Drop ink amount accumulates (ADDITIVE saturation) so overlapping bleeds
 *     pool darker, exactly like layered washes.
 *   • Chromatographic separation: the dye fraction `sep = (R - r)/R` indexes the
 *     house accent ramp, so the running front is one hue and the saturated core
 *     another — a living, on-brand ink that still reads as ink.
 *
 * MOTION — the bleed GROWS and breathes: each drop's radius eases outward on a
 *   slow phase then holds and trembles, and the drop centres drift on a gentle
 *   value-noise current, so the field reads as ink still spreading through damp
 *   paper. The pointer wets the sheet: a fresh capillary bloom wicks from the
 *   cursor.
 *
 * THEME
 *   DARK → luminous ink suspended in a dark wash; the fronts glow additively.
 *   LIGHT → sumi ink on warm paper; composited source-over, fronts darkening the
 *   sheet (a stain), with hard-capped strength so the paper keeps its tooth.
 *   A faint fbm paper grain underlies both; a vignette keeps text legible.
 *
 * DISTINCT from the existing kernels:
 *   - suminagashi-drift: inverse drop/comb DEFORMATION maps on water (rings by
 *     pulling samples back); here rings come from a DIFFUSION front + edge-darken,
 *     additive, feathered into fibre — ink in paper, not ink on water.
 *   - oilfield: a Kuwahara painterly filter (flat brush patches).
 *   - aurora / fluid-aurora: smooth FBM ribbons (no wicking fronts).
 *   The "capillary chromatography bleed with a darkened wicking rim" idiom is
 *   unique to this kernel.
 *
 * Single-pass GLSL ES 3.00 via {@link createShaderKernel}; RGBA8, no sim, no
 * float target — same renderable set as suminagashi-drift. Colour is 100%
 * palette-driven (uBg, accentRamp, uInk, uAccent2, uIntensity) and theme-branched.
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Ink Diffusion — capillary chromatography bleed into wet fibre ──────────
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float asp = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(asp, 1.0);
  vec2 ptr = (uPointer - 0.5) * vec2(asp, 1.0);
  float t = uTime;

  // Paper-fibre feather field — a fine fbm that ragged-wicks every ink front and
  // also lays a faint laid-paper grain under the wash.
  float fibre = fbm(vec3(p * 5.5, t * 0.03));
  float grain = fbm(vec3(p * 22.0, 7.0)) * 0.5 + 0.5;

  // Accumulators: total ink (saturation) + a chromatographic hue index.
  float ink = 0.0;
  float hue = 0.0;
  float edge = 0.0;   // darkened wicking-rim accumulation

  // ── N drifting ink drops, each a breathing capillary diffusion front ──
  // Two interleaved scales: broad primary bleeds + finer secondary micro-bleeds,
  // so the field reads as a continuous oil-on-paper wash, not discrete blobs.
  const int NDROP = 9;
  for (int i = 0; i < NDROP; i++) {
    float fi = float(i);
    bool micro = (i >= 5);                  // the last 4 are small micro-bleeds
    // slow value-noise drift of the drop centre (the damp sheet creeping).
    float spread = micro ? 0.5 : 0.4;
    vec2 c = spread * vec2(sin(fi * 2.39 + t * 0.05), cos(fi * 1.71 - t * 0.045));
    c += 0.06 * vec2(fbm(vec3(fi, t * 0.07, 0.0)), fbm(vec3(fi + 9.0, 0.0, t * 0.07)));

    // boundary radius eases outward then holds + trembles — ink still spreading.
    float grow = 0.5 + 0.5 * sin(fi * 1.3 + t * 0.18);
    float baseR = micro ? 0.07 : 0.15;
    float R = baseR + (micro ? 0.05 : 0.12) * grow + 0.012 * sin(t * 0.9 + fi * 3.0);

    // feather the distance by the fibre field → a ragged wicking boundary.
    float r = length(p - c) + (fibre - 0.5) * 0.09;

    float soft = (micro ? 0.06 : 0.10) + 0.05 * grow;
    float front = smoothstep(R, R - soft, r);             // wet wicked interior
    // darkened rim: a thin band piled just inside the advancing front.
    float rim = smoothstep(R, R - soft * 0.45, r) * (1.0 - smoothstep(R - soft * 0.5, R - soft, r));

    ink += front * (0.6 + 0.4 * grain) * (micro ? 0.7 : 1.0);
    edge += rim;
    // chromatographic separation: fast dye runs to the front (low sep), slow
    // pigment piles at the core (high sep) → hue indexes the ramp. Widened span
    // (×1.15) so the spectral separation reads, offset per drop so hues vary.
    float sep = clamp((R - r) / max(R, 1e-3), 0.0, 1.0);
    hue += front * fract(sep * 1.15 + fi * 0.17 + 0.05 * t);
  }

  // Pointer bloom — a fresh capillary wick from the cursor.
  {
    float r = length(p - ptr) + (fibre - 0.5) * 0.07;
    float R = 0.18;
    float front = uPointerActive * smoothstep(R, R - 0.12, r);
    ink += front;
    edge += uPointerActive * smoothstep(R, R - 0.05, r) * (1.0 - smoothstep(R - 0.06, R - 0.12, r));
    hue += front * fract(0.3 + 0.05 * t);
  }

  float sat = clamp(ink, 0.0, 1.0);
  float hueIdx = ink > 1e-3 ? fract(hue / max(ink, 1e-3)) : 0.0;
  vec3 inkCol = accentRamp(hueIdx);

  vec3 col;
  if (uTheme < 0.5) {
    // DARK — luminous ink suspended in a dark wash; fronts glow additively.
    vec3 wash = uBg + uBg * 0.4 * (grain - 0.5);
    vec3 bleed = inkCol * (0.5 + 0.7 * sat);
    bleed = mix(bleed, uAccent2, 0.18 * sat);            // cool running front
    col = wash + bleed * sat * uIntensity;
    col -= edge * 0.22 * uIntensity;                     // rim darkening (pigment pile)
    col = max(col, 0.0);
  } else {
    // LIGHT — sumi ink staining warm paper; source-over, capped.
    vec3 paper = mix(uBg, uBg * 0.96, grain - 0.5);
    vec3 stain = mix(inkCol, uInk, 0.55);                // ink reads dark on paper
    col = mix(paper, stain, clamp(sat, 0.0, 0.9));
    col -= edge * 0.16;                                  // darker wicking rim
    col = max(col, uInk * 0.0);
  }

  // Vignette — keeps foreground text legible.
  float vig = smoothstep(1.16, 0.26, length(p));
  col *= mix(0.62, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;

export function createInkDiffusionKernel(): Kernel {
  return createShaderKernel({
    id: "ink-diffusion",
    label: "Ink Diffusion",
    body: BODY,
  });
}
