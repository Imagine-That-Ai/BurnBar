import{c as e}from"./createShaderKernel-DNT32VLs.js";import"./index-PmASUbTN.js";const t=`
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

  // Per-orb "rim" accumulator (sharpness = largest local density gradient
  // magnitude → used for the chromatic-aberration split later).
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

    // Rim = local Laplacian approximation: how quickly w drops off here. Use
    // the analytic gradient magnitude (sampled cheaply with a tiny epsilon).
    float eps = 0.004;
    float wL = orbField(pw, c, r - eps, s);
    float wR = orbField(pw, c, r + eps, s);
    float ww = abs(wL - wR);
    rimAccum += ww * (1.0 / (eps * 2.0));
  }

  // ── Density → palette ramp → final colour ──
  // Normalise weighted hue by total weight; use the density to interpolate
  // between the theme background and the iridescent rim colour.
  vec3 orbHue = weightSum > 1e-4 ? weightedHue / weightSum : accentRamp(0.5);

  // Soft "core vs halo" split: small density → background, large → orb body.
  float core = smoothstep(0.05, 0.55, density);
  float halo = smoothstep(0.0, 0.08, density) * (1.0 - core);

  // Iridescent oil-slick bias: phase = density + time → rainbow rim.
  float phase = density * 1.4 + tHue * 1.3 + length(warp) * 0.5;
  vec3 slick = vec3(
    accentRamp(fract(phase + 0.10)).r,
    accentRamp(fract(phase + 0.34)).g,
    accentRamp(fract(phase + 0.62)).b
  );

  // ── Chromatic-aberration rim: sample density at three offset positions in
  //     palette-space, then weight the three ramps by them. Cheap, classic CA.
  float ca = 0.018 + 0.012 * halo;
  float dR = density + ca * 1.6;
  float dG = density;
  float dB = density - ca * 1.6;
  vec3 caRgb = vec3(
    smoothstep(0.05, 0.55, dR),
    smoothstep(0.05, 0.55, dG),
    smoothstep(0.05, 0.55, dB)
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
    // Soft airglow floor (prevents "dead black" between orbs).
    col += vec3(0.05, 0.06, 0.10) * (1.0 - core) * 0.4;
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
`;function a(){return e({id:"plasma-orbs",label:"Plasma Orbs",body:t})}export{a as createPlasmaOrbsKernel};
