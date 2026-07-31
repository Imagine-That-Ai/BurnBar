import{c as e}from"./createShaderKernel-DNT32VLs.js";import{Q as t,a as o,b as a}from"./quasicrystalWaves-BD0dAad5.js";import"./index-PmASUbTN.js";const i=`
// ── moiré quasicrystal — tuning constants (mirror quasicrystalWaves.ts) ────
const int   QC_WAVES_C   = ${t};
const float QC_GOLDEN_C  = ${o.toFixed(10)};
const float QC_FREQ_C    = ${a.toFixed(1)};
const float QC_SPIN      = 0.012;     // basis-rotation clock (authentic QC anim)
const float QC_SCRUB     = 0.05;      // global phase-drift clock
const float QC_LENS_TIGHT = 9.0;      // pointer-lens gaussian tightness
const float QC_LENS_STR   = 0.18;     // pointer-lens warp strength
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

  // STEP 2 — POINTER LENS (domain warp). fwidth() on the FINAL phase tracks this
  // warp's frequency change automatically — the reason analytic AA survives warps.
  vec2 pw = p;
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    vec2 d  = p - pp;
    float r2 = dot(d, d);
    float g  = exp(-r2 * QC_LENS_TIGHT);              // ripple bubble at cursor
    pw += normalize(d + 1e-4) * g * QC_LENS_STR;
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

  // STEP 4 — TONE SHAPING. Inhale crisps the interference nodes.
  float sharp = mix(0.9, 1.5, breath);
  float t = clamp(0.5 + (q * 0.5) * sharp, 0.0, 1.0);
  vec3  accent = accentRamp(t);
  float node = pow(abs(q), 6.0);                              // bright antinode fringes

  // STEP 5 — THEME COMPOSITE (timing identical; only the math flips).
  vec3 col;
  if (uTheme < 0.5){
    // DARK: additive over ink + filmic knee; antinodes bloom toward white.
    col  = uBg;
    col += accent * (0.55 + 0.45 * breath) * uIntensity;
    col += vec3(0.80, 0.85, 1.0) * node * 0.25 * uIntensity;
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
`;function r(){return e({id:"moire",label:"Moiré",body:i})}export{r as createMoireKernel};
