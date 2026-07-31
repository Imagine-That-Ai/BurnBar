import{c as e}from"./createShaderKernel-DNT32VLs.js";import"./index-PmASUbTN.js";const o=`
// ── Inversion Lattice — 2D Apollonian / circle-inversion fractal ──────────
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 R = uResolution;
  vec2 p = (fragCoord - 0.5 * R) / R.y;

  // ── Living transform: slow rotation + breathing zoom + pointer parallax ──
  float tt = uTime * 0.08;
  float zoom = 1.18 + 0.16 * sin(uTime * 0.13);
  p *= zoom;
  float ca = cos(tt), sa = sin(tt);
  p = mat2(ca, -sa, sa, ca) * p;
  p += (uPointer - 0.5) * 0.12 * uPointerActive;

  // ── Circle-inversion fold loop (Apollonian nesting), fixed 8 steps ──
  float ir = 1.06 + 0.12 * sin(uTime * 0.2);   // inversion radius, breathing
  vec2 z = p;
  float scale = 1.0;
  float kAcc = 0.0;
  float trap = 1e9;
  const int STEPS = 8;
  for (int i = 0; i < STEPS; i++) {
    z = -1.0 + 2.0 * fract(0.5 * z + 0.5);     // fold into the unit cell
    float r2 = dot(z, z);
    float k = ir / (r2 + 1e-6);                 // circle inversion
    z *= k;
    scale *= k;
    kAcc += k;
    trap = min(trap, abs(r2 - 0.5));            // orbit trap (ring halo)
  }

  // ── Distance-estimator ring edge (fwidth-AA) + orbit-trap glow ──
  float sc = max(scale, 1e-6);                  // guard log()/division below
  float de = abs(z.y) / sc;
  float w = fwidth(de) + 1e-4;
  float line = 1.0 - smoothstep(0.0, 2.6 * w, de);
  float glow = exp(-6.0 * trap);
  float shape = clamp(line + 0.55 * glow, 0.0, 1.0);

  // ── Palette hue from inversion scale + fold accumulation ──
  float fold = fract(0.06 * log(sc) + 0.16 * kAcc - 0.08 * uTime);
  vec3 ramp = accentRamp(fold);
  vec3 base = uBg;

  // ── Theme composite ──
  // DARK: luminous rings added over deep ink (the canonical look).
  vec3 lumRings = base + mix(uInk, ramp, 0.85) * shape * (0.6 + 0.8 * uIntensity);
  lumRings += ramp * 0.04 * (0.5 + 0.5 * sin(log(sc) * 1.5));   // faint scale shimmer
  // LIGHT: ink-deposit rings on the warm paper bg (never blows out).
  vec3 inkRings = mix(base, mix(ramp, uInk, 0.55), shape * (0.5 + 0.6 * uIntensity));

  vec3 col = (uTheme < 0.5) ? lumRings : inkRings;

  // ── Vignette (keeps foreground text legible) ──
  float vig = smoothstep(1.2, 0.35, length(uv - 0.5) * 1.4);
  col *= mix(0.82, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;function a(){return e({id:"inversion-lattice",label:"Inversion Lattice",body:o})}export{a as createInversionLatticeKernel};
