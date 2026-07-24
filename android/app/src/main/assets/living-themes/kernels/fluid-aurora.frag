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


vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  // Normalised centred coordinates, y-up, aspect-correct.
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // ── Time clocks (multi-frequency so the loop never visually repeats) ──
  float t  = uTime * 0.05;   // master drift
  float t2 = uTime * 0.023;  // slower hue roll

  // ── Horizon: aurora-over-water ──
  // Below the waterline the sky is sampled mirrored about the horizon and
  // vertically compressed (0.72), so the reflection reads stretched/smeared,
  // with a scrolling two-frequency ripple wobbling x. One sample space feeds
  // all five fbm taps — the reflection is free.
  const float HORIZON = -0.34;
  float below = smoothstep(HORIZON + 0.01, HORIZON - 0.01, p.y);
  float wdepth = max(HORIZON - p.y, 0.0);
  float ripple = sin(p.y * 46.0 + uTime * 0.8 + p.x * 3.0) * 0.011
               + sin(p.y * 88.0 - uTime * 1.6) * 0.005;
  vec2 sp = p;
  sp.y = mix(p.y, HORIZON + wdepth * 0.72, below);
  sp.x += ripple * below * (0.5 + wdepth * 1.8);

  // ── Domain warp: two layers of fbm advection ──
  // q = first warp field, r = second warp field, f = final scalar warp.
  vec2 q = vec2(
    fbm(vec3(sp * 1.6, t)),
    fbm(vec3(sp * 1.6 + 5.2, t)));

  // ── Pointer gust: the cursor locally drags the first warp layer (a swirl
  // plus a radial push, aspect-corrected exp falloff), so both downstream fbm
  // layers comb around it. Analytic only — no extra noise taps.
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 pp = (uPointer - 0.5) * vec2(aspect, 1.0);
  vec2 toPtr = p - pp;
  float gust = uPointerActive * exp(-6.5 * dot(toPtr, toPtr));
  q += gust * (0.55 * vec2(toPtr.y, -toPtr.x) + 0.30 * toPtr)
       / (length(toPtr) + 0.15);

  vec2 r = vec2(
    fbm(vec3(sp * 1.6 + 1.3 * q + vec2(1.7, 9.2), t * 1.1)),
    fbm(vec3(sp * 1.6 + 1.3 * q + vec2(8.3, 2.8), t * 1.1)));
  float f = fbm(vec3(sp * 1.6 + 1.5 * r, t * 0.9));
  vec2 flow = 1.5 * r + 0.6 * q;

  // ── Three layered curtains (pure trig, zero extra noise) ──
  vec3 acc = vec3(0.0);
  for (int i = 0; i < 3; i++) {
    float di = float(i);
    float depth = 1.0 - 0.30 * di;
    float lt = t * (1.0 + 0.22 * di) + di * 2.39996; // golden-angle offset
    vec2 lp = sp * (1.0 - 0.14 * di);
    lp.x += t2 * (1.0 + 0.2 * di) * 1.4;

    float x = lp.x * 3.0 + flow.x * (1.1 * depth) + lt;
    float hgt = lp.y * 1.3 + f * 0.85 + flow.y * 0.45;

    // Cheap fractal filaments (3 octaves abs(sin)) — no extra snoise.
    float fil = 0.0, amp = 1.0, fq = 1.0;
    for (int k = 0; k < 3; k++) {
      fil += amp * abs(sin(x * fq + hgt * 1.2));
      fq *= 2.2;
      amp *= 0.5;
    }
    fil *= 0.571;

    float edge = smoothstep(0.0, 1.0, fil);
    float core = 1.0 - edge;
    core = core * core * (3.0 - 2.0 * core); // smootherstep
    float glow = core * core;

    // Vertical envelope (fade top/bottom for legibility).
    float env = smoothstep(-1.1, -0.2, lp.y) * smoothstep(1.2, 0.1, lp.y);

    // Altitude-keyed hue via the shared accent ramp.
    float hue = clamp(0.5 + hgt * 0.5 + 0.1 * f + di * 0.05, 0.0, 1.0);
    vec3 accent = accentRamp(hue);

    float lum = glow * env;
    acc += accent * lum * (0.60 / (1.0 + 0.45 * di));
    // Per-curtain glint, accent-derived (white lifted toward uAccent3).
    acc += mix(vec3(1.0), uAccent3, 0.45) * pow(glow, 4.0) * env * 0.16 * (1.0 - 0.25 * di);
  }

  // ── Water composite: dim the mirrored field with depth, then ride a thin
  // accent glint along the waterline itself (modulated by the warp scalar so
  // it shimmers rather than rules a line).
  acc *= mix(1.0, 0.12 + 0.55 * exp(-wdepth * 2.2), below);
  float shoreline = exp(-abs(p.y - HORIZON) * 55.0);
  acc += mix(vec3(1.0), uAccent1, 0.55) * shoreline
       * (0.10 + 0.14 * clamp(0.5 + 0.5 * f, 0.0, 1.0));

  // ── Theme composite (identical timing, math flips for light) ──
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: additive over deep ink (the water plane a shade deeper), filmic knee bloom.
    col = uBg * (1.0 - 0.10 * below);
    col += acc * (0.95 * uIntensity);
    col = col / (col + vec3(0.55));
    col *= 1.18;
  } else {
    // LIGHT: pearl watermark — soft, never muddy.
    col = uBg;
    float v = pow(clamp(dot(acc, vec3(0.45)) * 1.6, 0.0, 1.0), 0.72);
    vec3 ribbon = accentRamp(clamp(0.40 + 0.36 * v + 0.08 * f, 0.0, 1.0));
    vec3 pearl = mix(uBg, ribbon, 0.88);
    col = mix(col, pearl, v * 0.58 * uIntensity);
    col = mix(col, uInk, smoothstep(0.10, 0.58, v) * 0.04 * uIntensity);
    col = mix(col, ribbon, pow(v, 2.4) * 0.16 * uIntensity);
    // Water plane: a whisper of ink so the horizon reads in light too.
    col = mix(col, uInk, below * 0.045 * uIntensity);
  }

  // ── Pointer halo (subtle, breath-cycled) ──
  if (uPointerActive > 0.5) {
    float dd = length(toPtr);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.22 * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // ── Vignette (protects text legibility) ──
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.35 + 0.65 * vig);
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}