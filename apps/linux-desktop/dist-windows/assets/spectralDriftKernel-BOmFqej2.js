import{c as e}from"./createShaderKernel-DNT32VLs.js";import"./index-PmASUbTN.js";const t=`
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
        float weight = hb * 2.0 - 1.0;             // signed amplitude
        acc += weight * win * cos(phase);
        wsum += win;
      }
    }
  }
  float n = clamp((acc / max(wsum, 1e-3)) * 1.3, -1.0, 1.0);

  // ── Palette mapping (theme-branched) ──
  vec3 ramp = accentRamp(n * 0.5 + 0.5);
  // DARK: ribbons emerge from the deep ink bg, brightest at the crests/troughs.
  vec3 darkCol = mix(uBg, ramp, 0.55 + 0.35 * abs(n));
  // LIGHT: the same grain deposited as soft pigment on the warm paper bg.
  vec3 lightCol = mix(uBg, mix(ramp, uInk, 0.18), 0.42 + 0.4 * abs(n));
  vec3 col = (uTheme < 0.5) ? darkCol : lightCol;

  // ── Thin zero-crossing ink seam between ribbons ──
  float band = smoothstep(0.045, 0.0, abs(n));
  col = mix(col, uInk, band * 0.22 * uIntensity);

  col *= uIntensity;

  // ── Vignette (keeps foreground text legible) ──
  float vig = smoothstep(1.15, 0.25, length(uv - 0.5) * 1.4);
  col *= mix(0.58, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;function i(){return e({id:"spectral-drift",label:"Spectral Drift",body:t})}export{i as createSpectralDriftKernel};
