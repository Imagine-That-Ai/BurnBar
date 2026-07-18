import{c as o}from"./createShaderKernel-DZdzJunW.js";import"./index-CeVJulmk.js";const e=`
// ── Vogel Bloom — golden-angle phyllotaxis seed field ─────────────────────
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  const float GA = 2.399963229728653; // golden angle (137.5°)
  vec2 res = uResolution;
  vec2 p = (fragCoord - 0.5 * res) / res.y;

  // ── Living transform: slow rotation + breathing zoom + pointer parallax ──
  float t = uTime * 0.15;
  float ca = cos(t), sa = sin(t);
  p = mat2(ca, -sa, sa, ca) * p;
  p *= 1.6 + 0.25 * sin(uTime * 0.30);
  p -= (uPointer - 0.5) * uPointerActive * 0.30;

  float r = length(p) + 1e-5;

  // ── Inverse Vogel: nearest seed index i ≈ (r/c)²; probe a tiny window. ──
  float c = 0.045;
  float fi = r / c; fi = fi * fi;
  float i0 = floor(fi);

  float bloom = 0.0;
  float tintIdx = 0.0;
  float wsum = 1e-5;
  for (int k = -3; k <= 3; k++) {       // fixed 7-sample probe (mobile 60fps)
    float idx = i0 + float(k);
    if (idx < 0.0) continue;
    float ang = idx * GA;
    float rad = c * sqrt(idx);
    vec2 seed = rad * vec2(cos(ang), sin(ang));
    float d = length(p - seed);
    float dotR = 0.012 + 0.010 * sqrt(idx) * c;
    float dval = smoothstep(dotR, dotR * 0.35, d);          // soft glowing dot
    dval *= 0.55 + 0.45 * sin(rad * 14.0 - uTime * 2.0);    // shimmer outward
    bloom += dval;
    tintIdx += idx * dval;
    wsum += dval;
  }
  bloom = clamp(bloom, 0.0, 1.0);

  // ── Palette hue from the seed index (rolls across the accent ramp). ──
  float seedT = fract((tintIdx / wsum) * 0.0125);
  vec3 ramp = accentRamp(seedT);

  // ── Fibonacci spiral arms (parastichy interference) shimmering outward. ──
  float arms = abs(sin(0.5 * (atan(p.y, p.x) - r * 9.0 + uTime * 0.6)));
  vec3 armCol = accentRamp(fract(r * 0.4 + uTime * 0.05));
  float armGlow = (1.0 - arms) * smoothstep(1.3, 0.2, r);

  // ── Theme composite ──
  // DARK: glowing seed dots bloom over deep ink; arms add a faint shimmer.
  vec3 darkCol = mix(uBg, ramp, bloom);
  darkCol += armCol * armGlow * 0.08;
  darkCol = mix(darkCol, uInk, (1.0 - bloom) * 0.06);
  // LIGHT: ink-tinted seed deposits on the warm paper bg (never blows out).
  vec3 lightCol = mix(uBg, mix(ramp, uInk, 0.35), bloom * 0.85);
  lightCol = mix(lightCol, armCol, armGlow * 0.05);

  vec3 col = (uTheme < 0.5) ? darkCol : lightCol;
  col *= 0.85 + 0.30 * uIntensity;

  // ── Vignette (keeps foreground text legible). ──
  vec2 vu = fragCoord / uResolution;
  col *= smoothstep(1.15, 0.35, length(vu - 0.5) * 1.4);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;function l(){return o({id:"vogel-bloom",label:"Vogel Bloom",body:e})}export{l as createVogelBloomKernel};
