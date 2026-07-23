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


// ── Second-Reality-style plasma (Future Crew, 1993) ───────────────────────
// Four sine waves with coprime wavenumbers + per-channel phase clocks.
// Sum range is roughly [-4, +4]; we normalise to [0,1] for the palette.
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // ── Time clocks (multi-frequency so the loop never visibly repeats) ──
  // Master drift + slower horizontal sweep. The original 1993 prod used
  // a single t; we add a second clock so the screen never quite returns.
  float t1 = uTime * 0.62;
  float t2 = uTime * 0.31;
  float t3 = uTime * 0.83;

  // ── Pointer press — the cursor presses the glass ───────────────────────
  // A local domain compression (aspect-corrected exp falloff) pulls the
  // sample coords toward the finger, so the four-sine bands visibly bulge
  // and bend around it — a lens dimple, not a decal. Branchless: the host
  // already smooths uPointer 8%/frame, and uPointerActive gates strength.
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 pp = (uPointer - 0.5) * vec2(aspect, 1.0);
  vec2 toPtr = p - pp;
  float press = uPointerActive * exp(-7.0 * dot(toPtr, toPtr));
  vec2 q = p - 0.30 * press * toPtr;

  // ── THE formula — four sines, that's it ────────────────────────────────
  // Future Crew's canonical plasma; wavenumbers are coprime so the iso-
  // contours never tile. Each term gets its own phase clock. Evaluated on
  // the pressed domain q so the ribbons wrap the cursor.
  float v = sin(q.x * 8.0 + t1)
          + sin(q.y * 7.0 + t2 * 1.07)
          + sin((q.x + q.y) * 5.0 + t3 * 0.91)
          + sin(sqrt(q.x * q.x + q.y * q.y) * 7.0 - t1 * 0.83);

  // Slow phase breathing under the finger keeps the pressed bands alive.
  v += 0.9 * press * sin(uTime * 0.5 + length(toPtr) * 12.0);

  // ── IQ cosine palette (a + b·cos(2π(c·t + d))), FIT TO THE BRAND ────────
  // The famous IQ "cheap procedural palette" (iquilezles.org/articles/palettes),
  // but instead of the 1993 hardcoded rainbow the coefficients are derived
  // per-pixel (constant across the frame, a few ALU) from uBg/uAccent0-3:
  //   a  = bg-biased accent mean (the DC level the sweep orbits),
  //   b  = per-channel accent half-range, floored so the sweep never
  //        flattens when a palette's accents huddle together,
  //   d2 = phase fit so the cycle STARTS on uAccent0 and rolls toward
  //        uAccent1 (acos alone is sign-ambiguous; the step flips slope).
  // The four-sine field now cycles the brand ramp with the full spectral
  // sweep feel intact. t is the normalised plasma value plus a slow phase
  // roll so the palette never sits at one fixed hue.
  vec3  accMean = (uAccent0 + uAccent1 + uAccent2 + uAccent3) * 0.25;
  vec3  a = mix(accMean, uBg, 0.18);
  vec3  accLo = min(min(uAccent0, uAccent1), min(uAccent2, uAccent3));
  vec3  accHi = max(max(uAccent0, uAccent1), max(uAccent2, uAccent3));
  vec3  b = clamp((accHi - accLo) * 1.1, vec3(0.20), vec3(0.55));
  vec3  c = vec3(1.00, 1.00, 0.50);  // R,G oscillate 1x, B 0.5x — the 1993 sweep
  vec3  fit = clamp((uAccent0 - a) / b, -1.0, 1.0);
  vec3  d2 = acos(fit) * 0.15915494;              // acos/2π ∈ [0, 0.5]
  d2 = mix(d2, 1.0 - d2, step(uAccent0, uAccent1));
  float t = (v + 4.0) * 0.125 + uTime * 0.018;
  vec3  paletteCol = a + b * cos(6.28318531 * (c * t + d2));

  // ── Theme composite — original 1993 plasma was RGB-on-black, period. ────
  // We theme-key it so the family's light theme doesn't blow out, but the
  // PLASMA IS THE POINT: dark theme is the canonical look, light theme is a
  // pearl deposit that preserves the spectral interference (never muddied).
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: classic plasma on deep ink. Filmic knee keeps the brightest
    // ribbons from burning to flat white; faint airglow floor prevents dead
    // black in the troughs.
    col = uBg + paletteCol * (0.95 * uIntensity);
    col = col / (col + vec3(0.55));
    col *= 1.18;
    // Airglow grain floor, brand-derived: a uBg lift plus a faint accent-
    // mean tint (no invented hue), with a tiny scalar epsilon preserving
    // the never-black guarantee even on a pure-black palette.
    col += uBg * 0.35 + accMean * 0.05 + 0.008;
  } else {
    // LIGHT: pearl deposit — the rainbow stays vivid because the palette
    // already lives in [0,1], but the brightness is mapped onto the warm
    // paper background instead of pure black. uIntensity ~ 0.78 here.
    float lum = clamp(dot(paletteCol, vec3(0.45)) * 1.6, 0.0, 1.0);
    vec3  pearl = mix(uBg, paletteCol, 0.80);
    col = mix(uBg, pearl, lum * 0.62 * uIntensity);
    col = mix(col, uInk, smoothstep(0.55, 0.95, lum) * 0.045 * uIntensity);
  }

  // ── CRAFT CUE: CRT phosphor shimmer ─────────────────────────────────────
  // A rolling scanline gain (~3px period, slow raster crawl) plus a whisper
  // of frame gain breathing modulates ONLY the plasma's deviation from uBg —
  // palette-true (no new hue), never-black safe (the uBg floor is untouched),
  // and small enough that MAIN's triangular dither still kills any banding.
  float scanAmp = uTheme < 0.5 ? 0.06 : 0.025;
  float scan = 1.0 - scanAmp * (0.5 + 0.5 * sin(fragCoord.y * 2.094395 - uTime * 6.0));
  scan *= 1.0 + 0.008 * sin(uTime * 11.0);   // phosphor persistence flicker
  col = uBg + (col - uBg) * scan;

  // ── Pointer halo (subtle; matches the family idiom) ────────────────────
  if (uPointerActive > 0.5) {
    float dd = length(toPtr);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.18
         * (uTheme < 0.5 ? 1.0 : 0.55);
  }

  // ── Vignette (protects glass-type legibility over the ribbons) ─────────
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);

  return col;   // MAIN() adds dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}