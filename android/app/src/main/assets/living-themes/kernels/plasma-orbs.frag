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


#define ORB_COUNT 6

// Hash → unit range; used to give each orb its own quiet per-instance phase.
float orbHash(float n){ return fract(sin(n) * 43758.5453123); }

// 2D analytic "field" at point p for a single orb centred at c, radius r,
// softness s (s controls the inverse-square falloff — larger s = softer edge).
// Returns a NON-NEGATIVE density; callers sum/integrate.
float orbField(vec2 p, vec2 c, float r, float s){
  vec2 d = p - c;
  float dd = dot(d, d);
  // Smooth-stepped inverse-square (avoids the 1/dd singularity at d=0).
  float k = max(r * r - dd, 0.0) / max(s * s, 1e-4);
  return k * k; // squared falloff → glassy round silhouettes
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  // Aspect-correct centred coords (y up). p is in [-aspect/2 .. +aspect/2] × [-0.5..0.5].
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // ── Time clocks (multi-frequency so the loop never visibly repeats) ──
  float t    = uTime * 0.18;     // orbit
  float tHue = uTime * 0.07;     // hue roll
  float tLow = uTime * 0.045;    // slow drift of the orbs' collective centre

  // ── Pointer warp (subtle; the host already smoothed uPointer 8%/frame) ──
  vec2 cursor = vec2(0.0);
  if (uPointerActive > 0.5) {
    cursor = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
  }

  // ── Field noise warp (a single shared fbm — cheap, the "liquid" feel) ──
  vec2 warp = vec2(
    fbm(vec3(p * 0.9,        tLow)),
    fbm(vec3(p * 0.9 + 5.2,  tLow))
  );
  vec2 pw = p + 0.18 * warp;

  // ── Build the orb cluster ──
  // Each orb orbits a slowly-drifting collective centre with its own radius,
  // phase, and softness, so silhouettes never perfectly align and never collide.
  vec2 centre = 0.10 * vec2(sin(tLow * 1.7), cos(tLow * 1.3));
  float density = 0.0;
  vec3 weightedHue = vec3(0.0); // sum of (hue · weight) for chromatic rim
  float weightSum = 0.0;

  // Dispersed density fields: the R and B channels see the orb field sampled at
  // positions shifted radially in/out of each orb, so the silhouette genuinely
  // fringes in space (true chromatic aberration, not a tinted density offset).
  float densityR = 0.0;
  float densityB = 0.0;

  // Per-orb "rim" accumulator (sharpness = largest local density gradient
  // magnitude → used to weight the chromatic-aberration rim later).
  float rimAccum = 0.0;

  for (int i = 0; i < ORB_COUNT; i++) {
    float fi = float(i);
    float ph = orbHash(fi * 1.3) * 6.2831853;
    float sp = 0.32 + 0.18 * orbHash(fi * 2.1 + 0.7);     // orbital speed
    float rad = 0.13 + 0.10 * orbHash(fi * 3.7 + 1.9);    // base radius
    float soft = 0.18 + 0.10 * orbHash(fi * 5.3 + 4.1);   // softness
    float orbitR = 0.30 + 0.22 * orbHash(fi * 7.1 + 2.3);  // orbit radius
    vec2  c = centre + orbitR * vec2(cos(t * sp + ph), sin(t * sp * 0.83 + ph));

    // Cursor gravitate (very small so orbs never dart across the screen).
    if (uPointerActive > 0.5) {
      c += 0.04 * (cursor - c) * (1.0 - orbHash(fi * 11.0 + 3.0));
    }

    // Per-orb breathing radius (slow inhale).
    float breathe = 1.0 + 0.10 * sin(uTime * (0.6 + 0.2 * fi) + ph);
    float r = rad * breathe;
    float s = soft * breathe;

    float w = orbField(pw, c, r, s);
    density += w;

    // Each orb carries a per-instance hue offset so the rim is multicoloured.
    float hueT = fract(tHue + 0.18 * fi + 0.07 * orbHash(fi * 9.7 + 6.1));
    weightedHue += accentRamp(hueT) * w;
    weightSum += w;

    // Dispersion taps (repurposed gradient taps — still 3 field evals per orb):
    // shift the SAMPLE POINT radially toward / away from this orb's centre so
    // red reads a slightly larger silhouette and blue a slightly smaller one.
    float eps = 0.006;
    vec2 dir = (pw - c) / max(length(pw - c), 1e-4);
    float wIn  = orbField(pw - dir * eps, c, r, s); // toward centre → denser
    float wOut = orbField(pw + dir * eps, c, r, s); // away → thinner
    densityR += wIn;
    densityB += wOut;
    // The same taps double as the gradient magnitude for rim weighting.
    rimAccum += abs(wIn - wOut) * (1.0 / (eps * 2.0));
  }

  // ── Density → palette ramp → final colour ──
  // Normalise weighted hue by total weight; use the density to interpolate
  // between the theme background and the iridescent rim colour.
  vec3 orbHue = weightSum > 1e-4 ? weightedHue / weightSum : accentRamp(0.5);

  // Soft "core vs halo" split: small density → background, large → orb body.
  float core = smoothstep(0.05, 0.55, density);
  float halo = smoothstep(0.0, 0.08, density) * (1.0 - core);

  // Iridescent oil-slick bias: phase = density + time → rainbow rim. Each RGB
  // channel phases off ITS OWN dispersed density field, so the slick ramp
  // fringes spatially across the silhouette instead of tinting in place.
  float phaseBase = tHue * 1.3 + length(warp) * 0.5;
  vec3 slick = vec3(
    accentRamp(fract(densityR * 1.4 + phaseBase + 0.10)).r,
    accentRamp(fract(density  * 1.4 + phaseBase + 0.34)).g,
    accentRamp(fract(densityB * 1.4 + phaseBase + 0.62)).b
  );

  // ── Chromatic-aberration rim: the R/G/B silhouettes come from the three
  //     spatially-offset density fields accumulated in the loop — a genuine
  //     dispersion fringe, widest where the gradient (rimAccum) is steep.
  vec3 caRgb = vec3(
    smoothstep(0.05, 0.55, densityR),
    smoothstep(0.05, 0.55, density),
    smoothstep(0.05, 0.55, densityB)
  );

  // ── Theme composite ──
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: orbs bloom over deep ink; filmic knee keeps the cores from
    // burning to flat white, while CA keeps the rim glassy.
    col = uBg;
    col += orbHue * core * 0.55 * uIntensity;
    col += slick   * halo * 0.40 * uIntensity;
    col += caRgb   * (rimAccum * 0.05) * uIntensity;
    col  = col / (col + vec3(0.50));
    col *= 1.18;
    // Soft airglow floor (prevents "dead black" between orbs) — a cool tint
    // derived from the theme background + the palette's blue end, so it stays
    // palette-true instead of hard-coding a navy constant.
    vec3 airglow = uBg * 0.9 + accentRamp(0.62) * 0.07;
    col += airglow * (1.0 - core) * 0.4;
  } else {
    // LIGHT: pearly watercolour orbs on pearl paper — never muddy.
    col = uBg;
    vec3 paper = mix(col, orbHue, 0.55 * core * uIntensity);
    paper = mix(paper, slick, halo * 0.45 * uIntensity);
    col = mix(col, paper, 1.0);
    // A whisper of ink gives the rim a soft contour.
    col = mix(col, uInk, halo * 0.06 * uIntensity);
  }

  // ── Pointer wash: subtle warm halo behind the cursor ──
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo2 = exp(-dd * dd * 4.5);
    col += accentRamp(fract(0.65 + uTime * 0.08)) * halo2 * 0.18 * (uTheme < 0.5 ? 1.0 : 0.55);
  }

  // ── Vignette (protects text legibility over the field) ──
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);

  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}