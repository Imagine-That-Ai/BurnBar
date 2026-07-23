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
uniform vec2  uScroll;
uniform float uScrollVel;



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


// ── iridescence — tuning constants (mirror iridescence/math.ts) ──
const float N1          = 1.0;      // air IOR
const float N2          = 1.3;      // thin-film IOR (oil/soap-like)
const float N3          = 1.5;      // substrate IOR (glass)
const float R01         = -0.1304;  // (N1-N2)/(N1+N2)  amplitude Fresnel air->film
const float R12         = -0.0714;  // (N2-N3)/(N2+N3)  amplitude Fresnel film->glass
const float C0_FILM     = 0.0221;   // R01*R01 + R12*R12  (angle-independent offset)
const float C1_FILM     = 0.0186;   // 2.0*R01*R12        (interference amplitude; both neg => +)
const float PHASE_R     = 0.02404;  // 4*pi*N2/lambdaR  (rad/nm), lambdaR = 680 nm
const float PHASE_G     = 0.02972;  // 4*pi*N2/lambdaG,          lambdaG = 550 nm
const float PHASE_B     = 0.03713;  // 4*pi*N2/lambdaB,          lambdaB = 440 nm  (blue accrues phase fastest => dispersion)
const float THICK_BASE  = 320.0;    // nm — resting thickness (mid color order)
const float THICK_AMP   = 220.0;    // nm — thickness-field swing (~2.6 color orders)
const float THICK_BREATH= 50.0;     // nm — breath sweeps this => sheet breathes through color PHASES
                                    //      (re-tuned for the live reactive clock: 90 was authored
                                    //      against the frozen uTime=0 bug and cycled a full fringe
                                    //      every ~4s once live; 50 keeps the sweep slow-liquid)
const float THICK_SCROLL= 160.0;    // nm — scroll sweeps color orders (descent)
const float THICK_PTR   = 140.0;    // nm — local cursor bump => color swirl under pointer
const float GRAD_GAIN   = 2.4;      // thickness-gradient -> pseudo-normal slope (view-angle gain)
const float FILM_GAIN   = 11.0;     // reflectance->luminance scale (raw R ~ 0.02-0.04)
const float WARP_AMP    = 0.35;     // domain-warp strength (one-body flow)
const float TWO_PI      = 6.28318531;

// Two-beam (m=0,1) Airy reflectance for one channel — the PRODUCTION form.
// Numerator (C0 + C1*cos d) / denominator (1 + R01*R01*R12*R12 + C1*cos d): the
// exact boxed Airy reflectance, no truncation past the m=0,1 series. The +1e-5
// is a numerical zero-guard. The denominator's extra terms beyond the numerator
// are O(R01*R01*R12*R12) ~ 9e-5, so a maintainer may drop it in one line to the
// cheapest variant 'return C0_FILM + C1_FILM*cos(phase);' (denominator ~ 1) if
// needed — there is NO runtime toggle; the shipped code is this denominator form.
float thinFilmReflectance(float phase){
  float c = cos(phase);
  return (C0_FILM + C1_FILM * c)
       / (1.0 + R01*R01*R12*R12 + C1_FILM * c + 1.0000001e-5);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // STEP 1 — CLOCKS (shared family breath: 14s/31s irrational lung; cf. moire/flow).
  float breath = 0.5 + 0.5 * (0.62 * sin(TWO_PI * uTime / 14.0)
                            + 0.38 * sin(TWO_PI * uTime / 31.0 + 1.3));
  float drift  = uTime * 0.03;             // slow field evolution (0.05 was authored
                                           // against the dead reactive clock; live it crawled)

  // STEP 2 — THICKNESS FIELD (domain-warped FBM; one-body flow like mesh/aurora).
  vec2 warp = WARP_AMP * vec2(fbm(vec3(p * 0.8, drift)),
                              fbm(vec3(p * 0.8 + 5.2, drift)));
  vec2 pw   = p + warp;
  float field = fbm(vec3(pw * 1.4, drift * 0.6));     // ~[-1,1]
  float d = THICK_BASE + THICK_AMP * (field * 0.5 + 0.5);

  // STEP 3 — REACTIVE THICKNESS MODULATION.
  d += (breath * 2.0 - 1.0) * THICK_BREATH;            // breath => color phases
  float scrollN = (uScroll.y > 0.5) ? clamp(uScroll.x / uScroll.y, 0.0, 1.0) : 0.0;
  d += (scrollN * 2.0 - 1.0) * THICK_SCROLL;           // opt-in descent through orders
  vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y; // pointer in p-space
  if (uPointerActive > 0.5){
    d += smoothstep(0.40, 0.0, distance(pw, pp)) * THICK_PTR; // cursor => local color swirl
  }

  // STEP 4 — FAKED VIEW-ANGLE from the thickness gradient (honest goniochromism).
  // A real N·V has no meaning on a flat backdrop; the gradient IS the surface
  // tilt, and d depends on cos(theta_t) — so folds/ridges genuinely shift the band.
  vec2  g    = vec2(dFdx(d), dFdy(d));
  vec3  nrm  = normalize(vec3(g * GRAD_GAIN, 1.0));
  float cosI = clamp(nrm.z, 0.0, 1.0);
  float sinT2 = (N1 / N2) * (N1 / N2) * (1.0 - cosI * cosI);
  float cosT = sqrt(clamp(1.0 - sinT2, 0.0, 1.0));    // Snell internal angle

  // STEP 5 — PER-CHANNEL AIRY REFLECTANCE at the three anchor wavelengths.
  float Rr = thinFilmReflectance(PHASE_R * d * cosT);
  float Rg = thinFilmReflectance(PHASE_G * d * cosT);
  float Rb = thinFilmReflectance(PHASE_B * d * cosT);

  // STEP 6 — PHYSICS WEIGHTS THE PALETTE ACCENTS (iris/cyan/violet by R/G/B).
  // Color is the interference; the palette only tints the channels => family identity.
  vec3 film = (Rr * uAccent0 + Rg * uAccent1 + Rb * uAccent2) * FILM_GAIN;

  // STEP 7 — THEME COMPOSITE (timing identical; only the math flips).
  vec3 col;
  if (uTheme < 0.5){
    // DARK: additive luminous film over deep ink + filmic knee; bands bloom.
    col  = uBg;
    col += film * (0.8 + 0.4 * breath) * uIntensity;
    col  = col / (col + vec3(0.6)) * 1.16;             // Reinhard knee
  } else {
    // LIGHT: subtractive interference glaze — the film is deposited as INK over
    // pearl, multiplying uBg DOWN toward the interference hue (never toward
    // white; the old additive watermark collapsed to a faint unit-hue wash).
    // glaze <= 1 per channel, so col <= uBg always; depth folds uIntensity and
    // breathes with the shared lung like the dark branch's luminous gain.
    float peak  = max(max(film.r, film.g), film.b);
    vec3  tint  = film / (peak + 1e-4);                // unit-hue interference
    float v     = clamp(peak, 0.0, 1.0);
    float depth = v * (0.55 + 0.20 * breath) * uIntensity;
    vec3  glaze = mix(vec3(1.0), tint * 0.72, depth);  // saturated sub-white deposit
    col = uBg * glaze;
    col = mix(col, uInk, smoothstep(0.20, 0.70, v) * 0.08 * uIntensity); // ink contour
  }

  // STEP 8 — POINTER HALO (match aurora/mesh/moire idiom; breath-gated).
  if (uPointerActive > 0.5){
    float halo = exp(-dot(p - pp, p - pp) * 3.5);
    // 0.05 => 20s hue lap (0.10 was dead-clock-era; live it laps too fast).
    col += accentRamp(fract(0.55 + uTime * 0.05)) * halo * 0.2 * breath
         * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // STEP 9 — VIGNETTE (protect glass-type legibility) + never-black bias to uBg.
  float vig = smoothstep(1.6, 0.2, length(p));
  col = mix(uBg, col, 0.45 + 0.55 * vig);
  return col;   // MAIN() adds dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}