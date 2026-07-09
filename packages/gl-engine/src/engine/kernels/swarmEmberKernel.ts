/**
 * Swarm Ember kernel — pure WebGL2 fire-ember murmuration.
 *
 * A living furnace of soft-glow coals, brass embers, and white-hot sparks
 * rendered as multi-scale procedural glow disks advected by Bridson curl-noise
 * wind. Dense enough to read as luminous murmuration ribbons of fire, not a
 * sparse starfield. Pointer injects a wind-scoop (repel + swirl). Micro-flicker
 * is always on (sin/hash+time). Composite respects `uBg` / `uIntensity` /
 * `uTheme`; particles use a HARDCODED fire temperature ramp (coal → blood →
 * brass `#fa6b06` → amber `#fdc42c` → white-hot), not the cool iris palette.
 *
 * API options are accepted for BackdropEngine compat:
 *   - `motionSpeedMultiplier` — shader pace is cinematic (fixed slow clock);
 *     a pure fragment kernel cannot retune host time easily.
 *   - `enableSwarmSparkles` — micro-flicker is always built in.
 *
 * No Canvas2D, no CPU particles, no provider-logo formation cycle.
 * Single-pass GLSL ES 3.00 via {@link createShaderKernel}.
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

/**
 * Host overrides when mounting `swarmEmber` (e.g. Linux dashboard cinematic pace).
 * Kept for API compatibility with {@link BackdropEngine}; pure-shader path
 * encodes motion as a fixed cinematic clock and always-on micro-flicker.
 */
export type SwarmEmberKernelOptions = {
  /** macOS SwarmCanvasView.enableSwarmSparkles — dashboard default false. Built-in micro-flicker is always on in the WebGL path. */
  enableSwarmSparkles?: boolean;
  /** macOS SwarmCanvasView.motionSpeedMultiplier — clamped 0.35…2.5 on Canvas path. Shader pace is cinematic (fixed). */
  motionSpeedMultiplier?: number;
};

const BODY = /* glsl */ `
// ── Swarm Ember — curl-advected fire particle murmuration ──────────────────
// Options (API only): motionSpeedMultiplier → cinematic fixed pace below;
// enableSwarmSparkles → micro-flicker always on via seFlicker().

// Hardcoded fire temperature ramp (sRGB 0–1):
// coal → blood → brass #fa6b06 → amber #fdc42c → white-hot
vec3 seFireRamp(float t){
  t = clamp(t, 0.0, 1.0);
  const vec3 c0 = vec3(0.110, 0.039, 0.031); // coal
  const vec3 c1 = vec3(0.361, 0.086, 0.031); // blood
  const vec3 c2 = vec3(0.659, 0.165, 0.031); // deep ember
  const vec3 c3 = vec3(0.910, 0.306, 0.039); // orange
  const vec3 c4 = vec3(0.980, 0.420, 0.024); // brass #fa6b06
  const vec3 c5 = vec3(0.992, 0.769, 0.173); // amber #fdc42c
  const vec3 c6 = vec3(1.000, 0.863, 0.471); // pale gold
  const vec3 c7 = vec3(1.000, 0.957, 0.863); // white-hot
  float x = t * 7.0;
  float i = floor(x);
  float f = fract(x);
  vec3 a = c0, b = c1;
  if(i < 0.5){ a = c0; b = c1; }
  else if(i < 1.5){ a = c1; b = c2; }
  else if(i < 2.5){ a = c2; b = c3; }
  else if(i < 3.5){ a = c3; b = c4; }
  else if(i < 4.5){ a = c4; b = c5; }
  else if(i < 5.5){ a = c5; b = c6; }
  else { a = c6; b = c7; }
  return mix(a, b, f);
}

// Scalar potential for Bridson curl-noise (procedural fluid flow).
float sePot(vec2 p, float tz){ return snoise(vec3(p, tz)); }

// Divergence-free wind = curl of scalar potential (Bridson et al. 2007).
vec2 seCurl(vec2 p, float tz){
  float e = 1.5e-3;
  float dy = sePot(p + vec2(0.0, e), tz) - sePot(p - vec2(0.0, e), tz);
  float dx = sePot(p + vec2(e, 0.0), tz) - sePot(p - vec2(e, 0.0), tz);
  return vec2(dy, -dx) / (2.0 * e);
}

// Soft multi-radius Gaussian glow (additive bloom look).
float seGlow(float d2, float r){
  float inv = 1.0 / max(r * r, 1e-6);
  float core = exp(-d2 * inv * 2.8);
  float mid  = exp(-d2 * inv * 0.85) * 0.45;
  float halo = exp(-d2 * inv * 0.22) * 0.14;
  return core + mid + halo;
}

// Micro-flicker always on (enableSwarmSparkles built into the field).
float seFlicker(vec2 seed, float t){
  return 0.72 + 0.28 * sin(hash21(seed) * 40.0 + t * (7.0 + hash21(seed + 1.7) * 5.0));
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  // Cinematic pace (motionSpeedMultiplier not applied — fixed slow clock).
  float t = uTime * 0.085;
  float tz = t * 0.55;

  const float FIELD_SCALE = 0.00145; // wind spatial frequency
  const float STREAM_PX   = 95.0;    // advection look-back along wind
  const float CELL_COARSE = 22.0;    // large coal / ember cells
  const float CELL_FINE   = 11.0;    // dense spark stipple
  const float CELL_RIBBON = 16.0;    // mid-scale murmuration ribbons

  // ── Wind at this fragment ──
  vec2 wind = seCurl(fragCoord * FIELD_SCALE, tz);
  // Buoyancy bias: fire lifts upward in screen space (y-up fragCoord).
  wind += vec2(0.0, 0.35);
  float speed = clamp(length(wind), 0.0, 2.5);
  vec2 dir = speed > 1e-5 ? wind / speed : vec2(0.0, 1.0);

  // Pointer wind-scoop: repel + swirl (bow wave).
  if(uPointerActive > 0.5){
    vec2 pp = uPointer * uResolution;
    vec2 dpx = fragCoord - pp;
    float R = 0.28 * min(uResolution.x, uResolution.y);
    float f = exp(-dot(dpx, dpx) / (R * R));
    vec2 radial = normalize(dpx + 1e-3);
    vec2 swirl  = vec2(-radial.y, radial.x);
    dir = normalize(dir + (radial * 1.1 + swirl * 0.85) * f * 2.2);
    speed = clamp(speed + f * 1.4, 0.0, 3.0);
  }

  // ── Furnace underglow (radial bottom brass/ember wash) ──
  vec2 pc = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float breath = 0.55 + 0.45 * sin(t * 1.35);
  float under = exp(-pow(max(0.0, -pc.y + 0.55) * 1.35, 2.0))
              * exp(-pc.x * pc.x * 1.8)
              * breath;
  float underWide = exp(-length(vec2(pc.x * 0.7, max(0.0, -pc.y + 0.15))) * 1.6) * 0.35;

  // Accumulated fire (energy) and weighted temperature / streak energy.
  float energy = 0.0;
  float tempW  = 0.0;
  float streak = 0.0;
  float weight = 0.0;

  // ── Layer A: coarse coals / large embers (3×3 cell stitch) ──
  {
    float cell = CELL_COARSE;
    vec2 g = fragCoord / cell;
    vec2 id = floor(g);
    vec2 fp = fract(g);
    for(int oy = -1; oy <= 1; oy++){
      for(int ox = -1; ox <= 1; ox++){
        vec2 nid = id + vec2(float(ox), float(oy));
        float h0 = hash21(nid);
        float h1 = hash21(nid + 19.7);
        float h2 = hash21(nid + 41.3);
        // Density gate: keep enough cells lit for murmuration, not sparse stars.
        if(h0 > 0.42) continue;

        vec2 cellPx = (nid + 0.5) * cell;
        vec2 src = cellPx - dir * (STREAM_PX * (0.45 + 0.35 * speed));
        // Advected life clock — streams across the cell with the wind.
        float life = fract(h1 + t * (0.07 + 0.10 * speed) + h2 * 0.1);
        float env = sin(life * 3.14159265);
        vec2 jit = (vec2(hash21(nid + 3.1), hash21(nid + 7.7)) - 0.5) * 0.48;
        vec2 ctr = vec2(0.5) + jit + dir * (life - 0.5) * 0.85;
        vec2 d = (fp - vec2(float(ox), float(oy))) - ctr;
        // Soft disk in cell space → px for multi-radius glow.
        float px = length(d) * cell;
        float size = mix(2.8, 7.5, h2);
        float gA = seGlow(px * px, size);
        float flick = seFlicker(nid, t);
        float temp = 0.08 + 0.32 * h0 + 0.12 * env; // coal → warm ember
        float amp = gA * env * flick * (0.55 + 0.45 * h1);
        energy += amp * 0.85;
        tempW  += temp * amp;
        weight += amp;
      }
    }
  }

  // ── Layer B: mid-scale ribbon embers (murmuration body) ──
  {
    float cell = CELL_RIBBON;
    vec2 g = fragCoord / cell;
    vec2 id = floor(g);
    vec2 fp = fract(g);
    for(int oy = -1; oy <= 1; oy++){
      for(int ox = -1; ox <= 1; ox++){
        vec2 nid = id + vec2(float(ox), float(oy));
        float h0 = hash21(nid + 101.0);
        float h1 = hash21(nid + 202.0);
        float h2 = hash21(nid + 303.0);
        if(h0 > 0.55) continue;

        // Ribbon density from low-freq FBM — forms luminous sheets of fire.
        vec2 cellPx = (nid + 0.5) * cell;
        vec2 src = cellPx - dir * (STREAM_PX * 0.7);
        float dens = clamp(fbm(vec3(src * 0.0036, tz * 0.8)) * 0.55 + 0.5, 0.0, 1.0);
        if(dens < 0.28) continue;

        float life = fract(h1 + t * (0.11 + 0.18 * speed));
        float env = sin(life * 3.14159265);
        vec2 jit = (vec2(hash21(nid + 5.5), hash21(nid + 9.2)) - 0.5) * 0.40;
        vec2 ctr = vec2(0.5) + jit + dir * (life - 0.5);
        vec2 d = (fp - vec2(float(ox), float(oy))) - ctr;
        float px = length(d) * cell;
        float size = mix(1.2, 3.6, dens) * (0.7 + 0.5 * h2);
        float gB = seGlow(px * px, size);
        float flick = seFlicker(nid + 0.3, t);
        float temp = 0.35 + 0.40 * dens + 0.15 * h0; // blood → brass → amber
        float amp = gB * env * flick * smoothstep(0.28, 0.85, dens);
        energy += amp * 1.15;
        tempW  += temp * amp;
        weight += amp;

        // Velocity streaks for hot mid-sparks along wind.
        if(temp > 0.55 && dens > 0.45){
          float along = abs(dot(d, dir));
          float across = abs(dot(d, vec2(-dir.y, dir.x)));
          float st = exp(-across * across * 48.0) * exp(-along * along * 6.0) * env;
          streak += st * flick * dens;
        }
      }
    }
  }

  // ── Layer C: fine white-hot sparks (dense stipple) ──
  {
    float cell = CELL_FINE;
    vec2 g = fragCoord / cell;
    vec2 id = floor(g);
    vec2 fp = fract(g);
    for(int oy = -1; oy <= 1; oy++){
      for(int ox = -1; ox <= 1; ox++){
        vec2 nid = id + vec2(float(ox), float(oy));
        float h0 = hash21(nid + 777.0);
        float h1 = hash21(nid + 888.0);
        // Sparse enough not to wash out, dense enough for sparkle ribbons.
        if(h0 > 0.38) continue;

        float life = fract(h1 + t * (0.18 + 0.28 * speed));
        float env = sin(life * 3.14159265);
        // Prefer sparks in wind-advected dense zones.
        vec2 cellPx = (nid + 0.5) * cell;
        float dens = clamp(fbm(vec3(cellPx * 0.0048, tz * 1.1)) * 0.5 + 0.5, 0.0, 1.0);
        if(dens < 0.38) continue;

        vec2 jit = (vec2(hash21(nid + 1.1), hash21(nid + 2.2)) - 0.5) * 0.55;
        vec2 ctr = vec2(0.5) + jit + dir * (life - 0.5) * 1.15;
        vec2 d = (fp - vec2(float(ox), float(oy))) - ctr;
        float px = length(d) * cell;
        float size = mix(0.45, 1.35, h0);
        float gC = seGlow(px * px, size);
        float flick = seFlicker(nid + 2.0, t * 1.3);
        float temp = 0.72 + 0.28 * h1; // amber → white-hot
        float amp = gC * env * flick * dens * 1.35;
        energy += amp;
        tempW  += temp * amp;
        weight += amp;

        // Hot spark velocity streaks.
        float along = abs(dot(d, dir));
        float across = abs(dot(d, vec2(-dir.y, dir.x)));
        float st = exp(-across * across * 90.0) * exp(-along * along * 4.5) * env * flick;
        streak += st * dens * 1.2;
      }
    }
  }

  // Soft advected haze between particles (ribbon fill, not muddy).
  float haze = fbm(vec3(fragCoord * 0.0022 - dir * 1.5, tz * 0.6));
  haze = clamp(haze * 0.5 + 0.5, 0.0, 1.0);
  float hazeBand = smoothstep(0.35, 0.9, haze) * (0.08 + 0.06 * speed);

  float meanTemp = weight > 1e-4 ? clamp(tempW / weight, 0.0, 1.0) : 0.35;
  float e = clamp(energy * 0.55 + hazeBand + streak * 0.45, 0.0, 4.0);
  float core = smoothstep(0.02, 0.55, e);
  float bloom = smoothstep(0.0, 0.25, e) * (1.0 - core * 0.35);

  vec3 fireCol = seFireRamp(meanTemp);
  vec3 hotCore = mix(fireCol, vec3(1.0, 0.97, 0.92), smoothstep(0.55, 0.95, meanTemp) * core);
  // Streaks push toward white-hot brass.
  vec3 streakCol = seFireRamp(clamp(meanTemp + 0.25, 0.0, 1.0));
  vec3 underCol = seFireRamp(0.42 + 0.12 * breath);

  vec3 col;
  if(uTheme < 0.5){
    // DARK: deep void + additive furnace.
    col = uBg;
    col += underCol * (under * 0.22 + underWide * 0.10) * uIntensity;
    col += hotCore * core * 0.95 * uIntensity;
    col += fireCol * bloom * 0.55 * uIntensity;
    col += streakCol * clamp(streak, 0.0, 1.5) * 0.55 * uIntensity;
    // Soft filmic knee so cores bloom without clipping flat white.
    col = col / (col + vec3(0.55));
    col *= 1.22;
  } else {
    // LIGHT: warm wash on paper — never muddy, never pure white blowout.
    col = uBg;
    vec3 paperFire = mix(fireCol, uInk, 0.08);
    col = mix(col, underCol, (under * 0.14 + underWide * 0.06) * uIntensity);
    col = mix(col, paperFire, core * 0.55 * uIntensity);
    col = mix(col, hotCore, bloom * 0.28 * uIntensity);
    col = mix(col, streakCol, clamp(streak, 0.0, 1.0) * 0.18 * uIntensity);
  }

  // Gentle pointer brass scoop glow.
  if(uPointerActive > 0.5){
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(pc - pp);
    float scoop = exp(-dd * dd * 5.5);
    col += seFireRamp(0.65) * scoop * 0.14 * (uTheme < 0.5 ? 1.0 : 0.45) * uIntensity;
  }

  // Vignette for UI chrome legibility.
  float vig = smoothstep(1.55, 0.18, length(pc));
  col = mix(uBg, col, 0.42 + 0.58 * vig);

  return col;
}
`;

export function createSwarmEmberKernel(_options: SwarmEmberKernelOptions = {}): Kernel {
  // Options retained for BackdropEngine API compat.
  // motionSpeedMultiplier: shader uses a fixed cinematic clock (see BODY).
  // enableSwarmSparkles: micro-flicker is always built into seFlicker().
  void _options;
  return createShaderKernel({
    id: "swarmEmber",
    label: "Swarm Ember",
    body: BODY,
  });
}
