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


// ── Ink Diffusion — capillary chromatography bleed into wet fibre ──────────
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float asp = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(asp, 1.0);
  vec2 ptr = (uPointer - 0.5) * vec2(asp, 1.0);
  float t = uTime;

  // Paper-fibre feather field — a fine fbm that ragged-wicks every ink front and
  // also lays a faint laid-paper grain under the wash. These are the ONLY two
  // fbm taps per pixel — drop motion below is pure per-drop trig.
  float fibre = fbm(vec3(p * 5.5, t * 0.03));
  float grain = fbm(vec3(p * 22.0, 7.0)) * 0.5 + 0.5;
  float feather = (fibre - 0.5) * 0.09;

  // Accumulators: pooled ink (additive saturation — layered washes) + a soft-max
  // UNION of signed front penetration, so touching bleeds share ONE continuous
  // advancing rim instead of N concentric ones.
  float ink = 0.0;
  float wet = -4.0;              // union penetration, in units of front softness
  const float UK = 0.7;          // smooth-max knee (soft-widths) — front merge range

  // ── N drifting ink drops, each a breathing capillary diffusion front ──
  // Two interleaved scales: broad primary bleeds + finer secondary micro-bleeds,
  // so the field reads as a continuous oil-on-paper wash, not discrete blobs.
  const int NDROP = 9;
  for (int i = 0; i < NDROP; i++) {
    float fi = float(i);
    bool micro = (i >= 5);                  // the last 4 are small micro-bleeds
    // slow lissajous orbit of the drop centre (the damp sheet creeping): a base
    // circuit plus an incommensurate second harmonic — same wander the old
    // per-pixel fbm drift gave, at zero noise cost.
    float spread = micro ? 0.5 : 0.4;
    vec2 c = spread * vec2(sin(fi * 2.39 + t * 0.05), cos(fi * 1.71 - t * 0.045));
    c += 0.06 * vec2(sin(fi * 7.31 + t * 0.113), cos(fi * 5.17 - t * 0.087));

    // boundary radius eases outward then holds + trembles — ink still spreading.
    float grow = 0.5 + 0.5 * sin(fi * 1.3 + t * 0.18);
    float baseR = micro ? 0.07 : 0.15;
    float R = baseR + (micro ? 0.05 : 0.12) * grow + 0.012 * sin(t * 0.9 + fi * 3.0);

    // feather the distance by the fibre field → a ragged wicking boundary.
    float r = length(p - c) + feather;

    float soft = (micro ? 0.06 : 0.10) + 0.05 * grow;
    float s = (R - r) / soft;               // signed penetration: 0 front, 1 wet

    // polynomial smooth-max union (no exp — range-safe): nearby fronts fuse.
    float h = max(UK - abs(wet - s), 0.0) / UK;
    wet = max(wet, s) + h * h * UK * 0.25;

    // pooled saturation stays additive so overlapping bleeds darken.
    ink += smoothstep(0.0, 1.0, s) * (0.6 + 0.4 * grain) * (micro ? 0.7 : 1.0);
  }

  // Pointer bloom — a fresh capillary wick from the cursor, joined into the same
  // union so it merges with whatever wash it lands on.
  {
    float s = (0.18 - (length(p - ptr) + (fibre - 0.5) * 0.07)) / 0.12;
    s = mix(-4.0, s, uPointerActive);
    float h = max(UK - abs(wet - s), 0.0) / UK;
    wet = max(wet, s) + h * h * UK * 0.25;
    ink += uPointerActive * smoothstep(0.0, 1.0, s);
  }

  // ONE advancing rim + chromatography, evaluated on the unioned front: a thin
  // pigment band piled just inside the shared wicking boundary.
  float edge = smoothstep(0.0, 0.45, wet) * (1.0 - smoothstep(0.5, 1.0, wet));
  // chromatographic separation: fast dye runs to the front (low sep), slow
  // pigment piles at the core (high sep) → hue indexes the ramp. Widened span
  // (×1.15) so the spectral separation reads; fibre modulation keeps the hue
  // varying across the sheet the way the per-drop offsets used to.
  float sep = clamp(wet * 0.5, 0.0, 1.0);
  float sat = clamp(ink, 0.0, 1.0);
  float hueIdx = fract(sep * 1.15 + 0.35 * fibre + 0.05 * t);
  vec3 inkCol = accentRamp(hueIdx);

  vec3 col;
  if (uTheme < 0.5) {
    // DARK — luminous ink suspended in a dark wash; fronts glow additively.
    vec3 wash = uBg + uBg * 0.4 * (grain - 0.5);
    vec3 bleed = inkCol * (0.5 + 0.7 * sat);
    bleed = mix(bleed, uAccent2, 0.18 * sat);            // cool running front
    col = wash + bleed * sat * uIntensity;
    col -= edge * 0.22 * uIntensity;                     // rim darkening (pigment pile)
    col = max(col, 0.0);
  } else {
    // LIGHT — sumi ink staining warm paper; source-over, capped.
    vec3 paper = mix(uBg, uBg * 0.96, grain - 0.5);
    vec3 stain = mix(inkCol, uInk, 0.55);                // ink reads dark on paper
    col = mix(paper, stain, clamp(sat, 0.0, 0.9));
    col -= edge * 0.16;                                  // darker wicking rim
    col = max(col, uInk * 0.0);
  }

  // Vignette — keeps foreground text legible.
  float vig = smoothstep(1.16, 0.26, length(p));
  col *= mix(0.62, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}