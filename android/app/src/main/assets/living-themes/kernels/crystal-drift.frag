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


// ── Crystal Drift — animated Worley/Voronoi cellular field ───────────────
vec2 cd_hash22(vec2 p) {
  p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
  return fract(sin(p) * 43758.5453123);
}

// Returns vec4(F1, F2, id.x, id.y) over a fixed 3x3 neighborhood of drifting
// sites. id is the winning site's stable hash (hue + facet normal seed).
// heat (0..1) softens the glass locally: drift amplitude widens from 0.42
// toward the 0.5 lattice-safety bound (sites stay inside their own cell, so
// the 3x3 scan never mis-classifies F1) and the sites get a bounded phase
// push + tremble, making cells shear under the pointer while the field far
// from it is untouched.
vec4 cd_worley(vec2 q, float t, float heat) {
  vec2 g = floor(q);
  vec2 f = fract(q);
  float f1 = 8.0, f2 = 8.0;
  vec2 id = vec2(0.0);
  float amp = 0.42 + 0.08 * heat;        // <= 0.5 keeps F1 exact in 3x3
  // Bounded agitation: a static phase push + a slow tremble — NOT a rate
  // multiplier (t * heat would grow the spatial phase gap across the halo
  // without bound, tearing the heated cells apart minutes into a session).
  float ph = t * 0.55 + heat * (1.9 + 1.1 * sin(t * 1.7));
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 lat = vec2(float(i), float(j));
      vec2 rnd = cd_hash22(g + lat);
      vec2 pt = lat + 0.5 + amp * sin(ph + 6.2831853 * rnd);
      vec2 d = pt - f;
      float dist = dot(d, d);
      if (dist < f1) {
        f2 = f1;
        f1 = dist;
        id = rnd;
      } else if (dist < f2) {
        f2 = dist;
      }
    }
  }
  return vec4(sqrt(f1), sqrt(f2), id);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float t = uTime;

  // ── Pointer heat: the cursor warms the glass (aspect-corrected coords) ──
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 pp = (uPointer - 0.5) * vec2(aspect, 1.0);
  vec2 toPtr = p - pp;
  float heat = uPointerActive * exp(-dot(toPtr, toPtr) * 3.5);

  // ── Domain-warp the lattice so cells shear instead of sitting on a grid ──
  float w = fbm(vec3(p * 1.3, t * 0.05));
  vec2 warp = vec2(w, fbm(vec3(p * 1.3 + 7.31, t * 0.05)));
  vec2 q = p * 2.6 + 0.35 * warp;
  q += 0.12 * vec2(t * 0.10, -t * 0.07);   // slow global drift

  // ── Cellular field: F1 facet, F2-F1 seam, stable per-cell hue ──
  vec4 cell = cd_worley(q, t, heat);
  float f1 = cell.x, f2 = cell.y, hue = cell.z;
  float edge = f2 - f1;
  float vein = 1.0 - smoothstep(0.0, 0.085, edge);   // glowing seam mask
  float facet = smoothstep(0.0, 0.85, f1);           // cell interior shade
  float tone = fract(hue + 0.10 * w + t * 0.018);    // palette index per cell
  vec3 base = accentRamp(tone);

  // ── Per-cell facet shading: pseudo-normal from the site id, fixed key ──
  // light. Each pane tilts at its own stable angle, so neighbors catch the
  // light differently and the tessellation reads as cut glass, not a wash.
  vec3 nrm = normalize(vec3(cell.zw * 2.0 - 1.0, 1.6));
  float lam = 0.60 + 0.40 * clamp(dot(nrm, normalize(vec3(-0.42, 0.68, 0.60))), 0.0, 1.0);

  // ── Theme composite ──
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: faceted glass glowing over deep ink, with bright seam highlights.
    col = mix(uBg, base, (0.30 + 0.45 * facet) * lam * uIntensity);
    col += base * vein * (0.85 * uIntensity);
    // Seam glint: the cell hue lifted toward ink (light in dark theme), so
    // the sparkle stays palette-true instead of a hardcoded cool white.
    col += mix(base, uInk, 0.65) * pow(vein, 3.0) * 0.22 * uIntensity;
  } else {
    // LIGHT: tinted facets inked onto warm paper; seams deposit ink (no blowout).
    col = uBg;
    vec3 tint = mix(uBg, base, 0.55);
    col = mix(col, tint, (0.32 + 0.40 * facet) * lam * uIntensity);
    col = mix(col, uInk, vein * 0.16 * uIntensity);
    col = mix(col, base, pow(vein, 2.0) * 0.10 * uIntensity);
  }

  // ── Pointer halo: heated seams glow near the cursor (heat already folds
  // in uPointerActive, so the glow fades smoothly instead of gating) ──
  col += accentRamp(fract(0.5 + t * 0.08)) * heat * vein * 0.45 * uIntensity * (uTheme < 0.5 ? 1.0 : 0.5);
  col += base * heat * 0.10 * uIntensity;

  // ── Vignette (keeps foreground text legible) ──
  float vig = smoothstep(1.5, 0.2, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}