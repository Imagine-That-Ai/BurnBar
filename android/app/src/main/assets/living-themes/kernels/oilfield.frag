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


// ── Oilfield — anisotropic-Kuwahara painterly filter over an fbm field ────

// Drifting warped fbm color field, mapped through the palette. Exactly ONE
// fbm + ONE snoise per call — the whole Kuwahara window stays on budget, and
// the freed cost pays for time coefficients fast enough to read as wet paint
// sliding within 2 s (the old 3-fbm field was cost-forced into stillness).
vec3 baseField(vec2 p) {
  float t = uTime * 0.13;
  float w = snoise(vec3(p * 1.5 + vec2(0.0, t * 0.7), t * 0.35));
  float n = fbm(vec3(p * 2.8 + w * 1.3 + vec2(t, -t * 0.6), 0.0));
  // House fbm is ZERO-centered (sum of 0.5/0.25/0.125-weighted snoise), so it
  // is centered on the ramp midpoint directly — subtracting 0.5 here shifted
  // the mean to 0.05 and hard-clamped most of the canvas to accentRamp(0).
  n = clamp(0.5 + 0.9 * n + 0.28 * w, 0.0, 1.0);
  vec3 col = accentRamp(n);
  col = mix(uBg, col, 0.85);
  return col;
}

// Perceptual luminance (renamed to avoid any builtin/chunk collision).
float lumv(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  // Fixed brush stride in UV (wider steps than the old 7x7 keep the same
  // patch footprint from fewer taps); pointer locally fattens the stroke.
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 px = vec2(1.0 / uResolution.y) * 3.2;
  vec2 pd = (uv - uPointer) * vec2(aspect, 1.0);
  px *= 1.0 + 0.9 * uPointerActive * exp(-dot(pd, pd) * 22.0);

  // Smoothly rotating sampling window: a low-frequency simplex field (in
  // aspect-corrected UV, so it is DPR/resolution independent) steers the
  // quadrant sector boundaries, so flat regions stop tiling into
  // axis-aligned blocks and read as knife strokes — with NO discontinuity
  // anywhere (a piecewise-constant per-cell hash jumps the winning-quadrant
  // mean at every cell border and prints its own device-px lattice). The
  // quadrant layout is pi/2-symmetric, so the +-pi range covers all angles.
  float ang = snoise(vec3(uv * vec2(aspect, 1.0) * 5.0, 4.7)) * 3.14159265;
  vec2 rot = vec2(cos(ang), sin(ang));

  // Four overlapping quadrant accumulators (mean color + luminance sq-sum).
  vec3 mean0 = vec3(0.0), mean1 = vec3(0.0), mean2 = vec3(0.0), mean3 = vec3(0.0);
  float sq0 = 0.0, sq1 = 0.0, sq2 = 0.0, sq3 = 0.0;
  float cnt0 = 0.0, cnt1 = 0.0, cnt2 = 0.0, cnt3 = 0.0;

  // CONSTANT 5×5 window (radius 2) — compile-time loop bounds, unrolls clean.
  for (int j = -2; j <= 2; j++) {
    for (int i = -2; i <= 2; i++) {
      vec2 g = vec2(float(i), float(j));
      vec2 off = vec2(g.x * rot.x - g.y * rot.y, g.x * rot.y + g.y * rot.x) * px;
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


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}