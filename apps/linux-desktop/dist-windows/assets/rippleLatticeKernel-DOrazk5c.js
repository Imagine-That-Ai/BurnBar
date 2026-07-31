import{c as e}from"./createShaderKernel-DNT32VLs.js";import"./index-PmASUbTN.js";const t=`
// ── Ripple Lattice — breathing accent-dot lattice + cursor sonar ripples ──
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 res = uResolution;
  vec2 p = fragCoord;

  // Lattice cell size, clamped so dots stay readable across resolutions.
  float cell = clamp(res.y / 28.0, 18.0, 64.0);

  // Pointer in y-up pixel space (uPointer is 0..1 y-up; fragCoord is y-up).
  vec2 ptr = uPointer * res;
  float d2p = distance(p, ptr) / max(res.y, 1.0);   // normalized pointer distance

  // Concentric sonar ripple + a soft proximity bulge, gated by uPointerActive.
  float phase  = d2p * 18.0 - uTime * 2.6;
  float ripple = sin(phase) * exp(-d2p * 3.2) * uPointerActive;
  float prox   = exp(-d2p * 2.2) * uPointerActive;

  // Radially shove the sampling space outward from the cursor (the "push").
  vec2 dir = normalize(p - ptr + vec2(1e-4));
  vec2 sp  = p + dir * ripple * cell * 0.6;

  // Slow traveling wave over the lattice (FBM keeps the breathing organic).
  float bgWave = fbm(vec3(sp / cell * 0.16, uTime * 0.14));
  vec2 gid = floor(sp / cell);
  vec2 cuv = fract(sp / cell) - 0.5;
  float wave = 0.5 + 0.5 * sin((gid.x + gid.y) * 0.55 - uTime * 1.4 + bgWave * 2.0);

  // Dot radius breathes with the wave, swells near the cursor + on ripple crests.
  float radius = mix(0.12, 0.32, wave) + prox * 0.20 + ripple * 0.12;
  radius = max(radius, 0.04);
  float dd = length(cuv);
  // Well-defined smoothstep (edge0 < edge1): 1 inside the dot, 0 outside.
  float dotMask = 1.0 - smoothstep(radius - 0.07, radius, dd);

  // Palette-driven dot color; brighter near the cursor.
  vec3 dotCol = accentRamp(wave * 0.65 + prox * 0.35 + 0.08);

  vec3 col = mix(uBg, mix(uBg, dotCol, 0.9), dotMask);
  // DARK: dots glow additively (bloom near the cursor / on ripple crests).
  col += dotCol * dotMask * (1.0 - uTheme) * (0.22 + prox * 0.55);
  // LIGHT: dots deposit ink onto the warm paper bg (never blows out).
  col = mix(col, mix(col, uInk, dotMask * 0.65), uTheme);
  // Faint accent wash riding the ripple crest (dark only).
  col += accentRamp(0.7) * max(ripple, 0.0) * 0.10 * (1.0 - uTheme);

  col *= uIntensity;

  // Vignette (well-defined form): 1 at center, fades toward the edges.
  float vig = 1.0 - smoothstep(0.32, 0.95, length(uv - 0.5));
  col = mix(uBg * mix(0.62, 1.0, uTheme), col, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;function i(){return e({id:"ripple-lattice",label:"Ripple Lattice",body:t})}export{i as createRippleLatticeKernel};
