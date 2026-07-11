/**
 * LIC kernel — "Flow Imaging": a per-fragment Line Integral Convolution
 * (Cabral–Leedom 1993) of the divergence-free curl-noise wind shared with the
 * `flow` kernel. Every fragment marches its streamline forward + backward along
 * the curl field, convolving a baked void-and-cluster blue-noise tile with an
 * animated Hann×cosine kernel whose phase travels along the flow ⇒ honest silk
 * in motion. One wind, two souls: `flow` images it as tracers, `lic` images the
 * same field as texture.
 *
 * **v1 ships the Lite tier** (Euler + forward-difference curl, full-res, N=14,
 * ≈87 snoise/frag) — the contract-compliant floor that holds locked 60fps on
 * integrated GPUs. Quality/Default (RK2 / central-diff) are in-kernel `#define`
 * upgrades for capable GPUs; see BUILD_LOG and the plan §6. No float gate
 * (RGBA8 tile) ⇒ runs everywhere WebGL2 does.
 *
 * Dark: bright bands lifted toward white + gentle breath bloom. Light: bands
 * darkened toward ink (white would vanish on pearl). Opts into the shared D2
 * scroll control block (`controls:["scroll"]`).
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import {
  LIC_BLUE_NOISE_DATA_URI,
  LIC_BLUE_NOISE_SIZE,
} from "../lic/licBlueNoise";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Tuning (the v1 Lite tier; mirror flowFieldKernel FIELD/TIME scales) ───
#define LIC_QUALITY 0          // 0 = Lite (Euler + forward-diff), 1 = Quality (RK2 + central)
const float FIELD_SCALE = 0.0016;   // wind spatial frequency (== flow)
const float TIME_SCALE  = 0.06;     // field reorganisation (uTime in seconds)
const float CURL_EPS    = 1e-3;     // finite-difference step (mirrors CPU EPS)
#if LIC_QUALITY
const int   LIC_STEPS   = 12;       // march steps per direction (2N+1 taps)
#else
const int   LIC_STEPS   = 14;       // Lite: a couple more steps to recover arc-length
#endif
const float STEP_PX     = 1.6;      // arc-length step, device px
const float CONV_FREQ   = 0.30;     // travelling-band spatial frequency
const float PHASE_SPEED = 2.2;      // band travel speed (rad/s)
const float CONTRAST    = 1.9;      // LIC contrast stretch
const float TILE_PX     = ${LIC_BLUE_NOISE_SIZE.toFixed(1)};   // blue-noise tile edge (matches bake)

// flow kernel's 14s/31s irrational breath lung, ported to GLSL.
float breath(float t){
  float ms = t * 1000.0;
  return 0.5 + 0.5*(0.62*sin(6.2831853*ms/14000.0)
                  + 0.38*sin(6.2831853*ms/31000.0 + 1.3));
}

// Scalar potential ψ(p,τ); z = field-time (same role as CPU noise3 z=t).
float licPotential(vec2 p, float tz){ return snoise(vec3(p, tz)); }

// Divergence-free curl of ψ. MIRRORS simplex.ts::curl2: curl = (∂ψ/∂y, −∂ψ/∂x).
// p is FIELD space (already ×FIELD_SCALE).
#if LIC_QUALITY
// Central differences — 4 snoise/curl.
vec2 licCurl(vec2 p, float tz){
  float dPdy = (licPotential(p + vec2(0.0, CURL_EPS), tz)
              - licPotential(p - vec2(0.0, CURL_EPS), tz)) / (2.0*CURL_EPS);
  float dPdx = (licPotential(p + vec2(CURL_EPS, 0.0), tz)
              - licPotential(p - vec2(CURL_EPS, 0.0), tz)) / (2.0*CURL_EPS);
  return vec2(dPdy, -dPdx);
}
#else
// Forward differences — 3 snoise/curl (reuse centre ψ₀): ~25% cheaper, visually
// indistinguishable for a backdrop. The §8 licCurlParity test validates the
// (central-diff) wiring on the CPU; this Lite form is the documented v1 default.
vec2 licCurl(vec2 p, float tz){
  float psi0 = licPotential(p, tz);
  float dPdy = (licPotential(p + vec2(0.0, CURL_EPS), tz) - psi0) / CURL_EPS;
  float dPdx = (licPotential(p + vec2(CURL_EPS, 0.0), tz) - psi0) / CURL_EPS;
  return vec2(dPdy, -dPdx);
}
#endif

// Pointer reactivity: BEND the field (LIC is blind to translation, reveals
// rotation) — add a Gaussian tangential swirl around the cursor.
vec2 pointerBend(vec2 screenPx, vec2 dirIn){
  if (uPointerActive < 0.5) return dirIn;
  vec2  pp = uPointer * uResolution;            // pointer → device px
  vec2  d  = screenPx - pp;
  float r2 = dot(d, d);
  float R  = 0.22 * min(uResolution.x, uResolution.y);
  float f  = exp(-r2 / (R*R));
  vec2  swirl = vec2(-d.y, d.x) / (sqrt(r2) + 1.0);  // unit tangential
  return normalize(dirIn + swirl * f * 1.6);
}

// Unit streamline direction at screen px.
vec2 fieldDir(vec2 screenPx, float tz){
  vec2 v = licCurl(screenPx * FIELD_SCALE, tz);
  float m = length(v);
  vec2 dir = m > 1e-5 ? v / m : vec2(1.0, 0.0);
  return pointerBend(screenPx, dir);
}

// Sample the tiled blue-noise (repeat wrap, linear filter).
float blue(vec2 px){ return texture(uBlueNoise, px / TILE_PX).r; }

// Animated kernel weight: Hann window (AA) × travelling cosine band (motion).
float licWeight(float s, float L, float phase){
  float hann = 0.5 + 0.5*cos(3.1415926*s / L);
  float band = 0.5 + 0.5*cos(CONV_FREQ*s - phase);
  return hann * band;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // Scroll from D2's shared control block: uScroll = vec2(offsetPx, yMax),
  // uScrollVel = px/frame. Normalize position locally.
  float sN    = uScroll.y > 0.0 ? uScroll.x / uScroll.y : 0.0;
  float b     = breath(uTime);
  float tz    = uTime * TIME_SCALE * (0.7 + 0.6*b) + sN * TIME_SCALE * 9.0;
  float phase = uTime * PHASE_SPEED + uScrollVel * 0.15;   // px/frame gust
  float L     = float(LIC_STEPS) * STEP_PX;

  // centre tap
  float wc  = licWeight(0.0, L, phase);
  float acc = wc * blue(fragCoord);
  float wsum = wc;

  // forward (+1) then backward (-1) march. Lite = Euler (1 fieldDir/step);
  // Quality = RK2 (midpoint sample).
  for (int sgn = 0; sgn < 2; sgn++){
    float dir = sgn == 0 ? 1.0 : -1.0;
    vec2  pt  = fragCoord;
    for (int i = 1; i <= LIC_STEPS; i++){
#if LIC_QUALITY
      vec2 k1 = fieldDir(pt, tz) * dir;
      vec2 k2 = fieldDir(pt + 0.5*STEP_PX*k1, tz) * dir;
      pt += STEP_PX * k2;
#else
      pt += STEP_PX * fieldDir(pt, tz) * dir;
#endif
      float s = float(i) * STEP_PX;
      float w = licWeight(s, L, phase * dir);   // bands travel outward per side
      acc  += w * blue(pt);
      wsum += w;
    }
  }

  float lic = acc / max(wsum, 1e-4);
  lic = clamp((lic - 0.5) * CONTRAST + 0.5, 0.0, 1.0);   // contrast stretch

  // Colour: silk tint from the accent ramp, nudged by local field speed + breath.
  float speed = clamp(length(licCurl(fragCoord*FIELD_SCALE, tz)) * 0.5, 0.0, 1.0);
  vec3  tint  = accentRamp(0.12 + 0.62*lic + 0.18*speed);

  // Theme: dark → luminous bands lifted toward white; light → bands darkened
  // toward ink (white would vanish on pearl). Fold uIntensity into the lift.
  vec3  silk;
  if (uTheme < 0.5){
    vec3 hot = mix(tint, vec3(1.0), 0.22 * lic);
    silk = mix(uBg, hot, clamp(lic * 1.15, 0.0, 1.0) * uIntensity);
    silk += tint * (0.10 * b * uIntensity);             // gentle breath bloom
  } else {
    vec3 dark = mix(tint, uInk, 0.35);
    silk = mix(uBg, dark, clamp((1.0 - lic) * 0.9, 0.0, 1.0) * uIntensity);
  }

  // VIGNETTE (protect glass-type legibility over the silk).
  float vig = smoothstep(1.6, 0.2, length(p));
  silk = mix(uBg, silk, 0.4 + 0.6 * vig);
  return silk;   // dither() added by the factory MAIN wrapper
}
`;

export function createLicKernel(): Kernel {
  return createShaderKernel({
    id: "lic",
    label: "Flow Imaging",
    body: BODY,
    // stream-01 texture-upload infra (§4): baked blue-noise tile.
    textures: [
      {
        name: "uBlueNoise",
        dataUri: LIC_BLUE_NOISE_DATA_URI,
        filter: "linear",
        wrap: "repeat",
      },
    ],
    // D7 opt-in → host pushes D2's shared vec2 uScroll / float uScrollVel block.
    controls: ["scroll"],
    // No float ext needed (RGBA8 tile) ⇒ no requiresFloatTex / fallbackId.
  });
}
