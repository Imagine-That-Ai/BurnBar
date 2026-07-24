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


// ── moiré quasicrystal — tuning constants (mirror quasicrystalWaves.ts) ────
const int   QC_WAVES_C   = 7;
const float QC_GOLDEN_C  = 2.3999632297;
const float QC_FREQ_C    = 9.0;
const float QC_SPIN      = 0.012;     // basis-rotation clock (authentic QC anim)
const float QC_SCRUB     = 0.05;      // global phase-drift clock
const float QC_LENS_TIGHT = 9.0;      // pointer-lens gaussian tightness
const float QC_LENS_STR   = 0.18;     // pointer-lens warp strength
const float QC_PHANTOM_T   = 25.0;    // phantom-lens orbit period (s)
const float QC_PHANTOM_STR = 0.07;    // phantom-lens warp strength (subtle)
const float QC_LENS_CRISP  = 0.45;    // phase-contrast boost inside a lens
const float QC_PI         = 3.14159265;

// IQ analytic band-limited cosine: deactivates a wave before it aliases.
// w = per-pixel domain footprint of x; cos·sinc(w/2), sinc≈(1−smoothstep(0,2π,w)).
// NOTE: explicit 1−smoothstep(0,2π,w) — never smoothstep(2π,0,w): reversed edges
// (edge0>edge1) are undefined in the GLSL ES spec.
float fcos(float x){
  float w = fwidth(x);
  return cos(x) * (1.0 - smoothstep(0.0, 6.28318531, w));
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // STEP 1 — CLOCKS (irrational ratios so nothing visibly loops).
  float breath = 0.5 + 0.5 * (0.62 * sin(6.28318531 * uTime / 14.0)
                            + 0.38 * sin(6.28318531 * uTime / 31.0 + 1.3));
  float spin  = uTime * QC_SPIN;
  float scrub = uTime * QC_SCRUB;
  float freq  = QC_FREQ_C * (0.9 + 0.2 * breath);

  // STEP 2 — LENSES (domain warp). fwidth() on the FINAL phase tracks these
  // warps' frequency change automatically — the reason analytic AA survives warps.
  // 2a — PHANTOM LENS: same warp math at low amplitude, orbiting a ~25s/~40s
  // Lissajous (irrational ratio) so the quasicrystal has a focal anchor at idle.
  vec2 pw = p;
  float lensG;                                         // combined lens presence
  {
    float oa = 6.28318531 * uTime / QC_PHANTOM_T;
    vec2 lc = vec2(cos(oa), sin(oa * 0.618034)) * vec2(0.30, 0.20);
    vec2 d  = p - lc;
    float g = exp(-dot(d, d) * QC_LENS_TIGHT);         // slow ripple bubble
    pw += normalize(d + 1e-4) * g * QC_PHANTOM_STR;
    lensG = g * 0.6;                                    // phantom anchors softer
  }
  // 2b — POINTER LENS: the physical one; takes over under the cursor.
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    vec2 d  = p - pp;
    float r2 = dot(d, d);
    float g  = exp(-r2 * QC_LENS_TIGHT);              // ripple bubble at cursor
    pw += normalize(d + 1e-4) * g * QC_LENS_STR;
    lensG = max(lensG, g);
  }

  // STEP 3 — N-WAVE QUASICRYSTAL SUM, each wave band-limited.
  float q = 0.0;
  for (int j = 0; j < QC_WAVES_C; j++){
    float a  = QC_PI * float(j) / float(QC_WAVES_C) + spin;  // even angle, rotated
    vec2  k  = vec2(cos(a), sin(a)) * freq;                  // |k| = freq
    float ph = float(j) * QC_GOLDEN_C;                        // golden phase seed
    q += fcos(dot(k, pw) + ph + scrub);                       // analytic AA here
  }
  q /= float(QC_WAVES_C);                                     // ≈ [−1, 1]

  // STEP 4 — TONE SHAPING. Inhale crisps the interference nodes; either lens
  // locally boosts phase contrast so the eye has an anchor.
  float sharp = mix(0.9, 1.5, breath) * (1.0 + QC_LENS_CRISP * lensG);
  float t = clamp(0.5 + (q * 0.5) * sharp, 0.0, 1.0);
  vec3  accent = accentRamp(t);
  float node = pow(abs(q), 6.0);                              // bright antinode fringes

  // STEP 5 — THEME COMPOSITE (timing identical; only the math flips).
  vec3 col;
  if (uTheme < 0.5){
    // DARK: additive over ink + filmic knee; antinodes bloom toward a
    // palette-derived tint (accent2/3 pulled toward the bg complement).
    vec3 bloom = mix(mix(uAccent2, uAccent3, 0.5), vec3(1.0) - uBg, 0.4);
    col  = uBg;
    col += accent * (0.55 + 0.45 * breath) * uIntensity;
    col += bloom * node * 0.25 * uIntensity;
    col  = col / (col + vec3(0.6));                           // Reinhard knee
    col *= 1.15;
  } else {
    // LIGHT: pearl deposit; uIntensity (~0.78) already low — never blow out.
    float v = pow(t, 0.8);
    vec3 pearl = mix(uBg, accent, 0.85);
    col = mix(uBg, pearl, v * 0.6 * uIntensity);
    col = mix(col, uInk, smoothstep(0.2, 0.7, node) * 0.05 * uIntensity); // ink contour
  }

  // STEP 6 — POINTER HALO (match aurora/mesh idiom; breath-gated).
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float halo = exp(-dot(p - pp, p - pp) * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.2 * breath
         * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // STEP 7 — VIGNETTE (protect glass-type legibility over the field).
  float vig = smoothstep(1.6, 0.2, length(p));
  col = mix(uBg, col, 0.4 + 0.6 * vig);
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}