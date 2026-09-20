/**
 * Mycelium Mesh kernel — a glowing, breathing mycelial transport network.
 *
 * Domain-warped ridged fbm knits a web of luminous veins that knit, thicken and
 * branch like a living slime-mold (Physarum) transport network. Two octaves of
 * a `ridged` fbm (`1 - |2·fbm - 1|`, squared) carve thin filaments out of a
 * twice-warped coordinate field; a slow `breathe` term keyed to a low-frequency
 * fbm modulates the whole web so it pulses. The pointer is a **nutrient source**:
 * an inverse-square `pull` displaces the inner warp toward the cursor, so the
 * network visibly reaches for it. Bright `nodes` (high powers of the vein field)
 * spark at the junctions and pick up the accent ramp.
 *
 * This file ships the **single-pass WebGL2 vein approximation** that runs today
 * on the same renderable set as `aurora` / `fluid-aurora`: one fullscreen
 * triangle, RGBA8, no sim, no float target. The "honest" Physarum agent
 * simulation (millions of sensing/depositing agents on a ping-pong trail field)
 * is a **WebGPU compute** upgrade for the future; this fragment shader
 * approximates that emergent vein look with multi-octave domain-warped ridged
 * noise so the world is available now and never black.
 *
 * Distinct from its cousins:
 *   - aurora / fluid-aurora: domain-warped fbm *ribbons* (smooth vertical
 *     curtains), not a ridged, branching *vein lattice* with junction nodes.
 *   - blobs-mesh / mesh: gradient-blended anchor fields (broad color washes).
 *   - inversion-lattice / moire: deterministic fractal / interference lattices.
 *   None of these is the "ridged domain-warped transport network that reaches
 *   toward a nutrient source" idiom.
 *
 * Single-pass GLSL ES 3.00 via {@link createShaderKernel}; color is 100%
 * palette-driven (`uBg`, `accentRamp`, `uInk`, `uIntensity`) and theme-branched
 * (`uTheme`). Aurora cousin for menu / theme wiring.
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Mycelium Mesh — domain-warped ridged-fbm transport network ────────────
// Ridged fbm filament: folds an fbm field into a thin bright ridge. Declared
// before renderKernel so it is in scope at the call sites below. Every fbm()
// call passes a vec3 (the chunk's signature is float fbm(vec3)).
float ridged(vec2 p) {
  float v = fbm(vec3(p, 0.0));
  v = 1.0 - abs(2.0 * v - 1.0);
  return v * v;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 aspect = vec2(uResolution.x / uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * aspect;
  float t = uTime * 0.05;

  // ── Pointer nutrient source: inverse-square pull toward the cursor ──
  vec2 nutrient = (uPointer - 0.5) * aspect;
  float pull = uPointerActive * 0.35 / (0.15 + dot(p - nutrient, p - nutrient));

  // ── Two-stage domain warp (the network's meandering coordinate field) ──
  vec2 q = vec2(
    fbm(vec3(p * 1.3 + vec2(0.0, t), 0.0)),
    fbm(vec3(p * 1.3 + vec2(5.2, -t), 0.0))
  );
  vec2 r = vec2(
    fbm(vec3(p * 2.1 + 2.0 * q + vec2(1.7, 9.2) + pull, 0.0)),
    fbm(vec3(p * 2.1 + 2.0 * q + vec2(8.3, 2.8) - pull * 0.5, 0.0))
  );

  // ── Ridged veins: a coarse trunk + a finer capillary octave ──
  float veins = ridged(p * 3.0 + 3.0 * r + t);
  veins += 0.45 * ridged(p * 7.0 + 4.0 * r - t * 1.3);
  veins = clamp(veins, 0.0, 1.0);

  // ── Breathing: the whole web pulses on a low-frequency fbm phase ──
  float breathe = 0.85 + 0.15 * sin(uTime * 0.4 + fbm(vec3(p * 0.6, 0.0)) * 6.2831);
  veins *= breathe;

  // ── Dark theme: luminous veins over deep ink, with sparking nodes ──
  vec3 col = uBg;
  vec3 net = accentRamp(veins);
  col = mix(col, net, smoothstep(0.25, 0.9, veins));
  col = mix(col, uInk, smoothstep(0.82, 1.0, veins) * 0.6);
  float nodes = pow(veins, 6.0);                 // bright junction sparks
  col += accentRamp(0.5 + 0.5 * sin(t)) * nodes * 0.6;

  // ── Light theme: keep veins as ink-on-pearl, never blown-out glow ──
  if (uTheme > 0.5) {
    col = mix(uBg, mix(uBg, net, 0.7), smoothstep(0.25, 0.95, veins));
    col = mix(col, uInk, smoothstep(0.8, 1.0, veins) * 0.25);
  }

  // ── Vignette (keeps foreground text legible) ──
  float vig = smoothstep(1.25, 0.2, length(p));
  col *= mix(0.55, 1.0, vig);

  col *= uIntensity;
  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;

export function createMyceliumMeshKernel(): Kernel {
  return createShaderKernel({
    id: "mycelium-mesh",
    label: "Mycelium Mesh",
    body: BODY,
  });
}
