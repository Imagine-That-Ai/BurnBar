#version 300 es
precision highp float;
out vec4 fragColor;
uniform vec2  uResolution;
uniform float uTime;
uniform vec2  uPointer;        // 0..1, y up
uniform float uPointerActive;  // 0 or 1
uniform vec3  uBg;
uniform vec3  uAccent0;
uniform vec3  uAccent1;
uniform vec3  uAccent2;
uniform vec3  uAccent3;
uniform vec3  uInk;
uniform float uIntensity;
uniform float uTheme;          // 0 dark, 1 light
uniform vec2  uScroll;
uniform float uScrollVel;



vec3 mod289(vec3 x){ return x - floor(x * (1.0/289.0)) * 289.0; }
vec4 mod289(vec4 x){ return x - floor(x * (1.0/289.0)) * 289.0; }
vec4 permute(vec4 x){ return mod289(((x*34.0)+1.0)*x); }
vec4 taylorInvSqrt(vec4 r){ return 1.79284291400159 - 0.85373472095314 * r; }
float snoise(vec3 v){
  const vec2 C = vec2(1.0/6.0, 1.0/3.0);
  const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);
  vec3 i  = floor(v + dot(v, C.yyy));
  vec3 x0 = v - i + dot(i, C.xxx);
  vec3 g = step(x0.yzx, x0.xyz);
  vec3 l = 1.0 - g;
  vec3 i1 = min(g.xyz, l.zxy);
  vec3 i2 = max(g.xyz, l.zxy);
  vec3 x1 = x0 - i1 + C.xxx;
  vec3 x2 = x0 - i2 + C.yyy;
  vec3 x3 = x0 - D.yyy;
  i = mod289(i);
  vec4 p = permute(permute(permute(
            i.z + vec4(0.0, i1.z, i2.z, 1.0))
          + i.y + vec4(0.0, i1.y, i2.y, 1.0))
          + i.x + vec4(0.0, i1.x, i2.x, 1.0));
  float n_ = 0.142857142857;
  vec3 ns = n_ * D.wyz - D.xzx;
  vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
  vec4 x_ = floor(j * ns.z);
  vec4 y_ = floor(j - 7.0 * x_);
  vec4 x = x_ *ns.x + ns.yyyy;
  vec4 y = y_ *ns.x + ns.yyyy;
  vec4 h = 1.0 - abs(x) - abs(y);
  vec4 b0 = vec4(x.xy, y.xy);
  vec4 b1 = vec4(x.zw, y.zw);
  vec4 s0 = floor(b0)*2.0 + 1.0;
  vec4 s1 = floor(b1)*2.0 + 1.0;
  vec4 sh = -step(h, vec4(0.0));
  vec4 a0 = b0.xzyw + s0.xzyw*sh.xxyy;
  vec4 a1 = b1.xzyw + s1.xzyw*sh.zzww;
  vec3 p0 = vec3(a0.xy, h.x);
  vec3 p1 = vec3(a0.zw, h.y);
  vec3 p2 = vec3(a1.xy, h.z);
  vec3 p3 = vec3(a1.zw, h.w);
  vec4 norm = taylorInvSqrt(vec4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3)));
  p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
  vec4 m = max(0.6 - vec4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
  m = m * m;
  return 42.0 * dot(m*m, vec4(dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3)));
}


float fbm(vec3 p){
  float a = 0.5, s = 0.0;
  for(int i = 0; i < 3; i++){
    s += a * snoise(p);
    p *= 2.0;
    a *= 0.5;
  }
  return s;
}


float hash21(vec2 p){
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
// Triangular-PDF dither, ~±1 LSB at 8-bit.
vec3 dither(vec2 fragCoord){
  float r = hash21(fragCoord);
  float r2 = hash21(fragCoord + 17.0);
  return vec3((r + r2 - 1.0)) / 255.0;
}


vec3 accentRamp(float t){
  t = clamp(t, 0.0, 1.0) * 3.0;
  vec3 c01 = mix(uAccent0, uAccent1, smoothstep(0.0, 1.0, t));
  vec3 c12 = mix(uAccent1, uAccent2, smoothstep(1.0, 2.0, t));
  vec3 c23 = mix(uAccent2, uAccent3, smoothstep(2.0, 3.0, t));
  vec3 c = c01;
  c = mix(c, c12, step(1.0, t));
  c = mix(c, c23, step(2.0, t));
  return c;
}


// Projector pinned dead-still off-canvas bottom-center. Beam aim eases toward
// the pointer (never snaps). Cone half-angle, shaft reach, fog density.
const float BEAM_HALF_ANGLE = 0.11;
const float SHAFT_LEN       = 2.8;
const float FOG_FREQ        = 1.5;
const float FOG_COVERAGE    = 0.44;
const float FOG_GAIN        = 1.4;
const float N_RAYS          = 5.0;     // a small steady set of god-rays

// Fog + grain ride the injected shared chunks (snoise/fbm/hash21) — one code
// path, finer simplex in-scatter grain than the old bespoke value noise.

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5*uResolution)/uResolution.y;

  float sN = uScroll.y > 0.0 ? uScroll.x/uScroll.y : 0.0;
  // one calm slow breath (very small amplitude) — alive, never busy. Retuned
  // against the LIVE clock (this term was authored on the dead reactive clock).
  float breath = 0.93 + 0.07*sin(uTime*0.45);

  // Projector origin: DEAD STILL, off-canvas bottom-center.
  vec2 proj = vec2(0.0, -1.15);

  // Beam AIM. Pointer ACTIVE → beam EASES toward the cursor (heavy ease so it
  // drifts, never snaps; pointer sits in the lower-mid sky so the beam rises at
  // a calm diagonal). Pointer ABSENT → a single near-static beam with the
  // faintest sway, not a sweep.
  vec2 aimN;
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer*uResolution - 0.5*uResolution)/uResolution.y;
    // compress + bias the target so the beam stays a graceful near-vertical
    // diagonal (never horizontal, never whipping to the edges).
    vec2 target = vec2(pp.x*0.5, max(pp.y, -0.1)*0.6 + 0.55);
    aimN = normalize(target - proj);
  } else {
    // heavy mounted lamp: a slow weighted sway — one long fundamental plus a
    // softer off-phase counter-swing so the lamp never reads as a metronome.
    float sway = sin(uTime*0.22)*0.10 + sin(uTime*0.083 + 1.3)*0.045;
    aimN = normalize(vec2(sway, 1.0));
  }

  // ── cone geometry: perp/along distance to the beam axis ──────────────────
  vec2 toP = p - proj;
  float along = dot(toP, aimN);
  float perp  = abs(toP.x*aimN.y - toP.y*aimN.x);
  // cone envelope: bright on axis, feathered at the half-angle, dead past it.
  float cone = smoothstep(BEAM_HALF_ANGLE, 0.0, perp/max(along, 0.001));
  // reach: beam fades with distance + only the forward half-cone.
  float reach = smoothstep(SHAFT_LEN, 0.0, along) * step(0.0, along);
  float beam = cone*reach;
  beam *= 0.8 + 0.2*breath;

  // ── fog field: shared 3-octave simplex fbm that BRIGHTENS where the beam
  // passes. Time rides the z axis so the fog CHURNS (not just translates) —
  // the finer in-scatter grain is the craft cue. Drifts slowly upward.
  vec3 fq = vec3(p*FOG_FREQ + vec2(uTime*0.022 + sN*1.2, -uTime*0.05), uTime*0.08);
  float fog = max(0.0, fbm(fq)*0.5 + 1.0 - FOG_COVERAGE) * FOG_GAIN * breath;
  // in-scatter: fog lit by the beam — the visible volumetric body of the cone.
  float scatter = fog * beam;

  // ── steady crepuscular god-rays: a small set, gently breathing in unison ─
  float rays = 0.0;
  for (float i = 0.0; i < N_RAYS; i += 1.0){
    float u = (i + 0.5)/N_RAYS - 0.5;            // -0.5..0.5 across the cone
    float angOff = u*BEAM_HALF_ANGLE*1.6;
    vec2 rayDir = vec2(aimN.x*cos(angOff) - aimN.y*sin(angOff),
                       aimN.x*sin(angOff) + aimN.y*cos(angOff));
    float rAlong = dot(toP, rayDir);
    float rPerp  = abs(toP.x*rayDir.y - toP.y*rayDir.x);
    float rCone  = smoothstep(0.016, 0.0, rPerp) * step(0.0, rAlong)
                   * smoothstep(SHAFT_LEN, 0.0, rAlong);
    rays += rCone;
  }
  rays *= breath * (0.85 + 0.15*sin(uTime*0.3 + 2.0)); // one shared slow pulse

  // ── lens flare at the projector origin ────────────────────────────────────
  float bloom = exp(-dot(toP,toP)*9.0) * breath;

  // tint: a steady cold sky-beam blue (held still — color must not wobble).
  vec3 tint = accentRamp(0.62);
  vec3 hot  = accentRamp(0.74);
  // flare + grain colors derive from the palette (uInk is the light foreground
  // in dark theme, so mixing toward it keeps the near-white lift palette-true).
  vec3 flare = mix(hot, uInk, 0.55);
  vec3 grainCol = mix(tint, uInk, 0.35);

  vec3 col;
  if (uTheme < 0.5){
    // DARK: additive in-scatter over deep ink, filmic knee blooms cores to white.
    col  = uBg;
    col += tint*beam*0.5*uIntensity;             // cone body
    col += tint*scatter*1.4*uIntensity;          // lit fog (the visible volume)
    col += hot*rays*0.16*uIntensity;             // steady god-rays
    col += flare*bloom*0.6*uIntensity;           // source flare
    col += grainCol*(hash21(fragCoord)-0.5)*0.012*(1.0-beam); // grain floor
    col = col/(col+vec3(0.6));
    col *= 1.14;
  } else {
    // LIGHT: pale luminous column deposited softly (never toward white).
    float v = pow(clamp(beam*0.7 + scatter*0.5, 0.0, 1.0), 0.85);
    vec3 pearl = mix(uBg, tint, 0.7);
    col = mix(uBg, pearl, v*0.38*uIntensity);
    col = mix(col, hot, clamp(rays*0.5, 0.0, 1.0)*0.10*uIntensity);
    col = mix(col, uInk, smoothstep(0.1, 0.6, v)*0.03*uIntensity);
    col = mix(col, tint, bloom*0.14*uIntensity); // soft flare disc
  }

  // Vignette to protect glass-type legibility. Return linear color — MAIN
  // applies the shared ordered dither that breaks the shaft's long gradients.
  float vig = smoothstep(1.7, 0.3, length(p));
  col = mix(uBg, col, 0.4 + 0.6*vig);
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}