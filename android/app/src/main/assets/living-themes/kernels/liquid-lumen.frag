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


// ── Liquid Lumen — fusing charges → a flowing lava-lamp color field ────────
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5); p.x *= aspect;

  // Pointer = finger heat on the lamp: every charge is pulled toward the
  // (smoothed) cursor with an exp falloff, so the nearest leans hardest and
  // the lava visibly tips toward the finger (liquidMetalField idiom).
  vec2 pp = (uPointer - 0.5) * vec2(aspect, 1.0);

  // ── Fixed charge cluster: each drifts on its own ellipse; densities sum ──
  const int N = 7;
  float field = 0.0; vec2 flow = vec2(0.0); float t = uTime * 0.27;
  for (int i = 0; i < N; i++){
    float fi = float(i);
    float sp = 0.6 + 0.35 * fract(sin(fi * 12.9898) * 43758.5453);
    float ph = fi * 2.39996;
    float rx = 0.34 + 0.12 * sin(fi * 1.7), ry = 0.30 + 0.13 * cos(fi * 2.3);
    vec2 c = vec2(
      rx * sin(t * sp + ph) + 0.08 * sin(t * 1.7 + fi),
      ry * cos(t * sp * 0.9 + ph * 1.3) + 0.07 * cos(t * 1.3 + fi)
    );
    vec2 dp = pp - c;
    c += dp * (uPointerActive * 0.6 * exp(-5.0 * dot(dp, dp)));
    // Each charge's field weight breathes over its orbit (normalized so the
    // mean field is unchanged): blobs melt into the halo and back, never pop.
    float w = (0.62 + 0.38 * sin(t * sp * 1.3 + ph * 2.0)) / 0.62;
    float rad = 0.030 + 0.018 * (0.5 + 0.5 * sin(fi * 3.1 + t));
    vec2 d = p - c; float g = w * rad / (dot(d, d) + 0.0008);
    field += g; flow += c * g;
  }
  flow /= max(field, 1e-4);                       // flow-weighted centroid

  // ── Smooth-union surface + thin fused edge band (wide knee: charges fade
  //    through halo → edge → surface instead of snapping across a threshold) ──
  float surf = smoothstep(0.70, 1.45, field);
  float edge = smoothstep(0.55, 0.85, field) - surf;

  // ── Palette band: surface mask + flow + a faint fbm wobble ──
  float rampT = 0.15 + 0.55 * surf + 0.30 * (flow.x * 0.5 + 0.5);
  rampT += 0.06 * fbm(vec3(p * 2.5, t));
  vec3 blob = accentRamp(clamp(rampT, 0.0, 1.0));

  bool light = uTheme > 0.5;
  vec3 col = uBg;
  col = mix(col, blob, surf);

  // ── Palette-derived lamp light: the lightest accent lifted toward the bg
  //    complement (inky in light theme, bright in dark) — no hardcoded white ──
  vec3 lw = vec3(0.299, 0.587, 0.114);
  vec3 lite = uAccent0; float ll = dot(uAccent0, lw);
  float l1 = dot(uAccent1, lw); lite = mix(lite, uAccent1, step(ll, l1)); ll = max(ll, l1);
  float l2 = dot(uAccent2, lw); lite = mix(lite, uAccent2, step(ll, l2)); ll = max(ll, l2);
  float l3 = dot(uAccent3, lw); lite = mix(lite, uAccent3, step(ll, l3));
  vec3 lamp = mix(lite, clamp(vec3(1.0) - uBg, 0.0, 1.0), 0.35);

  // ── Rim accent on the fused edge (lamp-lit in light, accent-lit in dark) ──
  vec3 rim = light ? mix(blob, lamp, 0.65) : (blob + uAccent2 * 0.6);
  col += rim * edge * (light ? 0.5 : 0.9);

  // ── Soft halo just outside the surface, and a single centroid hot spot ──
  float halo = smoothstep(0.25, 0.85, field) * (1.0 - surf);
  col += blob * halo * (light ? 0.12 : 0.28);
  float spec = exp(-6.0 * length(p - flow));
  col += (light ? lamp : uAccent3) * spec * 0.18 * surf;

  // ── Light-only ink deepening inside the surface; intensity gain ──
  col = mix(col, mix(col, uInk, 0.06), surf * (light ? 1.0 : 0.0));
  col *= mix(0.85, 1.25, uIntensity);

  // ── Vignette (protects text legibility over the field) ──
  float vig = smoothstep(1.15, 0.35, length((uv - 0.5) * vec2(aspect, 1.0)));
  col *= mix(light ? 0.92 : 0.78, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}