import{c as e}from"./createShaderKernel-DNT32VLs.js";import"./index-PmASUbTN.js";const t=`
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

  // STEP 3 — Height/thickness field for normals + interference.
  float h = fbm(vec3(pw * 1.6, t * 0.5));
  float filmThk = h * 0.7 + 0.15 * length(pw);  // radial meniscus bias

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
  float band = abs(h - 0.5) * 2.0;
  float seam = smoothstep(0.55, 0.70, band) * smoothstep(0.86, 0.70, band);
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
    col = mix(uBg, mesh, 0.30 * uIntensity);  // soft pastel over pearl
  }
  float causticGain = (0.10 + 0.16 * uIntensity)
    * (0.35 + 0.65 * sheen)
    * (uTheme < 0.5 ? 1.0 : 0.5);
  col += accentRamp(0.7 + 0.15 * breath) * caustic * causticGain;
  col += iri * rim * (uTheme < 0.5 ? 0.12 : 0.06);

  // STEP 9 — Eased pointer bloom (smoothed upstream in createShaderKernel); the
  // bloom radius widens slightly on inhale.
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float d = length(p - pp);
    col = mix(col, accentRamp(0.4 + 0.2 * breath), smoothstep(0.35, 0.0, d) * 0.18 * uIntensity);
  }

  // STEP 10 — Breathing grain: grittier on exhale, silkier at peak inhale.
  // dither() is still applied by MAIN on top of this.
  float g = hash21(fragCoord + fract(uTime) * vec2(13.0, 7.0));
  col += (g - 0.5) * (0.016 + 0.010 * (1.0 - breath));
  return col;
}
`;function i(){return e({id:"mesh",label:"Iridescent Mesh",body:t})}export{i as createMeshKernel};
