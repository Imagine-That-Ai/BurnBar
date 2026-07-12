/**
 * Retro Plasma kernel — "Second Reality plasma", a 1993 demoscene port.
 *
 * The PLASMA part of *Second Reality* by **Future Crew** (Assembly 1993,
 * released as the source code / algorithm in countless 1990s cracked-game
 * intros and demoscene prods) is the canonical "hidden gem" of the demoscene
 * fragment-shader tradition. Its entire visual is produced by FOUR sine calls
 * summed together, plus a single colour-palette lookup. ~10 lines of GLSL.
 *
 * The trick (deceptively simple, that's the demoscene joke): four 2D sine
 * waves, each with its own wavenumber, direction, and phase offset, are
 * summed into one scalar `v` in roughly [-4, +4]. Because the four waves
 * interfere at every pixel with different periods in x, y, x+y, and r, the
 * iso-contours of `v` produce the iconic flowing organic ribbons. Mapping
 * `v` through IQ's cosine palette (`a + b·cos(2π(c·t+d))`) — itself a
 * one-liner — yields the saturated rainbow that 1993 demoscene intros shipped
 * with as their boot screen.
 *
 *   p = (fragCoord - 0.5*uResolution) / uResolution.y   // aspect-correct
 *   v = sin(p.x*8 + t) + sin(p.y*8 + t) + sin((p.x+p.y)*5 + t)
 *       + sin(sqrt(p.x² + p.y²)*7 + t)                // THE formula
 *   col = palette((v + 4.0) / 8.0)                     // IQ palette
 *
 * Why distinct from the existing 22 kernels:
 *   - aurora / fluid-aurora: domain-warped FBM ribbons (heavy noise).
 *   - cloudfield: 280-char demoscene raymarched VOLUME (3D).
 *   - moire: N-wave SUM of cosines (THIS is sum of SINES, + time domain).
 *   - iridescence: physics-driven Airy thin-film reflectance.
 *   - plasma-orbs: 6 orbiting metaball orbs (object metaphor, not a field).
 *   - mesh / blobs-mesh: gradient-blended anchor fields.
 *   - halftone: dot screens. attractor / cgl / spiral / fluid / wave: sims.
 *   None of these is the "1993 four-sine summed field" idiom — a primitive
 *   that visually *predates* domain warping by a decade and is still the
 *   single most-recognised demoscene fragment shader.
 *
 * Pure fragment shader via {@link createShaderKernel}; no per-frame JS, no
 * sim, no float target — runs on the same set as iridescence/halftone/mesh.
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Second-Reality-style plasma (Future Crew, 1993) ───────────────────────
// Four sine waves with coprime wavenumbers + per-channel phase clocks.
// Sum range is roughly [-4, +4]; we normalise to [0,1] for the palette.
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // ── Time clocks (multi-frequency so the loop never visibly repeats) ──
  // Master drift + slower horizontal sweep. The original 1993 prod used
  // a single t; we add a second clock so the screen never quite returns.
  float t1 = uTime * 0.62;
  float t2 = uTime * 0.31;
  float t3 = uTime * 0.83;

  // ── THE formula — four sines, that's it ────────────────────────────────
  // Future Crew's canonical plasma; wavenumbers are coprime so the iso-
  // contours never tile. Each term gets its own phase clock.
  float v = sin(p.x * 8.0 + t1)
          + sin(p.y * 7.0 + t2 * 1.07)
          + sin((p.x + p.y) * 5.0 + t3 * 0.91)
          + sin(sqrt(p.x * p.x + p.y * p.y) * 7.0 - t1 * 0.83);

  // Pointer warp (subtle; the host already smooths uPointer 8%/frame).
  if (uPointerActive > 0.5) {
    vec2 cursor = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float d = distance(p, cursor);
    v += 1.2 * exp(-d * d * 5.0) * sin(uTime * 0.5 + d * 12.0);
  }

  // ── IQ cosine palette (a + b·cos(2π(c·t + d))) — one line, full rainbow ──
  // The famous IQ "cheap procedural palette" (iquilezles.org/articles/palettes).
  // t is the normalised plasma value, plus a slow phase roll so the rainbow
  // never sits at one fixed hue.
  float t = (v + 4.0) * 0.125 + uTime * 0.018;
  vec3  a = vec3(0.50, 0.50, 0.50);
  vec3  b = vec3(0.50, 0.50, 0.50);
  vec3  c = vec3(1.00, 1.00, 0.50);  // R oscillates 1x, G 1x, B 0.5x → rainbow
  vec3  d2 = vec3(0.80, 0.90, 0.30); // per-channel phase offset
  vec3  paletteCol = a + b * cos(6.28318531 * (c * t + d2));

  // ── Theme composite — original 1993 plasma was RGB-on-black, period. ────
  // We theme-key it so the family's light theme doesn't blow out, but the
  // PLASMA IS THE POINT: dark theme is the canonical look, light theme is a
  // pearl deposit that preserves the spectral interference (never muddied).
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: classic plasma on deep ink. Filmic knee keeps the brightest
    // ribbons from burning to flat white; faint airglow floor prevents dead
    // black in the troughs.
    col = uBg + paletteCol * (0.95 * uIntensity);
    col = col / (col + vec3(0.55));
    col *= 1.18;
    col += vec3(0.05, 0.06, 0.10) * 0.4;  // airglow grain floor
  } else {
    // LIGHT: pearl deposit — the rainbow stays vivid because the palette
    // already lives in [0,1], but the brightness is mapped onto the warm
    // paper background instead of pure black. uIntensity ~ 0.78 here.
    float lum = clamp(dot(paletteCol, vec3(0.45)) * 1.6, 0.0, 1.0);
    vec3  pearl = mix(uBg, paletteCol, 0.80);
    col = mix(uBg, pearl, lum * 0.62 * uIntensity);
    col = mix(col, uInk, smoothstep(0.55, 0.95, lum) * 0.045 * uIntensity);
  }

  // ── Pointer halo (subtle; matches the family idiom) ────────────────────
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.18
         * (uTheme < 0.5 ? 1.0 : 0.55);
  }

  // ── Vignette (protects glass-type legibility over the ribbons) ─────────
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);

  return col;   // MAIN() adds dither() + clamps to [0,1]
}
`;

export function createRetroPlasmaKernel(): Kernel {
  return createShaderKernel({
    id: "retro-plasma",
    label: "Retro Plasma",
    body: BODY,
  });
}
