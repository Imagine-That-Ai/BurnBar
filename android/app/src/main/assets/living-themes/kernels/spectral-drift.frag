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


// ── Spectral Drift — anisotropic Gabor (sparse-convolution) noise ─────────
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5);
  p.x *= aspect;

  // ── Gabor parameters (compile-time constants → unrollable loop) ──
  const float FREQ = 9.0;   // carrier frequency of each impulse
  const float BW   = 5.0;   // Gaussian window bandwidth (larger ⇒ tighter)
  const float SCALE = 4.0;  // cells across the (aspect-corrected) field
  const int   IMP  = 2;     // impulses per grid cell
  // cos/sin of the fixed comb offset (0.5 rad) between the two carrier sets.
  const vec2  ROT  = vec2(0.87758256, 0.47942554);

  float t = uTime * 0.15;

  // ── Drifting dominant orientation; bends near an active pointer ──
  float gAng = t * 0.6 + 1.2;
  if (uPointerActive > 0.5) {
    vec2 ptr = (uPointer - 0.5);
    ptr.x *= aspect;
    vec2 pd = p - ptr;
    gAng += atan(pd.y, pd.x) * 0.5 * exp(-3.5 * dot(pd, pd));
  }

  // ── Sparse Gabor convolution over a 3×3 cell neighborhood ──
  vec2 g = p * SCALE;
  vec2 cellId = floor(g);
  vec2 f = fract(g);
  float acc = 0.0;
  float wsum = 0.0;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 cId = cellId + vec2(float(i), float(j));
      for (int k = 0; k < IMP; k++) {
        vec3 hid = vec3(cId, float(k));
        float ha = fract(sin(dot(hid, vec3(127.1, 311.7, 74.7))) * 43758.5453);
        float hb = fract(sin(dot(hid, vec3(269.5, 183.3, 246.1))) * 23421.6310);
        float hc = fract(sin(dot(hid, vec3(113.5, 271.9, 124.6))) * 14375.5964);
        vec2 d = (vec2(float(i), float(j)) + vec2(ha, hb)) - f;
        float r2 = dot(d, d);
        float win = exp(-BW * r2);                 // Gaussian envelope
        float ang = gAng + (hc - 0.5) * 2.5;       // per-impulse orientation jitter
        vec2 dir = vec2(cos(ang), sin(ang));
        float phase = 6.2831853 * FREQ * dot(d, dir) + t * 4.0 * (ha - 0.5);
        // Second half-amplitude carrier at a fixed comb rotation — same
        // envelope, decorrelated phase. Fills the gaps between streaks so the
        // grain reads fully brushed; dir2 is a constant-angle rotation of dir
        // (no extra sin/cos), so the only added cost is one cos per impulse.
        vec2 dir2 = vec2(dir.x * ROT.x - dir.y * ROT.y,
                         dir.x * ROT.y + dir.y * ROT.x);
        float phase2 = 6.2831853 * FREQ * dot(d, dir2)
                     + t * 4.0 * (hc - 0.5) + 2.399963;
        float weight = hb * 2.0 - 1.0;             // signed amplitude
        acc += weight * win * (cos(phase) + cos(phase2)) * 0.5;
        wsum += win;
      }
    }
  }
  // Gain 1.8 (was 1.3): the two half-amplitude carriers sum with RMS ~1/sqrt(2)
  // of a single full-amplitude cosine, so compensate to keep field contrast.
  float n = clamp((acc / max(wsum, 1e-3)) * 1.8, -1.0, 1.0);

  // ── Palette mapping (theme-branched) ──
  vec3 ramp = accentRamp(n * 0.5 + 0.5);
  // DARK: ribbons emerge from the deep ink bg, brightest at the crests/troughs.
  vec3 darkCol = mix(uBg, ramp, 0.55 + 0.35 * abs(n));
  // LIGHT: the same grain deposited as soft pigment on the warm paper bg.
  vec3 lightCol = mix(uBg, mix(ramp, uInk, 0.18), 0.42 + 0.4 * abs(n));
  vec3 col = (uTheme < 0.5) ? darkCol : lightCol;

  // ── Thin zero-crossing ink seam between ribbons ──
  // Deeper + slightly wider on the light theme so the signature seam stays
  // legible against the pearl background (0.22 on dark is already enough).
  float bandW = (uTheme < 0.5) ? 0.045 : 0.06;
  float seamAmp = (uTheme < 0.5) ? 0.22 : 0.42;
  float band = smoothstep(bandW, 0.0, abs(n));
  col = mix(col, uInk, band * seamAmp * uIntensity);

  col *= uIntensity;

  // ── Vignette (keeps foreground text legible) ──
  float vig = smoothstep(1.15, 0.25, length(uv - 0.5) * 1.4);
  col *= mix(0.58, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}