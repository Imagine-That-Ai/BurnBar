import{c as e}from"./createShaderKernel-DZdzJunW.js";import"./index-CeVJulmk.js";const t=`
// ── Crystal Drift — animated Worley/Voronoi cellular field ───────────────
vec2 cd_hash22(vec2 p) {
  p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
  return fract(sin(p) * 43758.5453123);
}

// Returns vec3(F1, F2, hue) over a fixed 3x3 neighborhood of drifting sites.
vec3 cd_worley(vec2 q, float t) {
  vec2 g = floor(q);
  vec2 f = fract(q);
  float f1 = 8.0, f2 = 8.0, hue = 0.0;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 lat = vec2(float(i), float(j));
      vec2 rnd = cd_hash22(g + lat);
      vec2 pt = lat + 0.5 + 0.42 * sin(t * 0.55 + 6.2831853 * rnd);
      vec2 d = pt - f;
      float dist = dot(d, d);
      if (dist < f1) {
        f2 = f1;
        f1 = dist;
        hue = rnd.x;
      } else if (dist < f2) {
        f2 = dist;
      }
    }
  }
  return vec3(sqrt(f1), sqrt(f2), hue);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float t = uTime;

  // ── Domain-warp the lattice so cells shear instead of sitting on a grid ──
  float w = fbm(vec3(p * 1.3, t * 0.05));
  vec2 warp = vec2(w, fbm(vec3(p * 1.3 + 7.31, t * 0.05)));
  vec2 q = p * 2.6 + 0.35 * warp;
  q += 0.12 * vec2(t * 0.10, -t * 0.07);   // slow global drift

  // ── Cellular field: F1 facet, F2-F1 seam, stable per-cell hue ──
  vec3 cell = cd_worley(q, t);
  float f1 = cell.x, f2 = cell.y, hue = cell.z;
  float edge = f2 - f1;
  float vein = 1.0 - smoothstep(0.0, 0.085, edge);   // glowing seam mask
  float facet = smoothstep(0.0, 0.85, f1);           // cell interior shade
  float tone = fract(hue + 0.10 * w + t * 0.018);    // palette index per cell
  vec3 base = accentRamp(tone);

  // ── Theme composite ──
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: faceted glass glowing over deep ink, with bright seam highlights.
    col = mix(uBg, base, (0.30 + 0.45 * facet) * uIntensity);
    col += base * vein * (0.85 * uIntensity);
    col += vec3(0.85, 0.92, 1.0) * pow(vein, 3.0) * 0.22;   // cool seam sparkle
  } else {
    // LIGHT: tinted facets inked onto warm paper; seams deposit ink (no blowout).
    col = uBg;
    vec3 tint = mix(uBg, base, 0.55);
    col = mix(col, tint, (0.32 + 0.40 * facet) * uIntensity);
    col = mix(col, uInk, vein * 0.16 * uIntensity);
    col = mix(col, base, pow(vein, 2.0) * 0.10 * uIntensity);
  }

  // ── Pointer halo: lights seams near the cursor ──
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.0);
    col += accentRamp(fract(0.5 + t * 0.08)) * halo * vein * 0.45 * (uTheme < 0.5 ? 1.0 : 0.5);
    col += base * halo * 0.10;
  }

  // ── Vignette (keeps foreground text legible) ──
  float vig = smoothstep(1.5, 0.2, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;function i(){return e({id:"crystal-drift",label:"Crystal Drift",body:t})}export{i as createCrystalDriftKernel};
