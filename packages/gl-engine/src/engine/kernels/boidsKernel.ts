/**
 * Boids kernel — "Boids".
 *
 * SOTA single-pass GPU murmuration (no Canvas2D, no CPU Reynolds O(n²)).
 * Classic agent-based boids cannot run as a pure fragment kernel; instead the
 * flock is represented as many procedural "birds" on a cell lattice, advected
 * by a strong divergence-free curl-noise wind (the large-scale wheel/fold of a
 * real starling cloud). Each bird is a tiny velocity-aligned soft streak —
 * an elongated Gaussian along the local wind — so density does the work:
 * packed regions accumulate into bright silver ribbons, thin regions fade to
 * sky.
 *
 * Aesthetic contracts (preserved from the Canvas2D murmuration):
 *  - Whole-flock near-monochrome tint cycling slowly through accentRamp (~40s)
 *    — NOT per-bird rainbow confetti.
 *  - Soft edge steering via field warp near borders (flock wheels, doesn't wrap).
 *  - Pointer = predator: wind/dir flees the cursor within radius, opening a hole.
 *  - Breath LFO on speed/density (~14s / ~31s irrational pair).
 *  - Dark: luminous silver birds on deep ink; light: dark ink birds on paper.
 *  - Vignette for UI legibility.
 *
 * Curl wind grounded in Bridson et al. 2007 ("Curl-Noise for Procedural Fluid
 * Flow"). Cell + life-stream advection mirrors kinetic-stipple; the mark shape
 * is a streak, not a stipple dot.
 *
 * Single-pass GLSL ES 3.00 via {@link createShaderKernel}; RGBA8, no sim, no
 * float target — same renderable set as kinetic-stipple / fluid-aurora.
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Boids — curl-advected lattice murmuration (SOTA single-pass) ───────────

// Scalar potential for the curl field: a single simplex slice over slow time.
float boidPot(vec2 p, float tz){ return snoise(vec3(p, tz)); }

// Divergence-free wind = curl of the scalar potential (Bridson 2007).
vec2 boidCurl(vec2 p, float tz){
  float e = 1.5e-3;
  float dy = boidPot(p + vec2(0.0, e), tz) - boidPot(p - vec2(0.0, e), tz);
  float dx = boidPot(p + vec2(e, 0.0), tz) - boidPot(p - vec2(e, 0.0), tz);
  return vec2(dy, -dx) / (2.0 * e);
}

// Soft elongated Gaussian streak: length along \`dir\`, width across it.
float boidStreak(vec2 d, vec2 dir, float sigL, float sigW){
  vec2 n = vec2(-dir.y, dir.x);
  float along  = dot(d, dir);
  float across = dot(d, n);
  return exp(-0.5 * (along * along / (sigL * sigL) + across * across / (sigW * sigW)));
}

// One lattice layer: 3×3 cell stitch of life-advected streaks.
// \`cell\` in CSS-ish px; \`stream\` how far a bird travels across its life.
float boidLayer(
  vec2 fragCoord, vec2 dir, float speed,
  float cell, float stream, float densScale,
  float t, float breath, float brightMul
){
  vec2 g  = fragCoord / cell;
  vec2 id = floor(g);
  vec2 fp = fract(g);
  float ink = 0.0;
  for(int oy = -1; oy <= 1; oy++){
    for(int ox = -1; ox <= 1; ox++){
      vec2 nid = id + vec2(float(ox), float(oy));
      // Stable per-bird seeds (position jitter, life phase, brightness, length).
      float h0 = hash21(nid);
      float h1 = hash21(nid + 3.17);
      float h2 = hash21(nid + 7.91);
      float h3 = hash21(nid + 13.3);
      // Density sampled UPSTREAM so birds inherit the field that flowed in.
      vec2 cellPx = (nid + 0.5) * cell;
      vec2 src = cellPx - dir * (stream * (0.55 + 0.45 * speed));
      float dens = clamp(fbm(vec3(src * densScale, t * 0.11)) * 0.55 + 0.5, 0.0, 1.0);
      // Breath thickens the flock on the inhale; cull sparse cells.
      float presence = smoothstep(0.18 - 0.08 * breath, 0.72, dens);
      if(presence < 0.02) continue;
      // Life clock — faster where the wind is faster / inhale is deeper.
      float lifeRate = 0.09 + 0.14 * speed + 0.04 * breath;
      float life = fract(h0 + t * lifeRate);
      float env = sin(life * 3.14159265);          // birth → peak → death
      vec2 jit = (vec2(h1, h2) - 0.5) * 0.55;
      // Stream across the cell along wind; slight lateral bank for ribbon grain.
      vec2 lat = vec2(-dir.y, dir.x);
      vec2 ctr = vec2(0.5) + jit + dir * (life - 0.5) * 1.15 + lat * (h3 - 0.5) * 0.18;
      vec2 d = (fp - vec2(float(ox), float(oy))) - ctr;
      // Streak size in cell-units; longer when dense / fast.
      float sigL = (0.22 + 0.18 * dens + 0.10 * speed) * (0.85 + 0.3 * h3);
      float sigW = 0.055 + 0.035 * dens;
      float streak = boidStreak(d, dir, sigL, sigW);
      float cov = streak * env * presence * brightMul * (0.55 + 0.45 * dens);
      ink += cov;
    }
  }
  return ink;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  const float TAU = 6.28318530718;
  const float FIELD_SCALE = 0.0014;   // wind spatial frequency (matches old WIND_SCALE)
  const float DENS_SCALE  = 0.0038;   // density-field spatial frequency
  const float TINT_PERIOD = 40.0;     // whole-flock accent cycle (~40s)

  // ── Breath LFO — 14s / 31s irrational pair (shared with the old Canvas lung) ──
  float breath =
    0.5 + 0.5 * (
      0.62 * sin(TAU * uTime / 14.0) +
      0.38 * sin(TAU * uTime / 31.0 + 1.3)
    );
  float tz = uTime * (0.05 + 0.025 * breath);   // field reorganizes a little faster on inhale

  // ── Soft edge steering: warp sample point so wind turns the flock at borders ──
  vec2 res = uResolution;
  float minR = min(res.x, res.y);
  float margin = 0.12 * minR;
  vec2 edgeN = vec2(
    smoothstep(0.0, margin, fragCoord.x) - smoothstep(res.x - margin, res.x, fragCoord.x),
    smoothstep(0.0, margin, fragCoord.y) - smoothstep(res.y - margin, res.y, fragCoord.y)
  );
  // Sample wind slightly inward near edges so streamlines wheel instead of leave.
  vec2 samplePx = fragCoord + (vec2(0.5) - edgeN) * margin * 0.35;
  vec2 wind = boidCurl(samplePx * FIELD_SCALE, tz);
  // Inject an inward turn force in the margin (field warp, not a hard clamp).
  wind += edgeN * 0.55;

  float speed = clamp(length(wind), 0.0, 2.5);
  vec2 dir = speed > 1e-5 ? wind / speed : vec2(1.0, 0.0);

  // Breath swells advection speed (flock gathers + quickens on the inhale).
  float speedMul = 0.88 + 0.28 * breath;
  speed *= speedMul;

  // ── Pointer = predator: flee the cursor, opening a hole in the murmuration ──
  float hole = 0.0;
  if(uPointerActive > 0.5){
    vec2 pp = uPointer * res;
    vec2 dpx = fragCoord - pp;
    float R = 0.20 * minR;                       // ~230px @ 1150 short-side
    float d2 = dot(dpx, dpx);
    float R2 = R * R;
    if(d2 < R2 && d2 > 1e-3){
      float d = sqrt(d2);
      // Falloff matches old POINTER.FALLOFF ≈ 1.25 (soft power edge).
      float f = pow(clamp((R - d) / R, 0.0, 1.0), 1.25);
      vec2 flee = dpx / d;
      // Steer wind/dir away from predator; stronger near the core.
      dir = normalize(dir + flee * f * 2.4);
      hole = f;
    }
  }

  // ── Two lattice octaves → dense multi-scale flock sheets ──
  // Fine layer: tight grain of the murmuration body.
  // Coarse layer: longer ribbon streaks that read as folding sheets.
  float streamFine   = 95.0 * (0.85 + 0.3 * breath);
  float streamCoarse = 150.0 * (0.85 + 0.3 * breath);
  float brightBreath = 0.75 + 0.45 * breath;     // density swell on inhale

  float inkFine = boidLayer(
    fragCoord, dir, speed,
    11.0, streamFine, DENS_SCALE,
    uTime, breath, 1.15 * brightBreath
  );
  float inkCoarse = boidLayer(
    fragCoord, dir, speed,
    18.5, streamCoarse, DENS_SCALE * 0.7,
    uTime * 0.87 + 4.2, breath, 0.72 * brightBreath
  );
  // Soft haze density under the streaks (advected FBM sheet).
  float haze = fbm(vec3(fragCoord * DENS_SCALE * 0.45 - dir * 2.4, uTime * 0.045));
  haze = clamp(haze * 0.5 + 0.35, 0.0, 1.0);

  float ink = inkFine * 0.72 + inkCoarse * 0.55;
  ink += haze * 0.12 * brightBreath;
  // Predator hole: punch density open near the cursor.
  ink *= 1.0 - hole * 0.92;
  ink = clamp(ink, 0.0, 2.4);

  // Soft ribbon highlight where birds pack tight (silvery sheet cores).
  float ribbon = smoothstep(0.55, 1.6, ink);
  float body   = smoothstep(0.05, 0.85, ink);

  // ── Whole-flock silvery tint — one tone for the entire murmuration ──
  // Cycles accentRamp once per ~40s; mix lightly toward ink so dark themes
  // read as luminous silver and light themes as dark ink birds on paper.
  float tintT = fract(uTime / TINT_PERIOD);
  vec3 accent = accentRamp(tintT);
  vec3 flockTint = mix(uInk, accent, 0.30);

  // ── Theme-branched composite ──
  vec3 col;
  if(uTheme < 0.5){
    // DARK: luminous silver birds on deep ink; ribbons lift toward white.
    vec3 hot = mix(flockTint, vec3(1.0), 0.22 + 0.28 * ribbon);
    col = mix(uBg, hot, clamp(body * uIntensity, 0.0, 1.0));
    col += hot * ribbon * 0.18 * uIntensity;     // additive core sparkle
  } else {
    // LIGHT: dark ink birds on paper (never blows out).
    vec3 dark = mix(flockTint, uInk, 0.55);
    col = mix(uBg, dark, clamp(body * 0.88 * uIntensity, 0.0, 1.0));
    col = mix(col, dark, ribbon * 0.12 * uIntensity);
  }

  // Faint sky wash in the thin zones so the field never reads as empty void.
  col = mix(col, mix(uBg, accent, 0.08), 0.04 * uIntensity * (1.0 - body));

  // ── Vignette (keeps foreground text legible) ──
  vec2 pc = (fragCoord - 0.5 * res) / res.y;
  float vig = smoothstep(1.6, 0.2, length(pc));
  col = mix(uBg, col, 0.45 + 0.55 * vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;

export function createBoidsKernel(): Kernel {
  return createShaderKernel({
    id: "boids",
    label: "Boids",
    body: BODY,
  });
}
