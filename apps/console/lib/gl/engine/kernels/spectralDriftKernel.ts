/**
 * Spectral Drift kernel — anisotropic Gabor (sparse-convolution) noise.
 *
 * Soft oriented ribbons of band-limited noise — like brushed metal or
 * wind-combed sand — whose dominant orientation drifts over time and bends
 * near the pointer. The field is built by Lagae et al.'s sparse Gabor
 * convolution (SIGGRAPH 2009): scatter a few randomly-placed, randomly-phased
 * Gabor kernels per grid cell, sum a 3×3 neighborhood of cells, and the
 * envelope of windowed cosines reads as anisotropic, band-limited noise. Each
 * impulse is a Gaussian-windowed cosine `win·cos(2π·FREQ·⟨d,dir⟩ + φ)`; the
 * shared kernel orientation `gAng` rotates slowly with time, and a localized
 * `atan`-of-offset term swings it near an active pointer so the grain combs
 * around the cursor. The normalized accumulator drives the shared accent ramp
 * (theme-branched), with a thin zero-crossing ink seam and a vignette.
 *
 * Distinct from the existing kernels:
 *   - aurora / fluid-aurora: domain-warped FBM ribbons (smooth multifractal,
 *     no oriented carrier wave).
 *   - moire: a sum of full-plane cosines (global interference, not localized,
 *     randomly-placed band-limited impulses).
 *   - mesh / blobs-mesh: gradient-blended anchor fields (no carrier frequency).
 *   - inversion-lattice / gyroid: iterated fractal / raymarched surface.
 *   None of these is the "sparse Gabor convolution / oriented band-limited
 *   grain" idiom — a procedural-noise primitive with an explicit orientation
 *   and bandwidth that can be steered locally.
 *
 * Single-pass GLSL ES 3.00 via {@link createShaderKernel}; RGBA8, no sim, no
 * float target — runs on the same renderable set as fluid-aurora / mesh. Color
 * is 100% palette-driven (`uBg`, `accentRamp`, `uInk`, `uIntensity`) and
 * theme-branched (`uTheme`).
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Spectral Drift — anisotropic Gabor (sparse-convolution) noise ─────────
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5);
  p.x *= aspect;

  // ── Gabor parameters (compile-time constants → unrollable loop) ──
  const float FREQ = 9.0;   // carrier frequency of each impulse
  const float BW   = 5.0;   // Gaussian window bandwidth (larger ⇒ tighter)
  const float SCALE = 4.0;  // cells across the (aspect-corrected) field
  const int   IMP  = 2;     // impulses per grid cell

  float t = uTime * 0.15;

  // ── Drifting dominant orientation; bends near an active pointer ──
  float gAng = t * 0.6 + 1.2;
  if (uPointerActive > 0.5) {
    vec2 ptr = (uPointer - 0.5);
    ptr.x *= aspect;
    vec2 pd = p - ptr;
    gAng += atan(pd.y, pd.x) * 0.5 * exp(-3.5 * dot(pd, pd));
  }

  // ── Sparse Gabor convolution over a 3×3 cell neighborhood ──
  vec2 g = p * SCALE;
  vec2 cellId = floor(g);
  vec2 f = fract(g);
  float acc = 0.0;
  float wsum = 0.0;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 cId = cellId + vec2(float(i), float(j));
      for (int k = 0; k < IMP; k++) {
        vec3 hid = vec3(cId, float(k));
        float ha = fract(sin(dot(hid, vec3(127.1, 311.7, 74.7))) * 43758.5453);
        float hb = fract(sin(dot(hid, vec3(269.5, 183.3, 246.1))) * 23421.6310);
        float hc = fract(sin(dot(hid, vec3(113.5, 271.9, 124.6))) * 14375.5964);
        vec2 d = (vec2(float(i), float(j)) + vec2(ha, hb)) - f;
        float r2 = dot(d, d);
        float win = exp(-BW * r2);                 // Gaussian envelope
        float ang = gAng + (hc - 0.5) * 2.5;       // per-impulse orientation jitter
        vec2 dir = vec2(cos(ang), sin(ang));
        float phase = 6.2831853 * FREQ * dot(d, dir) + t * 4.0 * (ha - 0.5);
        float weight = hb * 2.0 - 1.0;             // signed amplitude
        acc += weight * win * cos(phase);
        wsum += win;
      }
    }
  }
  float n = clamp((acc / max(wsum, 1e-3)) * 1.3, -1.0, 1.0);

  // ── Palette mapping (theme-branched) ──
  vec3 ramp = accentRamp(n * 0.5 + 0.5);
  // DARK: ribbons emerge from the deep ink bg, brightest at the crests/troughs.
  vec3 darkCol = mix(uBg, ramp, 0.55 + 0.35 * abs(n));
  // LIGHT: the same grain deposited as soft pigment on the warm paper bg.
  vec3 lightCol = mix(uBg, mix(ramp, uInk, 0.18), 0.42 + 0.4 * abs(n));
  vec3 col = (uTheme < 0.5) ? darkCol : lightCol;

  // ── Thin zero-crossing ink seam between ribbons ──
  float band = smoothstep(0.045, 0.0, abs(n));
  col = mix(col, uInk, band * 0.22 * uIntensity);

  col *= uIntensity;

  // ── Vignette (keeps foreground text legible) ──
  float vig = smoothstep(1.15, 0.25, length(uv - 0.5) * 1.4);
  col *= mix(0.58, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;

export function createSpectralDriftKernel(): Kernel {
  return createShaderKernel({
    id: "spectral-drift",
    label: "Spectral Drift",
    body: BODY,
  });
}
