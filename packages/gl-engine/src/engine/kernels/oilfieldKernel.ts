/**
 * Oilfield kernel — a living painting via the anisotropic-Kuwahara idiom.
 *
 * A slow-breathing fbm color field (`baseField`: domain-warped simplex/fbm fed
 * through the shared `accentRamp`) is re-rendered as oil-paint brush regions by
 * a classic 4-quadrant Kuwahara filter. Over a FIXED 7×7 window (i,j ∈ [-3,3])
 * the four overlapping quadrants each accumulate a mean color and a luminance
 * variance; the quadrant with the LOWEST variance wins, so flat palette-knife
 * patches form with crisp coherent edges — the canonical "painterly filter"
 * look (Kuwahara/Kyprianidis). A faint specular `sheen` on the brightest
 * patches reads as wet-paint highlight; the pointer locally widens the brush
 * stride so a cursor "drags" thicker strokes through the canvas.
 *
 * Distinct from the existing kernels:
 *   - aurora / fluid-aurora: domain-warped FBM ribbons (smooth gradients, no
 *     edge-preserving region flattening).
 *   - mesh / blobs-mesh: gradient-blended anchor fields (no painterly patches).
 *   - moire / retro-plasma: analytic interference / plasma (continuous, never
 *     quantized into flat brush regions).
 *   None of these run an edge-preserving Kuwahara window — the "flat coherent
 *   brush patches with crisp edges" idiom is unique to this kernel.
 *
 * PERF: the Kuwahara window is a COMPILE-TIME-CONSTANT 7×7 (`for j/i = -3..3`),
 * never a uniform-driven dynamic radius, so the loop unrolls and `baseField`
 * (one `fbm`, ≤3 octaves via the shared chunk) is called a fixed 49 times.
 * This is the heaviest display-pass kernel — see the plan's fallback ladder.
 *
 * Single-pass GLSL ES 3.00 via {@link createShaderKernel}; RGBA8, no sim, no
 * float target — same renderable set as fluid-aurora / inversion-lattice. Color
 * is 100% palette-driven (`uBg`, `accentRamp`, `uAccent2`, `uInk`, `uIntensity`)
 * and theme-branched (`uTheme`).
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Oilfield — anisotropic-Kuwahara painterly filter over an fbm field ────

// Slow-breathing, domain-warped fbm color field, mapped through the palette.
vec3 baseField(vec2 p) {
  float t = uTime * 0.05;
  vec2 q = vec2(
    fbm(vec3(p * 2.3 + vec2(0.0, t), 0.0)),
    fbm(vec3(p * 2.3 + vec2(5.2, -t), 0.0))
  );
  float n = fbm(vec3(p * 3.1 + 1.8 * q + vec2(t * 0.6, -t * 0.4), 0.0));
  n = 0.5 + 0.5 * snoise(vec3(p * 1.4 + n * 1.6 + t, 0.0));
  vec3 col = accentRamp(clamp(n, 0.0, 1.0));
  col = mix(uBg, col, 0.85);
  return col;
}

// Perceptual luminance (renamed to avoid any builtin/chunk collision).
float lumv(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  // Fixed brush stride in UV; pointer locally fattens the stroke.
  vec2 px = vec2(1.0 / uResolution.y) * 2.2;
  if (uPointerActive > 0.5) {
    float d = distance(uv, uPointer);
    px *= 1.0 + 0.9 * exp(-d * d * 22.0);
  }

  // Four overlapping quadrant accumulators (mean color + luminance sq-sum).
  vec3 mean0 = vec3(0.0), mean1 = vec3(0.0), mean2 = vec3(0.0), mean3 = vec3(0.0);
  float sq0 = 0.0, sq1 = 0.0, sq2 = 0.0, sq3 = 0.0;
  float cnt0 = 0.0, cnt1 = 0.0, cnt2 = 0.0, cnt3 = 0.0;

  // CONSTANT 7×7 window (radius 3) — compile-time loop bounds, unrolls clean.
  for (int j = -3; j <= 3; j++) {
    for (int i = -3; i <= 3; i++) {
      vec2 off = vec2(float(i), float(j)) * px;
      vec3 c = baseField(uv + off);
      float l = lumv(c);
      bool left = (i <= 0), right = (i >= 0), down = (j <= 0), up = (j >= 0);
      if (left && down)  { mean0 += c; sq0 += l * l; cnt0 += 1.0; }
      if (right && down) { mean1 += c; sq1 += l * l; cnt1 += 1.0; }
      if (left && up)    { mean2 += c; sq2 += l * l; cnt2 += 1.0; }
      if (right && up)   { mean3 += c; sq3 += l * l; cnt3 += 1.0; }
    }
  }

  // Pick the quadrant with the lowest luminance variance (flattest patch).
  vec3 outCol = vec3(0.0);
  float best = 1e9;
  vec3 m; float v;
  m = mean0 / max(cnt0, 1.0); v = sq0 / max(cnt0, 1.0) - lumv(m) * lumv(m); if (v < best) { best = v; outCol = m; }
  m = mean1 / max(cnt1, 1.0); v = sq1 / max(cnt1, 1.0) - lumv(m) * lumv(m); if (v < best) { best = v; outCol = m; }
  m = mean2 / max(cnt2, 1.0); v = sq2 / max(cnt2, 1.0) - lumv(m) * lumv(m); if (v < best) { best = v; outCol = m; }
  m = mean3 / max(cnt3, 1.0); v = sq3 / max(cnt3, 1.0) - lumv(m) * lumv(m); if (v < best) { best = v; outCol = m; }

  // Wet-paint sheen on the brightest patches (palette-tinted highlight).
  float sheen = pow(clamp(lumv(outCol) - 0.55, 0.0, 1.0), 2.0);
  outCol += sheen * 0.12 * uAccent2;

  // LIGHT theme: settle the patches toward ink so the bright canvas reads.
  outCol = mix(outCol, uInk, 0.06 * uTheme);

  outCol *= uIntensity;

  // Vignette (keeps foreground text legible).
  float vig = smoothstep(0.95, 0.35, length(uv - 0.5));
  outCol *= mix(0.78, 1.0, vig);

  return clamp(outCol, 0.0, 1.0);   // MAIN() appends dither() + clamps to [0,1]
}
`;

export function createOilfieldKernel(): Kernel {
  return createShaderKernel({
    id: "oilfield",
    label: "Oilfield",
    body: BODY,
  });
}
