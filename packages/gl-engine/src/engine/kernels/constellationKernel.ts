/**
 * Constellation kernel — a cinematic deep-sky field.
 *
 * Stacked celestial layers (not a lazy domain-warp-and-dots shim):
 *  1. Milky-way galactic band with dark dust lanes
 *  2. Multi-depth domain-warped emission nebulae (cool dust + warm cores)
 *  3. Three parallax star strata (dim dust → mid field → bright anchors)
 *  4. Diffraction spikes + hot cores on bright stars
 *  5. Sparse intentional constellation chords (hash-gated, soft ink)
 *  6. Pointer as a local gravitational lens (warp + caustic ring)
 *
 * Single-pass GLSL ES 3.00 via {@link createShaderKernel}. Palette-driven.
 * Loops use constant bounds (ANGLE/WebGL2 safe). No Canvas2D / float sim.
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Constellation — cinematic deep sky ───────────────────────────────────

// Remap snoise/fbm from ~[-1,1] → [0,1].
float n01(float n){ return clamp(n * 0.5 + 0.5, 0.0, 1.0); }

float fbm2(vec3 q){
  return snoise(q) * 0.55 + snoise(q * 2.17) * 0.28;
}

float distSeg(vec2 p, vec2 a, vec2 b){
  vec2 pa = p - a;
  vec2 ba = b - a;
  float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
  return length(pa - ba * h);
}

// Soft airy-disk star: core + bloom + optional diffraction cross.
vec3 drawStar(vec2 d, float size, float tw, vec3 tint, float spikes){
  float r = length(d);
  float invS = 1.0 / max(size, 1e-5);
  float core = exp(-r * r * invS * invS * 5.5);
  float bloom = exp(-r * r * invS * invS * 0.55);
  float ang = atan(d.y, d.x);
  float sp =
    exp(-abs(sin(ang * 2.0)) * (14.0 + 10.0 * invS * 0.01)) *
    exp(-r * r * invS * invS * 0.08) *
    spikes;
  float hot = core * core;
  vec3 c = tint * (bloom * 0.7 + core * 1.4) * tw;
  c += mix(tint, vec3(1.0), 0.75) * hot * 1.6 * tw;
  c += mix(tint, vec3(0.82, 0.9, 1.0), 0.45) * sp * 1.1 * tw;
  return c;
}

// Sparse star layer. aliveThr = minimum hash to live (higher → sparser).
vec3 starLayer(
  vec2 p, float cell, float aliveThr, float sizeMul, float tTwinkle,
  float parallax, vec2 ptr, float ptrActive, float spikesAmt
){
  vec2 drift = vec2(parallax * 0.1, -parallax * 0.035);
  vec2 q = p + drift;
  if(ptrActive > 0.5){
    vec2 d = q - ptr;
    float dd = length(d);
    float lens = exp(-dd * dd * 6.5);
    q += normalize(d + 1e-4) * lens * 0.035 * (0.55 + 0.45 * parallax);
  }

  vec2 g = q / cell;
  vec2 id = floor(g);
  vec3 acc = vec3(0.0);

  for(int oy = -1; oy <= 1; oy++){
    for(int ox = -1; ox <= 1; ox++){
      vec2 nid = id + vec2(float(ox), float(oy));
      float h0 = hash21(nid + parallax * 13.7);
      if(h0 < aliveThr) continue;

      vec2 jit = vec2(hash21(nid + 2.17), hash21(nid + 9.41));
      vec2 sp = (nid + jit) * cell + drift;
      vec2 d = q - sp;

      float mag = hash21(nid + 4.4);
      float size = (0.0024 + 0.0075 * pow(mag, 1.8)) * sizeMul;
      float twPhase = hash21(nid + 11.9) * 6.2831853;
      float twRate = 0.4 + hash21(nid + 17.2) * 1.6;
      float tw = 0.7 + 0.3 * sin(tTwinkle * twRate + twPhase);
      if(mag > 0.9) tw = 0.5 + 0.5 * pow(abs(sin(tTwinkle * twRate * 0.65 + twPhase)), 0.55);

      float spect = hash21(nid + 6.6);
      vec3 tint = mix(
        mix(accentRamp(0.08), vec3(0.72, 0.86, 1.0), 0.6),
        mix(accentRamp(0.88), vec3(1.0, 0.86, 0.68), 0.5),
        spect
      );
      tint = mix(tint, vec3(1.0), smoothstep(0.8, 0.97, mag) * 0.6);

      float spikes = spikesAmt * smoothstep(0.75, 0.96, mag);
      float rot = (hash21(nid + 21.3) - 0.5) * 0.75;
      float cs = cos(rot), sn = sin(rot);
      vec2 dr = vec2(cs * d.x - sn * d.y, sn * d.x + cs * d.y);

      acc += drawStar(dr, size, tw, tint, spikes);
    }
  }
  return acc;
}

// Constellation chords — constant-bound loops only (ANGLE-safe).
float constellationInk(vec2 p, float t, vec2 ptr, float ptrActive){
  float cell = 0.4;
  vec2 id = floor(p / cell);
  float ink = 0.0;

  for(int i = 0; i < 9; i++){
    float ix = float(i - (i / 3) * 3) - 1.0;
    float iy = float(i / 3) - 1.0;
    vec2 nidA = id + vec2(ix, iy);
    float hA = hash21(nidA + 31.0);
    if(hA < 0.8) continue;
    vec2 jitA = vec2(hash21(nidA + 1.3), hash21(nidA + 4.8));
    vec2 a = (nidA + jitA) * cell;

    for(int j = 0; j < 9; j++){
      if(j <= i) continue;
      float jx = float(j - (j / 3) * 3) - 1.0;
      float jy = float(j / 3) - 1.0;
      vec2 nidB = id + vec2(jx, jy);
      float hB = hash21(nidB + 31.0);
      if(hB < 0.8) continue;
      vec2 jitB = vec2(hash21(nidB + 1.3), hash21(nidB + 4.8));
      vec2 b = (nidB + jitB) * cell;

      float sep = length(a - b);
      if(sep < 0.2 || sep > 0.92) continue;

      float edge = hash21(floor((a + b) * 19.0) + vec2(sep * 40.0, 7.0));
      if(edge < 0.7) continue;

      float pulse = 0.78 + 0.22 * sin(t * 0.55 + edge * 12.0 + sep * 4.0);
      float ds = distSeg(p, a, b);
      float thr = 0.0014 + 0.0007 * edge;
      float fil = 1.0 - smoothstep(thr, thr * 5.0, ds);
      fil = fil * fil * fil;
      float node =
        exp(-dot(p - a, p - a) / 0.0007) +
        exp(-dot(p - b, p - b) / 0.0007);
      fil = max(fil, node * 0.6);
      fil *= pulse;
      fil *= smoothstep(0.92, 0.25, sep);
      if(ptrActive > 0.5){
        float dd = length(p - ptr);
        fil *= 1.0 - exp(-dd * dd * 5.0) * 0.85;
      }
      ink = max(ink, fil);
    }
  }
  return ink;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  float t  = uTime * 0.038;
  float t2 = uTime * 0.014;
  float t3 = uTime * 0.58;
  float t4 = uTime * 0.008;

  vec2 ptr = vec2(0.0);
  float ptrActive = 0.0;
  if(uPointerActive > 0.5){
    ptr = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    ptrActive = 1.0;
  }

  vec2 warp = vec2(0.0);
  float ptrFall = 0.0;
  if(ptrActive > 0.5){
    vec2 dptr = p - ptr;
    float dd = length(dptr);
    ptrFall = exp(-dd * dd * 4.8);
    warp = normalize(dptr + 1e-4) * ptrFall * 0.055;
  }
  vec2 pw = p + warp;

  // ── 1. Galactic band ───────────────────────────────────────────────────
  float bandAng = 0.52 + 0.07 * sin(t4 * 1.7);
  float ca = cos(bandAng), sa = sin(bandAng);
  vec2 bp = vec2(ca * pw.x + sa * pw.y, -sa * pw.x + ca * pw.y);
  bp.x += t2 * 0.18;
  float bandDist = abs(bp.y + 0.14 * snoise(vec3(bp.x * 1.35, t2, 0.5)));
  float band = exp(-bandDist * bandDist * 11.0);
  float bandTurb = n01(fbm(vec3(bp * vec2(1.7, 3.0) + vec2(t2 * 0.35, 0.0), t * 0.55)));
  band *= 0.5 + 0.6 * bandTurb;
  float dust = smoothstep(0.2, 0.7, n01(fbm(vec3(bp * vec2(2.5, 5.5), t2 + 2.0))));
  float dustLane = pow(1.0 - dust, 2.0) * band;
  band *= mix(0.5, 1.0, dust);

  // ── 2. Emission nebulae ────────────────────────────────────────────────
  vec2 q = vec2(
    n01(fbm(vec3(pw * 0.9 + vec2(0.0, t * 0.22), t))),
    n01(fbm(vec3(pw * 0.9 + vec2(4.1, 1.7) - vec2(t * 0.16, 0.0), t * 0.8))));
  vec2 r = vec2(
    n01(fbm(vec3(pw * 1.2 + 1.35 * (q * 2.0 - 1.0) + vec2(1.7, 9.2), t * 0.9))),
    n01(fbm(vec3(pw * 1.2 + 1.35 * (q * 2.0 - 1.0) + vec2(8.3, 2.8), t * 0.9))));
  float nA = n01(fbm(vec3(pw * 1.05 + 1.5 * (r * 2.0 - 1.0), t * 0.65)));
  float densA = smoothstep(0.28, 0.82, 0.5 * nA + 0.35 * q.x + 0.12);

  vec2 pwB = pw * 1.3 + vec2(t2 * 0.18, -t2 * 0.1) + 0.5 * (r * 2.0 - 1.0);
  float nB = n01(fbm(vec3(pwB * 1.55, t * 1.0 + 3.1)));
  float ridge = 1.0 - abs(nB * 2.0 - 1.0);
  ridge *= ridge;
  float densB = smoothstep(0.3, 0.9, ridge * 0.75 + nB * 0.3);

  float nC = n01(fbm2(vec3(pw * 3.0 + 1.8 * (q * 2.0 - 1.0), t * 1.25)));
  float densC = smoothstep(0.5, 0.92, nC) * densA;

  float breath = 0.88 + 0.12 * sin(t2 * 4.5 + densA * 3.0);

  vec3 nebCool = accentRamp(0.1 + 0.28 * densA);
  vec3 nebWarm = accentRamp(0.52 + 0.38 * densB);
  vec3 nebHot  = mix(accentRamp(0.8), vec3(1.0, 0.93, 0.86), 0.4);

  // ── 3. Star strata ─────────────────────────────────────────────────────
  // aliveThr lower = denser field
  vec3 starsFar  = starLayer(pw, 0.07,  0.42, 0.7,  t3, 0.25, ptr, ptrActive, 0.0);
  vec3 starsMid  = starLayer(pw, 0.125, 0.62, 1.15, t3, 0.55, ptr, ptrActive, 0.45);
  vec3 starsNear = starLayer(pw, 0.24,  0.8,  2.1,  t3, 1.0,  ptr, ptrActive, 1.0);

  // ── 4. Constellation ink ───────────────────────────────────────────────
  float fil = constellationInk(pw, t, ptr, ptrActive);
  fil *= mix(1.0, 0.4, clamp(densA * 0.65 + densB * 0.45, 0.0, 1.0));
  vec3 filTint = mix(accentRamp(0.42), vec3(0.88, 0.92, 1.0), 0.45);

  // ── Composite ──────────────────────────────────────────────────────────
  vec3 col;
  if(uTheme < 0.5){
    col = uBg;

    vec3 bandCol = mix(accentRamp(0.18), accentRamp(0.58), bandTurb);
    col += bandCol * band * 0.38 * uIntensity * breath;
    col *= 1.0 - dustLane * 0.4;

    col += nebCool * densA * densA * 0.55 * uIntensity * breath;
    col += nebWarm * densB * 0.7 * uIntensity;
    col += nebHot  * densB * densB * densB * 0.55 * uIntensity;
    col += nebCool * densC * 0.18 * uIntensity;

    col += starsFar  * 0.55 * uIntensity;
    col += starsMid  * 0.95 * uIntensity;
    col += starsNear * 1.35 * uIntensity;

    col += filTint * fil * 0.85 * uIntensity;

    if(ptrActive > 0.5){
      float ring = abs(length(p - ptr) - 0.11);
      float caust = exp(-ring * ring * 850.0) * ptrFall;
      col += accentRamp(fract(0.55 + t2 * 2.0)) * caust * 0.55 * uIntensity;
      col += accentRamp(0.28) * ptrFall * ptrFall * 0.1 * uIntensity;
    }

    // Soft filmic lift — keep blacks deep but stars luminous
    col = max(col, vec3(0.0));
    col = col / (col + vec3(0.55)) * 1.22;
  } else {
    col = uBg;
    float vA = pow(densA, 0.9);
    float vB = pow(densB, 1.05);
    col = mix(col, mix(uBg, nebCool, 0.75), vA * 0.45 * uIntensity);
    col = mix(col, mix(uBg, nebWarm, 0.78), vB * 0.28 * uIntensity);
    col = mix(col, mix(uBg, accentRamp(0.35), 0.55), band * 0.22 * uIntensity);

    float starL = clamp(dot(starsMid + starsNear, vec3(0.33)), 0.0, 2.5);
    col = mix(col, mix(accentRamp(0.5), uInk, 0.35), clamp(starL * 0.4, 0.0, 0.6) * uIntensity);
    col = mix(col, uInk, clamp(dot(starsNear, vec3(0.33)) * 0.6, 0.0, 0.45) * uIntensity);
    col = mix(col, mix(filTint, uInk, 0.45), fil * 0.38 * uIntensity);

    if(ptrActive > 0.5){
      col = mix(col, mix(uBg, accentRamp(0.5), 0.5), ptrFall * 0.14 * uIntensity);
    }
  }

  float env = smoothstep(-1.2, -0.12, p.y) * smoothstep(1.25, 0.02, p.y);
  col = mix(uBg, col, 0.5 + 0.5 * env);

  float vig = smoothstep(1.7, 0.2, length(p));
  col = mix(uBg, col, 0.35 + 0.65 * vig);

  return col;
}
`;

export function createConstellationKernel(): Kernel {
  return createShaderKernel({
    id: "constellation",
    label: "Constellation",
    body: BODY,
  });
}
