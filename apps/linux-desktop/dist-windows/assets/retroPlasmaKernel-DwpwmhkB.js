import{c as e}from"./createShaderKernel-DNT32VLs.js";import"./index-PmASUbTN.js";const t=`
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

  // ── THE formula — four sines, that's it ────────────────────────────────
  // Future Crew's canonical plasma; wavenumbers are coprime so the iso-
  // contours never tile. Each term gets its own phase clock.
  float v = sin(p.x * 8.0 + t1)
          + sin(p.y * 7.0 + t2 * 1.07)
          + sin((p.x + p.y) * 5.0 + t3 * 0.91)
          + sin(sqrt(p.x * p.x + p.y * p.y) * 7.0 - t1 * 0.83);

  // Pointer warp (subtle; the host already smooths uPointer 8%/frame).
  if (uPointerActive > 0.5) {
    vec2 cursor = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float d = distance(p, cursor);
    v += 1.2 * exp(-d * d * 5.0) * sin(uTime * 0.5 + d * 12.0);
  }

  // ── IQ cosine palette (a + b·cos(2π(c·t + d))) — one line, full rainbow ──
  // The famous IQ "cheap procedural palette" (iquilezles.org/articles/palettes).
  // t is the normalised plasma value, plus a slow phase roll so the rainbow
  // never sits at one fixed hue.
  float t = (v + 4.0) * 0.125 + uTime * 0.018;
  vec3  a = vec3(0.50, 0.50, 0.50);
  vec3  b = vec3(0.50, 0.50, 0.50);
  vec3  c = vec3(1.00, 1.00, 0.50);  // R oscillates 1x, G 1x, B 0.5x → rainbow
  vec3  d2 = vec3(0.80, 0.90, 0.30); // per-channel phase offset
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
    col += vec3(0.05, 0.06, 0.10) * 0.4;  // airglow grain floor
  } else {
    // LIGHT: pearl deposit — the rainbow stays vivid because the palette
    // already lives in [0,1], but the brightness is mapped onto the warm
    // paper background instead of pure black. uIntensity ~ 0.78 here.
    float lum = clamp(dot(paletteCol, vec3(0.45)) * 1.6, 0.0, 1.0);
    vec3  pearl = mix(uBg, paletteCol, 0.80);
    col = mix(uBg, pearl, lum * 0.62 * uIntensity);
    col = mix(col, uInk, smoothstep(0.55, 0.95, lum) * 0.045 * uIntensity);
  }

  // ── Pointer halo (subtle; matches the family idiom) ────────────────────
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.18
         * (uTheme < 0.5 ? 1.0 : 0.55);
  }

  // ── Vignette (protects glass-type legibility over the ribbons) ─────────
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);

  return col;   // MAIN() adds dither() + clamps to [0,1]
}
`;function a(){return e({id:"retro-plasma",label:"Retro Plasma",body:t})}export{a as createRetroPlasmaKernel};
