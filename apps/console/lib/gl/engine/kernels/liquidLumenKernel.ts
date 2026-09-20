/**
 * Liquid Lumen kernel — a soft 2D "lava-lamp" gooey color field.
 *
 * Many small inverse-square charges drift on lazy elliptical paths; their
 * densities sum into one continuous scalar `field`. A pair of smoothsteps lift a
 * flowing **surface** (`field > ~1.0`) and a thin **edge** band beneath it, so
 * the charges visibly *fuse* into a single molten gradient sheet (the classic
 * smooth-union / metaball merge) rather than reading as separate dots. Color is
 * not a silhouette tint — it is a `accentRamp` band driven by the surface mask
 * plus the field's flow-weighted centroid (`flow`), so the palette pours through
 * the merging blobs like dye in a lava lamp. A faint `fbm` wobble breaks the
 * banding; a soft halo and a single centroid "hot spot" add depth; a vignette
 * keeps foreground text legible.
 *
 * Distinct from `plasma-orbs` (the existing metaball kernel):
 *   - plasma-orbs renders a FEW (5–6) GLASSY orbs with a chromatic-aberration
 *     rim, an iridescent oil-slick ramp, and a filmic tonemap — a refracting
 *     "liquid chrome" look where each orb keeps its own glassy silhouette.
 *   - liquid-lumen renders MANY (7) SMALL charges that fuse into one SOFT,
 *     matte color field — no chrome, no refraction, no CA, no tonemap. The
 *     point is the flowing `accentRamp` band over the fused surface (a 2D
 *     lava-lamp gradient), not glass orbs in a void.
 *
 * Single-pass GLSL ES 3.00 via {@link createShaderKernel}; RGBA8, no sim, no
 * float target — same renderable set as `aurora` / `fluid-aurora`. Color is
 * 100% palette-driven (`uBg`, `accentRamp`, `uAccent2/3`, `uInk`, `uIntensity`)
 * and theme-branched (`uTheme`).
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Liquid Lumen — fusing charges → a flowing lava-lamp color field ────────
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5); p.x *= aspect;

  // ── Fixed charge cluster: each drifts on its own ellipse; densities sum ──
  const int N = 7;
  float field = 0.0; vec2 flow = vec2(0.0); float t = uTime * 0.27;
  for (int i = 0; i < N; i++){
    float fi = float(i);
    float sp = 0.6 + 0.35 * fract(sin(fi * 12.9898) * 43758.5453);
    float ph = fi * 2.39996;
    float rx = 0.34 + 0.12 * sin(fi * 1.7), ry = 0.30 + 0.13 * cos(fi * 2.3);
    vec2 c = vec2(
      rx * sin(t * sp + ph) + 0.08 * sin(t * 1.7 + fi),
      ry * cos(t * sp * 0.9 + ph * 1.3) + 0.07 * cos(t * 1.3 + fi)
    );
    // Last charge follows the (smoothed) pointer so the field leans toward it.
    if (i == N - 1 && uPointerActive > 0.5){
      vec2 pp = (uPointer - 0.5); pp.x *= aspect; c = mix(c, pp, 0.85);
    }
    float rad = 0.030 + 0.018 * (0.5 + 0.5 * sin(fi * 3.1 + t));
    vec2 d = p - c; float g = rad / (dot(d, d) + 0.0008);
    field += g; flow += c * g;
  }
  flow /= max(field, 1e-4);                       // flow-weighted centroid

  // ── Smooth-union surface + thin fused edge band ──
  float surf = smoothstep(0.85, 1.35, field);
  float edge = smoothstep(0.65, 0.95, field) - surf;

  // ── Palette band: surface mask + flow + a faint fbm wobble ──
  float rampT = 0.15 + 0.55 * surf + 0.30 * (flow.x * 0.5 + 0.5);
  rampT += 0.06 * fbm(vec3(p * 2.5, t));
  vec3 blob = accentRamp(clamp(rampT, 0.0, 1.0));

  bool light = uTheme > 0.5;
  vec3 col = uBg;
  col = mix(col, blob, surf);

  // ── Rim accent on the fused edge (paper-bright in light, accent-lit in dark) ──
  vec3 rim = light ? mix(blob, vec3(1.0), 0.65) : (blob + uAccent2 * 0.6);
  col += rim * edge * (light ? 0.5 : 0.9);

  // ── Soft halo just outside the surface, and a single centroid hot spot ──
  float halo = smoothstep(0.25, 0.85, field) * (1.0 - surf);
  col += blob * halo * (light ? 0.12 : 0.28);
  float spec = exp(-6.0 * length(p - flow));
  col += (light ? vec3(0.9) : uAccent3) * spec * 0.18 * surf;

  // ── Light-only ink deepening inside the surface; intensity gain ──
  col = mix(col, mix(col, uInk, 0.06), surf * (light ? 1.0 : 0.0));
  col *= mix(0.85, 1.25, uIntensity);

  // ── Vignette (protects text legibility over the field) ──
  float vig = smoothstep(1.15, 0.35, length((uv - 0.5) * vec2(aspect, 1.0)));
  col *= mix(light ? 0.92 : 0.78, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;

export function createLiquidLumenKernel(): Kernel {
  return createShaderKernel({
    id: "liquid-lumen",
    label: "Liquid Lumen",
    body: BODY,
  });
}
