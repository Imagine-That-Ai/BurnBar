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


// ── Vogel Bloom — golden-angle phyllotaxis seed field ─────────────────────
const float VB_GA = 2.399963229728653; // golden angle (137.5°)
const float VB_C  = 0.045;             // Vogel radial constant

// One phyllotaxis seed: soft glowing dot + heliotropism + shimmer fronts.
// pp = pointer mapped into seed space; returns the dot's glow weight.
float vbSeedGlow(vec2 p, vec2 pp, float idx) {
  float ang = idx * VB_GA;
  float rad = VB_C * sqrt(idx);
  vec2 seed = rad * vec2(cos(ang), sin(ang));
  // Heliotropism: seeds near the cursor lean toward it and brighten.
  vec2 toPtr = pp - seed;
  float pd = length(toPtr) + 1e-4;
  float heli = uPointerActive * exp(-pd * pd * 7.0);
  seed += toPtr * (heli * 0.014 / pd);
  float d = length(p - seed);
  float dotR = 0.012 + 0.010 * sqrt(idx) * VB_C;
  float dval = smoothstep(dotR, dotR * 0.35, d);            // soft glowing dot
  float shimmer = 0.55 + 0.45 * sin(rad * 14.0 - uTime * 2.0); // outward pulse
  // Second shimmer front radiating outward from the pointer itself.
  shimmer += uPointerActive * exp(-pd * 1.6)
           * (0.30 + 0.30 * sin(pd * 11.0 - uTime * 6.0));
  return dval * shimmer * (1.0 + heli * 0.8);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 res = uResolution;
  vec2 p = (fragCoord - 0.5 * res) / res.y;

  // ── Living transform: slow rotation + breathing zoom. The pointer no
  //    longer pans the head — it acts on the seeds via heliotropism. ──
  float t = uTime * 0.15;
  float ca = cos(t), sa = sin(t);
  mat2 rot = mat2(ca, -sa, sa, ca);
  float zoomF = 1.6 + 0.25 * sin(uTime * 0.30);
  p = rot * p * zoomF;
  // Pointer through the SAME transform so it lives in seed space.
  vec2 pp = rot * ((uPointer - 0.5) * vec2(res.x / res.y, 1.0)) * zoomF;

  float r = length(p) + 1e-5;

  // ── Inverse Vogel: nearest seed index i ≈ (r/c)²; probe a tiny window. ──
  float fi = r / VB_C; fi = fi * fi;
  float i0 = floor(fi);

  float bloom = 0.0;
  float tintIdx = 0.0;
  float wsum = 1e-5;
  // Solid core: the inverse index is unreliable at r→0 (angular neighbours
  // are far apart in index space), so seeds 0-7 are resolved directly for the
  // innermost radius. Their reach is rad(7)+dotR ≈ 0.135, so the r-gate keeps
  // the outer field on the plain 7-sample budget (coherent branch, cheap).
  if (r < 0.22) {
    for (int k = 0; k < 8; k++) {
      float idx = float(k);
      float dval = vbSeedGlow(p, pp, idx);
      bloom += dval;
      tintIdx += idx * dval;
      wsum += dval;
    }
  }
  for (int k = -3; k <= 3; k++) {       // fixed 7-sample probe (mobile 60fps)
    float idx = i0 + float(k);
    if (idx < 8.0) continue;            // core seeds handled analytically above
    float dval = vbSeedGlow(p, pp, idx);
    bloom += dval;
    tintIdx += idx * dval;
    wsum += dval;
  }
  bloom = clamp(bloom, 0.0, 1.0);

  // ── Palette hue from the seed index (rolls across the accent ramp). ──
  float seedT = fract((tintIdx / wsum) * 0.0125);
  vec3 ramp = accentRamp(seedT);

  // ── Fibonacci spiral arms (parastichy interference) shimmering outward. ──
  float arms = abs(sin(0.5 * (atan(p.y, p.x) - r * 9.0 + uTime * 0.6)));
  vec3 armCol = accentRamp(fract(r * 0.4 + uTime * 0.05));
  float armGlow = (1.0 - arms) * smoothstep(1.3, 0.2, r);

  // ── Signature cue: a specular glint racing outward from the pointer ALONG
  //    the parastichy arms — the arm mask gates a travelling wavefront. ──
  float dp = length(p - pp);
  float glint = pow(1.0 - arms, 6.0)
              * exp(-dp * dp * 1.8)
              * (0.5 + 0.5 * sin(dp * 9.0 - uTime * 4.5))
              * uPointerActive;
  vec3 glintCol = accentRamp(fract(dp * 0.5 - uTime * 0.12));

  // ── Theme composite ──
  // DARK: glowing seed dots bloom over deep ink; arms add a faint shimmer.
  vec3 darkCol = mix(uBg, ramp, bloom);
  darkCol += armCol * armGlow * 0.08;
  darkCol += glintCol * glint * 0.55;
  darkCol = mix(darkCol, uInk, (1.0 - bloom) * 0.06);
  // LIGHT: ink-tinted seed deposits on the warm paper bg (never blows out).
  vec3 lightCol = mix(uBg, mix(ramp, uInk, 0.35), bloom * 0.85);
  lightCol = mix(lightCol, armCol, armGlow * 0.05);
  lightCol = mix(lightCol, mix(glintCol, uInk, 0.30), glint * 0.35);

  vec3 col = (uTheme < 0.5) ? darkCol : lightCol;
  col *= 0.85 + 0.30 * uIntensity;

  // ── Vignette (keeps foreground text legible). ──
  vec2 vu = fragCoord / uResolution;
  col *= smoothstep(1.15, 0.35, length(vu - 0.5) * 1.4);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}