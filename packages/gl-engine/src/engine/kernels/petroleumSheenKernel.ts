/**
 * Petroleum Sheen kernel — physically-flavoured thin-film iridescence on a
 * slow-flowing oil film floating over deep water.
 *
 * The colour is not painted; it is *computed* from interference, the same way a
 * real oil slick makes its rainbow. A domain-warped fbm field is read as the
 * film THICKNESS `d(x,y,t)` (nm); the optical path difference of light bouncing
 * off the top and bottom of the film, `opd = 2·n·d·cosθ`, sets a per-wavelength
 * phase. Sampling that phase at three representative wavelengths (R 680 / G 550 /
 * B 440 nm) gives `0.5 + 0.5·cos(2π·opd/λ)` per channel — the canonical
 * Belcour–Barla "practical microfacet thin-film" approximation, reduced to its
 * art-directable spectral core. Where the thickness gradient is steep the bands
 * crowd into tight rainbow filaments; where it is flat, broad sheets of colour
 * pool — exactly the signature of petroleum on a wet road.
 *
 * MATERIAL
 *   • thickness ranges over several interference orders (≈120…1850 nm) so the
 *     slick shows multiple nested rainbows, not one soft gradient;
 *   • a Fresnel grazing term brightens the film at the puddle's rim;
 *   • the spectral rainbow is gently rotated through the house accent ramp so the
 *     slick reads on-brand without losing its petroleum identity;
 *   • a wet specular glint (uAccent2) rides the brightest, thinnest film.
 *
 * MOTION — the film FLOWS: two stacked domain warps advect the thickness field
 *   on a slow ~0.04 Hz current, so the rainbow sheets drift, stretch and marble
 *   as one coherent surface. The pointer presses the surface: a local thickness
 *   swell + a ring ripple radiates from the cursor (touching oil on water).
 *
 * THEME
 *   DARK → the sheen floats ADDITIVELY over deep oily water (uBg), glinting;
 *   LIGHT → a pale pearlescent puddle, the sheen composited source-over with a
 *   hard-capped intensity so the bright canvas never blows out. A vignette keeps
 *   foreground text legible in both.
 *
 * DISTINCT from the existing kernels:
 *   - oilfield: an anisotropic-Kuwahara PAINTERLY filter (flat brush patches);
 *     this computes spectral thin-film INTERFERENCE (rainbow bands), not paint.
 *   - iridescence / mesh: smooth gradient-blended fields (no λ-indexed bands).
 *   - suminagashi-drift: closed-form marbling deformation maps (no interference).
 *   None of these derive colour from an optical-path-difference phase — the
 *   "computed oil-slick rainbow" idiom is unique to this kernel.
 *
 * Single-pass GLSL ES 3.00 via {@link createShaderKernel}; RGBA8, no sim, no
 * float target — the same renderable set as oilfield / fluid-aurora. Colour is
 * 100% palette-driven (uBg, accentRamp, uAccent2, uInk, uIntensity) and
 * theme-branched (uTheme), so a custom palette recolours the whole slick.
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Petroleum Sheen — computed thin-film interference on a flowing oil film ──
const float TAU = 6.28318530718;

// Three-wavelength thin-film interference (Belcour-Barla spectral core):
// reflectance per channel from the optical path difference opd (nm).
vec3 thinFilm(float opd) {
  vec3 lambda = vec3(680.0, 550.0, 440.0);   // R, G, B representative wavelengths
  vec3 phase = (TAU * opd) / lambda;
  vec3 r = 0.5 + 0.5 * cos(phase);            // first-order Airy term
  // a faint second harmonic crisps the filaments without muddying the hue.
  r += 0.12 * (0.5 + 0.5 * cos(2.0 * phase));
  return pow(clamp(r / 1.12, 0.0, 1.0), vec3(1.35));
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float asp = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(asp, 1.0);
  vec2 ptr = (uPointer - 0.5) * vec2(asp, 1.0);
  float t = uTime * 0.04;

  // ── Oil film thickness field: two stacked domain warps → a marbled flow ──
  vec2 q = vec2(
    fbm(vec3(p * 1.6 + vec2(0.0, t), 0.0)),
    fbm(vec3(p * 1.6 + vec2(4.3, -t), 1.7))
  );
  vec2 r = vec2(
    fbm(vec3(p * 2.2 + 1.7 * q + vec2(t * 0.7, 0.0), 2.0)),
    fbm(vec3(p * 2.2 + 1.7 * q + vec2(0.0, -t * 0.6), 4.0))
  );
  float base = fbm(vec3(p * 1.9 + 2.0 * r, t * 0.3));
  base = 0.5 + 0.5 * base;

  // Pointer press — a thickness swell + an outgoing ring ripple (touching oil).
  float pd = length(p - ptr);
  base += uPointerActive * 0.45 * exp(-pd * pd * 10.0) * sin(pd * 20.0 - uTime * 3.0);

  // Map to a physical film thickness spanning several interference orders (nm).
  // Clamped to a positive floor so the OPD never implies a negative film.
  float thickness = clamp(120.0 + 1730.0 * clamp(base, 0.0, 1.0) + 360.0 * r.x, 80.0, 2200.0);

  // Incidence varies across the puddle (grazing toward the rim) → angle shift.
  float cosTheta = clamp(1.0 - 0.34 * length(p), 0.42, 1.0);

  // ── Thin-film interference colour from the optical path difference ──
  float filmIOR = 1.32;                        // oil over water
  float opd = 2.0 * filmIOR * thickness * cosTheta;
  vec3 sheen = thinFilm(opd);

  // Rotate the spectral rainbow through the house accents (on-brand, still oil).
  float hueIdx = fract(opd / 1500.0 + 0.04 * t);
  vec3 tint = accentRamp(hueIdx);
  sheen = mix(sheen, sheen * (0.55 + 0.9 * tint), 0.5);

  // Fresnel grazing term brightens the rim; specular glint on the thinnest film.
  float fres = pow(1.0 - cosTheta, 3.0);
  float thinSpot = smoothstep(0.0, 0.18, 1.0 - clamp(thickness / 360.0, 0.0, 1.0));
  float glint = thinSpot * smoothstep(0.6, 1.0, base);

  vec3 col;
  if (uTheme < 0.5) {
    // DARK — sheen floats additively over deep oily water.
    vec3 deep = uBg + uBg * 0.35 * r.y;        // faint depth mottling
    col = deep + sheen * (0.42 + 0.6 * fres + 0.5 * base) * uIntensity;
    col += uAccent2 * glint * 0.5 * uIntensity; // wet specular glint
  } else {
    // LIGHT — a pale pearlescent puddle; capped so the canvas never blows out.
    vec3 pearl = mix(uBg, sheen, 0.42 + 0.30 * base);
    pearl = mix(pearl, uInk, 0.05 * (1.0 - base)); // settle deep film toward ink
    col = pearl;
    col += uAccent2 * glint * 0.16;
  }

  // Vignette — keeps foreground text legible.
  float vig = smoothstep(1.18, 0.28, length(p));
  col *= mix(0.6, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;

export function createPetroleumSheenKernel(): Kernel {
  return createShaderKernel({
    id: "petroleum-sheen",
    label: "Petroleum Sheen",
    body: BODY,
  });
}
