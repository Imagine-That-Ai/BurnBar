/**
 * Inversion Lattice kernel — a 2D Apollonian / circle-inversion fractal.
 *
 * Infinitely-nested luminous rings produced by iterating a fold-then-invert
 * map. Each step folds the plane into the unit cell
 * (`z = -1 + 2·fract(0.5·z + 0.5)`) and then applies a circle inversion
 * (`z *= ir / (|z|² + ε)`). The inversion contracts space toward circle nests,
 * so a fixed 8-step loop resolves rings-within-rings (the Apollonian gasket
 * idiom) down to the pixel. A distance-estimator edge (`abs(z.y)/scale`, AA'd
 * with `fwidth`) gives crisp ring filaments; an orbit-trap term
 * (`exp(-6·trap)`) adds the soft halo. Hue rolls through the shared accent ramp
 * via the accumulated inversion scale + fold phase, so the brand palette + theme
 * tints flow through every frame.
 *
 * Distinct from the existing kernels:
 *   - aurora / fluid-aurora: domain-warped FBM ribbons (vertical curtains).
 *   - moire: N-wave sum of cosines (interference lattice, not a fractal map).
 *   - gyroid: a 3D raymarched minimal surface (volume, not a 2D inversion).
 *   - mesh / blobs-mesh: gradient-blended anchor fields.
 *   None of these is the "iterated circle-inversion / Apollonian ring nest"
 *   idiom — a self-similar 2D fractal that nests rings within rings forever.
 *
 * Single-pass GLSL ES 3.00 via {@link createShaderKernel}; RGBA8, no sim, no
 * float target — runs on the same renderable set as fluid-aurora / retro-plasma.
 * Color is 100% palette-driven and theme-branched.
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Inversion Lattice — 2D Apollonian / circle-inversion fractal ──────────
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 R = uResolution;
  vec2 p = (fragCoord - 0.5 * R) / R.y;

  // ── Living transform: slow rotation + breathing zoom + pointer parallax ──
  float tt = uTime * 0.08;
  float zoom = 1.18 + 0.16 * sin(uTime * 0.13);
  p *= zoom;
  float ca = cos(tt), sa = sin(tt);
  p = mat2(ca, -sa, sa, ca) * p;
  p += (uPointer - 0.5) * 0.12 * uPointerActive;

  // ── Circle-inversion fold loop (Apollonian nesting), fixed 8 steps ──
  float ir = 1.06 + 0.12 * sin(uTime * 0.2);   // inversion radius, breathing
  vec2 z = p;
  float scale = 1.0;
  float kAcc = 0.0;
  float trap = 1e9;
  const int STEPS = 8;
  for (int i = 0; i < STEPS; i++) {
    z = -1.0 + 2.0 * fract(0.5 * z + 0.5);     // fold into the unit cell
    float r2 = dot(z, z);
    float k = ir / (r2 + 1e-6);                 // circle inversion
    z *= k;
    scale *= k;
    kAcc += k;
    trap = min(trap, abs(r2 - 0.5));            // orbit trap (ring halo)
  }

  // ── Distance-estimator ring edge (fwidth-AA) + orbit-trap glow ──
  float sc = max(scale, 1e-6);                  // guard log()/division below
  float de = abs(z.y) / sc;
  float w = fwidth(de) + 1e-4;
  float line = 1.0 - smoothstep(0.0, 2.6 * w, de);
  float glow = exp(-6.0 * trap);
  float shape = clamp(line + 0.55 * glow, 0.0, 1.0);

  // ── Palette hue from inversion scale + fold accumulation ──
  float fold = fract(0.06 * log(sc) + 0.16 * kAcc - 0.08 * uTime);
  vec3 ramp = accentRamp(fold);
  vec3 base = uBg;

  // ── Theme composite ──
  // DARK: luminous rings added over deep ink (the canonical look).
  vec3 lumRings = base + mix(uInk, ramp, 0.85) * shape * (0.6 + 0.8 * uIntensity);
  lumRings += ramp * 0.04 * (0.5 + 0.5 * sin(log(sc) * 1.5));   // faint scale shimmer
  // LIGHT: ink-deposit rings on the warm paper bg (never blows out).
  vec3 inkRings = mix(base, mix(ramp, uInk, 0.55), shape * (0.5 + 0.6 * uIntensity));

  vec3 col = (uTheme < 0.5) ? lumRings : inkRings;

  // ── Vignette (keeps foreground text legible) ──
  float vig = smoothstep(1.2, 0.35, length(uv - 0.5) * 1.4);
  col *= mix(0.82, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;

export function createInversionLatticeKernel(): Kernel {
  return createShaderKernel({
    id: "inversion-lattice",
    label: "Inversion Lattice",
    body: BODY,
  });
}
