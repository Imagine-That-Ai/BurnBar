/**
 * Blobs Mesh kernel — "Fluid Mesh Gradient": the SECOND most popular WebGL
 * background effect of 2026 on creative-developer portfolios, SaaS hero pages,
 * and design-tool marketplaces (the unhyphenated "mesh gradient" idiom that
 * stands beside fluid aurora as the other pillar of the year's backdrop stack).
 *
 * Concept: a small set of large, soft-edged colored "blobs" that wander via
 * low-frequency simplex noise and blend by inverse-square weight into a single
 * painterly gradient mesh. No iridescence, no caustics, no Fresnel rim, no
 * thin-film; just clean, slow, luminous color. Pointer-inert: the host's
 * smoothed uPointer uniform drags the collective centre a touch toward the
 * cursor, never a hard warp.
 *
 * Why this fills the gap vs the existing 22 kernels:
 *  - fluid-aurora (#1 mainstream, 2026): vertical curtain ribbons.
 *  - mesh (iridescent): inverse-square blend BUT layered with thin-film,
 *    ridged caustic seam, Fresnel oil-sheen rim, breathing grain — the slab
 *    looks like wet glass with interference, not a clean mesh.
 *  - plasma-orbs: 5-6 small hard-edged orbs with chromatic-aberration rim and
 *    oil-slick iridescence on the silhouette — the orb-cluster idiom, not the
 *    mesh-gradient idiom.
 *  - halftone / iridescence / fluid: structurally different (dot screens,
 *    wavelength interference, Navier–Stokes ink).
 *  - blob-mesh is the clean, painterly, NO-rim, NO-iridescence mesh gradient:
 *    four softly-blending blobs of palette color wandering through simplex
 *    noise, depositing the result as a luminous pearl (light) or additive
 *    bloom (dark) over uBg.
 *
 * Pure fragment shader via {@link createShaderKernel}; no per-frame JS, no
 * float target, no sim — runs on the same set as iridescence/halftone/plasma.
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
#define BLOB_COUNT 4

// Hash → unit range (Ashima/Gustavson-style, deterministic, no snoise).
float blobHash(float n){ return fract(sin(n) * 43758.5453123); }

// Inverse-square blob weight at point p for a blob centred at c with radius r.
// Soft-edge falloff: w = 1 / (r^2 + d^2) — the canonical "metaball-meets-mesh"
// weight. Returns POSITIVE density (additive across blobs).
float blobWeight(vec2 p, vec2 c, float r){
  vec2 d = p - c;
  float dd = dot(d, d);
  float rr = r * r;
  // Smooth the singularity: k = 1 when d=0, falls off smoothly. This is the
  // classic soft-min trick inverted — it preserves the gentle mesh feel without
  // a 1/0 spike at the centre.
  return rr / (rr + dd + 1e-4);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  // Aspect-correct centred coords (y up). p ∈ [-aspect/2 .. +aspect/2] × [-0.5..0.5].
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // ── Time clocks (multi-frequency so the loop never visibly repeats) ──
  float t    = uTime * 0.085;   // drift — slow, contemplative
  float tHue = uTime * 0.018;   // hue roll (very slow; colour identity holds)
  float tLow = uTime * 0.045;   // collective-centre drift

  // ── Domain warp: simplex noise displaces the sample coordinate so the
  //    blob boundaries flow like liquid (the 2026 "fluid mesh" feel). ONE
  //    shared fbm warp keeps the field as a single body. ──
  vec2 warp = 0.22 * vec2(
    fbm(vec3(p * 0.85,         tLow)),
    fbm(vec3(p * 0.85 + 5.2,   tLow))
  );
  vec2 pw = p + warp;

  // ── Collective centre (the whole mesh drifts on its own slow clock; the
  //    pointer nudges it gently, like a magnet) ──
  vec2 centre = 0.08 * vec2(sin(tLow * 1.7), cos(tLow * 1.3));
  if (uPointerActive > 0.5) {
    vec2 cursor = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    centre = mix(centre, cursor, 0.10); // soft pointer influence, never a dart
  }

  // ── Build the 4-blob mesh ──
  // Each blob's centre wanders around the collective centre via simplex noise,
  // its size breathes gently, its softness is per-instance so silhouettes vary.
  vec3 weightedColor = vec3(0.0);
  float weightSum = 0.0;
  float maxWeight = 0.0;   // strongest single-blob influence at p — the
                           // spatial key that keeps blob centres readable
                           // (a flat weightSum wash is what made the field
                           // read as a featureless gradient).

  for (int i = 0; i < BLOB_COUNT; i++) {
    float fi = float(i);
    float seed     = blobHash(fi * 1.3 + 0.7);
    float driftSpd = 0.55 + 0.45 * blobHash(fi * 2.1 + 1.9);
    float driftAmp = 0.32 + 0.20 * blobHash(fi * 3.7 + 4.1);
    // Two-axis wander via low-freq snoise — the "organic" feel.
    vec2  wander = vec2(
      snoise(vec3(pw * 0.6 + fi * 7.1,         t * driftSpd)),
      snoise(vec3(pw * 0.6 + fi * 7.1 + 12.3,  t * driftSpd))
    );
    float rad = 0.36 + 0.12 * blobHash(fi * 5.3 + 2.7);
    // Breathing radius — 5.7s/11s irrational pair, never phase-locks.
    float breathe = 1.0 + 0.12 * (
        0.62 * sin(uTime * 1.099 + seed * 6.2831) +
        0.38 * sin(uTime * 0.571 + seed * 6.2831 + 1.3)
    );
    rad *= breathe;

    // The blob's resting colour comes from a per-instance palette slot (the
    // existing accent ramp), with a tiny per-blob hue roll driven by tHue +
    // a deterministic per-instance offset.
    float hueT = fract(tHue + 0.13 * fi + 0.13 * blobHash(fi * 9.7 + 6.1));
    vec3  col  = accentRamp(hueT);

    // Quadrant anchor per blob: even angular spread + deterministic jitter.
    // Without it the four noise-driven centres can start on top of each
    // other, and the mesh opens as a featureless wash until they separate.
    float ang = fi * 1.5708 + blobHash(fi * 4.3 + 2.2) * 0.9;
    vec2 anchor = 0.34 * vec2(cos(ang), sin(ang));

    vec2 c = centre + anchor + driftAmp * wander;
    float w = blobWeight(pw, c, rad);
    weightedColor += col * w;
    weightSum += w;
    maxWeight = max(maxWeight, w);
  }

  // Normalise: weighted colour sum / total weight → the mesh colour at p.
  vec3 mesh = weightSum > 1e-4 ? weightedColor / weightSum : accentRamp(0.5);

  // ── Theme composite (timing identical; only the math flips) ──
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: additive bloom over deep ink; the mesh glows like a luminous
    // gradient poster. The maxWeight key concentrates the bloom at blob
    // centres and lets the gaps fall back toward the ink, so the blobs read
    // as distinct bodies instead of one saturated wash. Filmic knee keeps
    // the brightest blob-centres from burning to flat white.
    float key = smoothstep(0.12, 0.9, maxWeight);
    col = uBg;
    col += mesh * (0.95 * uIntensity) * (0.22 + 0.78 * key);
    col = col / (col + vec3(0.55));
    col *= 1.16;
    // Faint airglow floor (prevents "dead black" between blobs).
    col += vec3(0.06, 0.07, 0.12) * (1.0 - clamp(weightSum * 0.7, 0.0, 1.0)) * 0.35;
  } else {
    // LIGHT: pearl watermark — a soft, painterly gradient deposited on the
    // paper. Intensity is ~0.78 in light mode (palette.ts) so we never blow out.
    vec3 pearl = mix(uBg, mesh, 0.85);
    // Luminance key: brighter where weightSum is high (blob centres), darker
    // in the gaps. This gives the gradient a soft "spotlit" feel without
    // any hard rim or contour.
    float key = clamp(weightSum * 0.85, 0.0, 1.0);
    col = mix(uBg, pearl, key * 0.62 * uIntensity);
    // A whisper of ink gives the bright blob centres a soft contour.
    col = mix(col, uInk, smoothstep(0.55, 0.95, key) * 0.05 * uIntensity);
  }

  // ── Pointer wash: a soft, slow-cycling halo behind the cursor ──
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.08)) * halo * 0.16
         * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // ── Vignette (protects text legibility over the field) ──
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);

  return col;   // MAIN() adds dither() + clamps to [0,1]
}
`;

export function createBlobsMeshKernel(): Kernel {
  return createShaderKernel({
    id: "blobs-mesh",
    label: "Blobs Mesh",
    body: BODY,
  });
}
