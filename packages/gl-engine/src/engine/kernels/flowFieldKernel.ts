/**
 * Flow Field kernel — "Luminous Silk" (WebGL2).
 *
 * Pure fragment-shader silk streamlines. Replaces the old Canvas2D tracer
 * swarm (thousands of quadratic silk strands) with a Bridson curl-noise wind
 * and short per-fragment streamline integration (LIC-lite accumulation) so
 * the field reads as continuous luminous ribbons — not stipple dots and not
 * the heavy blue-noise convolution of `lic` (Flow Imaging).
 *
 * Technique:
 *  - Divergence-free wind = curl of a scalar snoise potential (Bridson 2007).
 *    Streamlines of curl(ψ) are iso-contours of ψ, so iso-level peaks of ψ
 *    become coherent silk strands when accumulated along the path.
 *  - Dual depth strata (broad slow back / fine fast front) with parallax.
 *  - 14s/31s irrational breath LFO modulates field strength + brightness.
 *  - Traveling light-bead phase along each strand (standing wave of light).
 *  - Pointer bow-wave: tangential swirl around the cursor.
 *  - Theme-branched palette silk (dark: bright on ink; light: ink on paper).
 *  - Vignette for type legibility.
 *
 * Perf: dual strata × 2 dirs × 6 Euler steps × 3 snoise/curl ≈ 72 snoise/frag
 * (+ centre taps / bead / haze) — under the lic Lite tier (~87), locked 60fps
 * on integrated GPUs. RGBA8 single-pass, no float target.
 *
 * Single-pass GLSL ES 3.00 via {@link createShaderKernel}. Opts into the shared
 * D2 scroll control block so scroll still scrubs the wind time axis and injects
 * a soft gust (parity with the old 2D kernel's reactive layers).
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Luminous Silk — curl-noise streamline accumulation ───────────────────
// Scales mirror the old Canvas2D flow field + lic Lite tier.
const float FIELD_SCALE = 0.0016;
const float TIME_SCALE  = 0.06;     // uTime is seconds
const float CURL_EPS    = 1e-3;
const int   STEPS       = 6;        // per direction; dual strata ≈72 snoise/frag
const float STEP_PX     = 2.8;      // arc-length step (px) — silk ribbon reach
const float STRAND_N    = 7.5;      // iso-level strand density
const float STRAND_W    = 0.085;    // strand half-width in iso-space (thinner = finer silk)

// 14s/31s irrational breath (same lung as the Canvas2D kernel / lic).
float breath(float t){
  float ms = t * 1000.0;
  return 0.5 + 0.5*(0.62*sin(6.2831853*ms/14000.0)
                  + 0.38*sin(6.2831853*ms/31000.0 + 1.3));
}

// Scalar potential ψ(p, τ).
float silkPot(vec2 p, float tz){ return snoise(vec3(p, tz)); }

// Divergence-free curl + ψ₀ in one go (3 snoise).
// Returns vec3(vx, vy, psi). p is FIELD space (screenPx × FIELD_SCALE × layerScale).
vec3 silkCurlPsi(vec2 p, float tz){
  float psi0 = silkPot(p, tz);
  float dPdy = (silkPot(p + vec2(0.0, CURL_EPS), tz) - psi0) / CURL_EPS;
  float dPdx = (silkPot(p + vec2(CURL_EPS, 0.0), tz) - psi0) / CURL_EPS;
  return vec3(dPdy, -dPdx, psi0);
}

// Soft iso-level peaks of ψ → thin continuous silk when path-coherent.
// Streamlines of curl(ψ) ride iso-contours, so peaks stay lit along the strand.
float strandOf(float psi){
  float u = abs(fract(psi * STRAND_N + 0.5) - 0.5) * 2.0; // 0 at peaks
  return exp(-(u * u) / (2.0 * STRAND_W * STRAND_W));
}

// Pointer bow-wave: Gaussian tangential swirl (same family as lic / kinetic-stipple).
vec2 pointerBend(vec2 screenPx, vec2 dirIn){
  if (uPointerActive < 0.5) return dirIn;
  vec2  pp = uPointer * uResolution;
  vec2  d  = screenPx - pp;
  float r2 = dot(d, d);
  float R  = 0.24 * min(uResolution.x, uResolution.y);
  float f  = exp(-r2 / (R * R));
  vec2  swirl = vec2(-d.y, d.x) / (sqrt(r2) + 1.0);
  return normalize(dirIn + swirl * f * 2.2);
}

// Unit wind + psi at screen px for one depth stratum. 3 snoise.
// Returns vec3(dir.x, dir.y, psi).
vec3 fieldSample(vec2 screenPx, float tz, float layerScale){
  vec3 c = silkCurlPsi(screenPx * FIELD_SCALE * layerScale, tz);
  float m = length(c.xy);
  vec2 dir = m > 1e-5 ? c.xy / m : vec2(1.0, 0.0);
  return vec3(pointerBend(screenPx, dir), c.z);
}

// Integrate a short streamline and accumulate soft ribbon intensity.
// Returns vec3(silk, speedHint, psiCenter). One fieldSample per step (3 snoise).
vec3 accumulateStratum(vec2 origin, float tz, float layerScale){
  float silk = 0.0;
  float wsum = 0.0;
  float L = float(STEPS) * STEP_PX;

  // Centre tap — also yields speed + psi for bead/palette.
  vec3 c0 = silkCurlPsi(origin * FIELD_SCALE * layerScale, tz);
  float speedHint = length(c0.xy);
  vec2 dir0 = speedHint > 1e-5 ? c0.xy / speedHint : vec2(1.0, 0.0);
  dir0 = pointerBend(origin, dir0);
  silk += strandOf(c0.z);
  wsum += 1.0;

  // Forward (+1) then backward (−1) Euler march.
  // One fieldSample per step: advance with current dir, accumulate psi at arrival.
  for (int sgn = 0; sgn < 2; sgn++){
    float sdir = sgn == 0 ? 1.0 : -1.0;
    vec2  pt   = origin;
    vec2  dir  = dir0;
    for (int i = 1; i <= STEPS; i++){
      pt += STEP_PX * dir * sdir;
      vec3 sm = fieldSample(pt, tz, layerScale);
      dir = sm.xy;
      float s = float(i) * STEP_PX;
      float hann = 0.5 + 0.5 * cos(3.14159265 * s / L);
      silk += hann * strandOf(sm.z);
      wsum += hann;
    }
  }

  silk = silk / max(wsum, 1e-4);
  return vec3(silk, speedHint, c0.z);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // Scroll (D2): scrub wind time + soft vertical gust energy for accent shift.
  float sN     = uScroll.y > 0.0 ? uScroll.x / uScroll.y : 0.0;
  float energy = clamp(abs(uScrollVel) / 120.0, 0.0, 1.0);
  float b      = breath(uTime);
  float timeScaleBreath = 0.7 + 0.6 * b;
  float tz     = uTime * TIME_SCALE * timeScaleBreath + sN * TIME_SCALE * 9.0;

  // ── Dual depth strata (parallax) ──────────────────────────────────────
  // Back (broad, slow, dimmer) + front (fine, faster eddies).
  // Cost: 2 × (1 centre curl + 2×6 path curls) × 3 snoise ≈ 78 snoise.
  vec3 back  = accumulateStratum(fragCoord, tz * 0.47 + 90.0, 0.70);
  vec3 front = accumulateStratum(fragCoord, tz,               1.55);

  // Layer weights: back ~40% contribution, front carries most of the silk.
  float silk  = back.x * 0.55 + front.x * 1.0;
  float speed = clamp((back.y + front.y) * 0.35, 0.0, 1.0);
  float psiC  = mix(back.z, front.z, 0.65);

  // Breath gathers density + brightness on the inhale.
  float breathLift = 0.82 + 0.30 * b;
  silk = clamp(silk * breathLift * (1.0 + 0.25 * energy), 0.0, 1.5);

  // Traveling light-bead: flow-aligned phase from centre ψ + screen projection.
  // Reuses front stratum's raw curl direction without an extra field sample:
  // reconstruct a cheap unit direction from the front speed/psi channel by
  // projecting with a stable secondary phase along the fragment.
  float beadPhase = fract(
    psiC * 1.7
    + (fragCoord.x * 0.0031 + fragCoord.y * 0.0027)
    + uTime * 0.35
    + speed * 0.4
  ) - 0.5;
  float bead = exp(-(beadPhase * beadPhase) / 0.018);
  bead *= 0.9 + 0.35 * b;

  // Contrast the soft accumulation into crisp luminous ribbons without
  // turning into a heavy LIC texture.
  float ribbon = pow(clamp(silk, 0.0, 1.0), 1.35);
  ribbon = smoothstep(0.08, 0.92, ribbon);

  // Accent ramp walks with speed + scroll (parity with old colorShift).
  float accentT = 0.10 + 0.55 * ribbon + 0.20 * speed + 0.12 * sN + energy * 0.08;
  vec3  tint    = accentRamp(accentT);

  // Theme-branched silk composite.
  vec3 col;
  if (uTheme < 0.5){
    // DARK: bright luminous strands on deep ink; bead lifts toward near-white.
    vec3 hot  = mix(tint, vec3(0.97, 0.98, 1.0), 0.45 * clamp(bead, 0.0, 1.0));
    float a   = clamp(ribbon * (1.0 + 0.85 * bead), 0.0, 1.0) * uIntensity;
    col = mix(uBg, hot, a);
    // Soft halo under the brightest beads (silk glow, not stipple).
    col += tint * (0.08 * b + 0.10 * bead) * ribbon * uIntensity;
  } else {
    // LIGHT: ink strands on paper; bead darkens (white would vanish on pearl).
    vec3 dark = mix(tint, uInk, 0.30 + 0.35 * clamp(bead, 0.0, 1.0));
    float a   = clamp(ribbon * (0.85 + 0.35 * bead), 0.0, 1.0) * uIntensity;
    col = mix(uBg, dark, a);
  }

  // Faint ambient flow haze in the gaps (keeps the field alive between strands).
  float haze = fbm(vec3(fragCoord * FIELD_SCALE * 0.55, uTime * 0.04));
  col = mix(col, accentRamp(0.08 + 0.25 * haze + 0.1 * b), 0.045 * uIntensity * (1.0 - ribbon));

  // Vignette — protect glass-type legibility over the silk.
  float vig = smoothstep(1.6, 0.2, length(p));
  col = mix(uBg, col, 0.42 + 0.58 * vig);

  return col;   // dither() added by the factory MAIN wrapper
}
`;

export function createFlowFieldKernel(): Kernel {
  return createShaderKernel({
    id: "flow",
    label: "Flow Field",
    body: BODY,
    // D7 opt-in → host pushes D2's shared vec2 uScroll / float uScrollVel block
    // (scroll time-scrub + gust energy, matching the old Canvas2D reactive layer).
    controls: ["scroll"],
  });
}
