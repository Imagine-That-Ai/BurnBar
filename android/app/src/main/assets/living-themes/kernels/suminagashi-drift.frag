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


// ── Suminagashi Drift — closed-form ink-on-water marbling ─────────────────

// Tine falloff pow(u, |d|) with a smoothstep knee: the raw absolute value has
// a derivative kink at d = 0, printing a hard crease along every comb line.
// Blending onto a parabolic cap (value- and slope-matched at d = k) keeps the
// Lu/Jaffer/Witkin exponential tail while rounding the crest into a soft fold.
float tineFalloff(float u, float sd) {
  float d = abs(sd);
  const float k = 0.15;                    // knee half-width
  float cap = 0.5 * (k + d * d / k);       // parabolic cap, C1 at d = k
  d = mix(cap, d, smoothstep(0.0, k, d));
  return pow(u, d);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float asp = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(asp, 1.0);
  vec2 ptr = (uPointer - 0.5) * vec2(asp, 1.0);
  float t = uTime * 0.18;

  // Closed-form rake strengths (Lu/Jaffer/Witkin): z = stroke amplitude,
  // u = tine falloff base in (0,1) so pow(u, dist) decays away from the line.
  float z = 0.34;
  float u = 0.62;
  vec2 q = p;

  // ── Crossed comb strokes (horizontal + vertical tine lines), drifting ──
  { float xL = 0.42 * sin(t * 1.3); q.y -= z * tineFalloff(u, q.x - xL); }
  { float yL = 0.40 * sin(t * 0.9 + 1.7); q.x -= (z * 0.85) * tineFalloff(u, q.y - yL); }

  // ── Slow vortex (rotational rake about a drifting center) ──
  {
    vec2 C = vec2(0.18 * sin(t * 0.7), 0.16 * cos(t * 0.6));
    vec2 rp = q - C;
    float h = length(rp);
    float r0 = 0.10;
    float l = (z * 1.4) * pow(u, abs(h - r0));
    float a = -(l / max(h, 1e-3));
    float ca = cos(a), sa = sin(a);
    q = C + vec2(ca * rp.x - sa * rp.y, sa * rp.x + ca * rp.y);
  }

  // ── Pointer rake — a live comb stroke under the cursor ──
  { float d = abs(q.x - ptr.x); q.y -= (z * uPointerActive) * pow(u, d); }

  // ── Concentric ink drops, applied back-to-front (inverse drop map) ──
  // Each drop claims a fractional coverage weight over a thin rim band instead
  // of a hard membership test, so the band index and vein radius interpolate
  // continuously across drop boundaries — no hard seam where drop edges meet.
  const int NDROP = 5;
  const float RIM = 0.035;               // rim half-width for the band blend
  float covered = 0.0;
  float tone = 0.0;
  float vein = 0.0;
  for (int i = NDROP - 1; i >= 0; i--) {
    float fi = float(i);
    vec2 C = 0.46 * vec2(sin(fi * 2.39 + t * 0.5), cos(fi * 1.71 - t * 0.4));
    float r = 0.16 + 0.05 * sin(fi * 1.7 + t);
    vec2 d2 = q - C;
    float dd = length(d2);
    float w = smoothstep(r, r - RIM, dd) * (1.0 - covered);
    tone += w * fract(fi * 0.27 + 0.12); // fractional band index for this drop
    vein += w * (dd / r);                // normalized radius within the drop
    covered += w;
    float s = sqrt(max(1.0 - (r * r) / max(dd * dd, 1e-6), 0.0));
    q = mix(C + d2 * s, q, w);           // pull back only the uncovered share
  }
  {                                      // outside every drop → background band
    // Accumulate the UNWRAPPED band phase: a fract() here wraps 1 -> 0, and
    // scaled by the partial rim weight (1 - covered) that integer jump becomes
    // a non-integer tone snap — a hard seam crawling through the rim blend.
    // Every downstream consumer is 1-periodic in tone (rings via tone * 2pi,
    // marble via fract), so the unwrapped value is exactly equivalent outside
    // the rims and seam-free inside them.
    float rr = length(q);
    tone += (1.0 - covered) * (rr * 1.6 - t * 0.05);
    vein += (1.0 - covered) * rr;
  }

  // ── Marble veins + paper grain ──
  // The lung: ring frequency eases by ~1.5% on a long slow breath, so the
  // rings dilate almost imperceptibly — the ink breathing on the water.
  float lung = sin(uTime * 0.42);
  float rings = 0.5 + 0.5 * sin((40.0 - 0.6 * lung) * vein + tone * 6.2831 - t);
  float grain = fbm(vec3(q * 3.0 + tone, 0.0)) * 0.12;
  vec3 marble = accentRamp(fract(tone + 0.15 * rings + grain));

  // ── Theme composite ──
  // DARK: luminous ink marble floated over deep water; vein crests pick out uInk.
  vec3 darkInk = mix(uBg, marble, 0.82);
  darkInk = mix(darkInk, uInk, smoothstep(0.85, 0.98, rings) * 0.35);
  darkInk *= uIntensity;
  // LIGHT: ink deposited on warm paper; stains toward uInk so it never blows out.
  vec3 paperInk = mix(uBg, mix(marble, uInk, 0.5), 0.5 + 0.5 * uIntensity);
  paperInk = mix(paperInk, uInk, smoothstep(0.82, 0.99, rings) * 0.22);

  vec3 col = (uTheme < 0.5) ? darkInk : paperInk;

  // ── Vignette (keeps foreground text legible) ──
  float vig = smoothstep(1.15, 0.25, length(p));
  col *= mix(0.6, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}