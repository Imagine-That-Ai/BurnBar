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


vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float t = uTime * 0.07;

  // STEP 0 — Breath conductor. One eased ~60s clock drives every layer so the
  // surface reads as a single organism; a delayed clock trails the color so the
  // light-breath swells ~5.7s after the color does.
  float bt = uTime * 0.105;
  float breath = 0.5 + 0.5 * sin(bt);
  breath = breath * breath * (3.0 - 2.0 * breath);  // eased dwell at extremes
  float sheen = 0.5 + 0.5 * sin(bt - 0.6);           // delayed light clock

  // STEP 1 — Domain warp the field ONCE (the "one body" move). Every later field
  // sample reads pw so the four blobs flow as one liquid.
  vec2 warp = 0.30 * vec2(fbm(vec3(p * 0.9, t)), fbm(vec3(p * 0.9 + 4.7, t)));
  vec2 pw = p + warp;

  // STEP 2 — Breathing, eased anchors (keep all 4, keep palette identity).
  // Per-anchor phase-warped clock for ease-in-out orbits; radius swells on inhale.
  float tw0 = t + 0.18 * sin(t * 0.37 + 0.0);
  float tw1 = t + 0.18 * sin(t * 0.37 + 1.7);
  float tw2 = t + 0.18 * sin(t * 0.37 + 3.4);
  float tw3 = t + 0.18 * sin(t * 0.37 + 5.1);
  float swell = 0.92 + 0.12 * breath;
  vec2 a0 = (0.62 * swell) * vec2(sin(tw0 * 0.7),       cos(tw0 * 0.5));
  vec2 a1 = (0.72 * swell) * vec2(sin(tw1 * 0.4 + 2.0), cos(tw1 * 0.6 + 1.0));
  vec2 a2 = (0.66 * swell) * vec2(cos(tw2 * 0.5 + 4.0), sin(tw2 * 0.45 + 3.0));
  vec2 a3 = (0.56 * swell) * vec2(cos(tw3 * 0.6 + 1.5), sin(tw3 * 0.7 + 5.0));

  // Inverse-square weights evaluated at domain-warped pw → flowing filaments.
  float w0 = 1.0 / (0.16 + dot(pw - a0, pw - a0));
  float w1 = 1.0 / (0.16 + dot(pw - a1, pw - a1));
  float w2 = 1.0 / (0.16 + dot(pw - a2, pw - a2));
  float w3 = 1.0 / (0.16 + dot(pw - a3, pw - a3));
  float wsum = w0 + w1 + w2 + w3;
  vec3 mesh = (w0 * uAccent0 + w1 * uAccent1 + w2 * uAccent2 + w3 * uAccent3) / wsum;

  // STEP 3 — Height/thickness field for normals + interference. The pointer
  // presses the laminate: a Gaussian bump in film thickness (aspect-corrected,
  // inertially smoothed upstream) so an iridescent bloom swims under the cursor
  // and the shared dFdx gradient picks up its rim + dispersion for free.
  float h = fbm(vec3(pw * 1.6, t * 0.5));
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 pp = (uPointer - 0.5) * vec2(aspect, 1.0);
  vec2 toPtr = p - pp;
  float press = uPointerActive * exp(-11.0 * dot(toPtr, toPtr));
  float filmThk = h * 0.7 + 0.15 * length(pw) + 0.45 * press;  // radial meniscus bias + press

  // STEP 4 — Thin-film iridescence: palette-routed, breath-coupled, dispersion
  // fringed. A single film gradient via core dFdx/dFdy is reused for dispersion
  // (here) and the Fresnel rim (STEP 7).
  vec2 n2 = vec2(dFdx(filmThk), dFdy(filmThk));
  float disp = 0.012 * (0.6 + 0.4 * uIntensity);
  float phase = filmThk * 1.5 + t * 0.15;
  vec3 iri = vec3(
    accentRamp(fract(phase + dot(n2, vec2(disp)))).r,
    accentRamp(fract(phase)).g,
    accentRamp(fract(phase - dot(n2, vec2(disp)))).b
  );
  mesh = mix(mesh, iri, 0.14 + 0.06 * breath);

  // STEP 5 — Parallax depth band (gives the slab thickness): ±4% luminance.
  float depth = fbm(vec3(pw * 0.7, t * 0.25));
  mesh *= mix(0.96, 1.04, depth * 0.5 + 0.5);

  // STEP 6 — Dual-clock ridged caustic isolated to ONE traveling seam (restraint).
  vec2 fa = vec2(cos(t * 0.20), sin(t * 0.20)) * 0.30;
  vec2 fb = vec2(cos(-t * 0.137), sin(-t * 0.137)) * 0.24;
  float c1 = fbm(vec3(pw * 2.2 + fa, t * 0.06));
  float c2 = fbm(vec3(pw * 3.5 - fb, t * 0.041));
  float caustic = c1 * c2;
  caustic = 1.0 - abs(2.0 * caustic - 1.0);  // thin ridge
  caustic = pow(caustic, 3.0);                // thin filaments
  // Gate to a single traveling iso-contour of the height field → one seam.
  // Steep gate edges (vs the old broad ramps) so the seam hits full strength
  // and its specular crest reads at a glance instead of dissolving into wash.
  float band = abs(h - 0.5) * 2.0;
  float seam = smoothstep(0.58, 0.68, band) * smoothstep(0.88, 0.78, band);
  caustic *= seam;

  // STEP 7 — Fresnel oil-sheen rim along folds (reuses the film gradient).
  float slope = length(n2);
  float rim = pow(clamp(slope * 3.0, 0.0, 1.0), 1.5);

  // STEP 8 — Theme composite. Base mesh UNCHANGED from the shipping kernel so the
  // legibility floor is preserved; all new light is ADDED on top and breath-gated.
  vec3 col;
  if (uTheme < 0.5) {
    col = mix(uBg, mesh, 0.24 + 0.5 * uIntensity);
  } else {
    // Keep the light treatment visibly rendered on small Lab cards; the old
    // 30% deposit was too close to pearl and read as an unpainted canvas.
    col = mix(uBg, mesh, 0.82 * uIntensity);
  }
  float causticGain = (0.14 + 0.20 * uIntensity)
    * (0.40 + 0.60 * sheen)
    * (uTheme < 0.5 ? 1.0 : 0.55);
  vec3 seamCol = accentRamp(0.7 + 0.15 * breath);
  col += seamCol * caustic * causticGain;
  // Specular crest — the signature cue. The hot core of the gated filaments is
  // lifted toward uInk (near-white in dark theme, near-black in light) so the
  // crest glints against the bg in BOTH themes while staying palette-derived.
  // max() guards the base: caustic goes negative in anti-ridge pockets (signed
  // fbm), and pow(negative, y) is GLSL-undefined; squaring it would also blow
  // past the clamp and speckle the seam band with full-strength ink flecks.
  float crest = pow(max(caustic, 0.0), 2.0) * (0.45 + 0.55 * sheen);
  col = mix(col, mix(seamCol, uInk, 0.55), clamp(crest * (0.30 + 0.35 * uIntensity), 0.0, 1.0));
  col += iri * rim * (uTheme < 0.5 ? 0.12 : 0.06);

  // STEP 9 — Pointer press glow: the film bump from STEP 3 swims the phase-
  // driven iridescence; this direct accent lift anchors the touch point (press
  // already carries the exp falloff shape — no rim coupling, which is O(1e-3)
  // for a screen-space gradient of a unit-scale field and reads as nothing).
  col += seamCol * press * (uTheme < 0.5 ? 0.20 : 0.12) * uIntensity;

  // STEP 10 — Breathing grain: grittier on exhale, silkier at peak inhale.
  // dither() is still applied by MAIN on top of this.
  float g = hash21(fragCoord + fract(uTime) * vec2(13.0, 7.0));
  col += (g - 0.5) * (0.016 + 0.010 * (1.0 - breath));
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}