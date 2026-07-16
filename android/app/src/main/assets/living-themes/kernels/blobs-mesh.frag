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


#define BLOB_COUNT 4

// Hash → unit range (Ashima/Gustavson-style, deterministic, no snoise).
float blobHash(float n){ return fract(sin(n) * 43758.5453123); }

// Inverse-square blob weight at point p for a blob centred at c with radius r.
// Soft-edge falloff: w = 1 / (r^2 + d^2) — the canonical "metaball-meets-mesh"
// weight. Returns POSITIVE density (additive across blobs).
float blobWeight(vec2 p, vec2 c, float r){
  vec2 d = p - c;
  float dd = dot(d, d);
  float rr = r * r;
  // Smooth the singularity: k = 1 when d=0, falls off smoothly. This is the
  // classic soft-min trick inverted — it preserves the gentle mesh feel without
  // a 1/0 spike at the centre.
  return rr / (rr + dd + 1e-4);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  // Aspect-correct centred coords (y up). p ∈ [-aspect/2 .. +aspect/2] × [-0.5..0.5].
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // ── Time clocks (multi-frequency so the loop never visibly repeats) ──
  float t    = uTime * 0.085;   // drift — slow, contemplative
  float tHue = uTime * 0.018;   // hue roll (very slow; colour identity holds)
  float tLow = uTime * 0.045;   // collective-centre drift

  // ── Domain warp: simplex noise displaces the sample coordinate so the
  //    blob boundaries flow like liquid (the 2026 "fluid mesh" feel). ONE
  //    shared fbm warp keeps the field as a single body. ──
  vec2 warp = 0.22 * vec2(
    fbm(vec3(p * 0.85,         tLow)),
    fbm(vec3(p * 0.85 + 5.2,   tLow))
  );
  vec2 pw = p + warp;

  // ── Collective centre (the whole mesh drifts on its own slow clock; the
  //    pointer nudges it gently, like a magnet) ──
  vec2 centre = 0.08 * vec2(sin(tLow * 1.7), cos(tLow * 1.3));
  if (uPointerActive > 0.5) {
    vec2 cursor = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    centre = mix(centre, cursor, 0.20); // the nearest blob visibly leans in, never a dart
  }

  // ── Build the 4-blob mesh ──
  // Each blob's centre wanders around the collective centre via simplex noise,
  // its size breathes gently, its softness is per-instance so silhouettes vary.
  vec3 weightedColor = vec3(0.0);
  float weightSum = 0.0;
  // Top-two blob weights, tracked for the iso-contour glint (the locus where
  // two adjacent blobs contribute equally).
  float wTop = 0.0;
  float wSecond = 0.0;

  for (int i = 0; i < BLOB_COUNT; i++) {
    float fi = float(i);
    float seed     = blobHash(fi * 1.3 + 0.7);
    float driftSpd = 0.55 + 0.45 * blobHash(fi * 2.1 + 1.9);
    float driftAmp = 0.32 + 0.20 * blobHash(fi * 3.7 + 4.1);
    // Two-axis wander via low-freq snoise — the "organic" feel.
    vec2  wander = vec2(
      snoise(vec3(pw * 0.6 + fi * 7.1,         t * driftSpd)),
      snoise(vec3(pw * 0.6 + fi * 7.1 + 12.3,  t * driftSpd))
    );
    float rad = 0.42 + 0.14 * blobHash(fi * 5.3 + 2.7);
    // Breathing radius — 5.7s/11s irrational pair, never phase-locks.
    float breathe = 1.0 + 0.12 * (
        0.62 * sin(uTime * 1.099 + seed * 6.2831) +
        0.38 * sin(uTime * 0.571 + seed * 6.2831 + 1.3)
    );
    rad *= breathe;

    // The blob's resting colour comes from a per-instance palette slot (the
    // existing accent ramp), with a tiny per-blob hue roll driven by tHue +
    // a deterministic per-instance offset.
    float hueT = fract(tHue + 0.07 * fi + 0.13 * blobHash(fi * 9.7 + 6.1));
    vec3  col  = accentRamp(hueT);

    vec2 c = centre + driftAmp * wander;
    float w = blobWeight(pw, c, rad);
    weightedColor += col * w;
    weightSum += w;
    if (w > wTop) { wSecond = wTop; wTop = w; }
    else if (w > wSecond) { wSecond = w; }
  }

  // Normalise: weighted colour sum / total weight → the mesh colour at p.
  vec3 mesh = weightSum > 1e-4 ? weightedColor / weightSum : accentRamp(0.5);

  // ── Craft cue: iso-contour glint. Where the top two blob weights cross
  //    (equal-weight locus), a thin palette-light seam appears — fwidth-crisped
  //    so it stays a soft hairline at any DPR. Gated on wTop so the far field,
  //    where ALL weights converge to similar small tails, stays quiet. ──
  float margin = (wTop - wSecond) / (wTop + wSecond + 1e-4);
  float rimAA = fwidth(margin);
  float rim = 1.0 - smoothstep(0.0, rimAA * 2.5 + 0.02, margin);
  rim *= smoothstep(0.35, 0.65, wTop);

  // ── Theme composite (timing identical; only the math flips) ──
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: additive bloom over deep ink; the mesh glows like a luminous
    // gradient poster. Filmic knee keeps the brightest blob-centres from
    // burning to flat white.
    float key = clamp(weightSum * 0.7, 0.0, 1.0);
    col = uBg;
    col += mesh * (0.95 * uIntensity);
    // Core lift: the accentRamp ends brighten the blob hearts (pre-knee, so
    // the filmic rolloff still tames them) — the field reads as relief.
    vec3 coreGlow = 0.5 * (accentRamp(0.0) + accentRamp(1.0));
    col += coreGlow * smoothstep(0.85, 1.6, weightSum) * 0.34 * uIntensity;
    col = col / (col + vec3(0.55));
    col *= 1.16;
    // Valley shadow: deepen the inter-blob gaps toward a uBg-derived shade so
    // the mesh gains contour (never true black — the airglow floor follows).
    col = mix(col, uBg * 0.6, (1.0 - key) * 0.45);
    // Faint airglow floor, tinted from uBg + a cool ramp note (prevents
    // "dead black" between blobs, stays palette-true).
    vec3 airglow = uBg * 1.4 + accentRamp(0.62) * 0.06;
    col += airglow * (1.0 - key) * 0.35;
  } else {
    // LIGHT: pearl watermark — a soft, painterly gradient deposited on the
    // paper. Intensity is ~0.78 in light mode (palette.ts) so we never blow out.
    vec3 pearl = mix(uBg, mesh, 0.85);
    // Luminance key: brighter where weightSum is high (blob centres), darker
    // in the gaps. This gives the gradient a soft "spotlit" feel without
    // any hard rim or contour.
    float key = clamp(weightSum * 0.85, 0.0, 1.0);
    col = mix(uBg, pearl, key * 0.62 * uIntensity);
    // A whisper of ink gives the bright blob centres a soft contour.
    col = mix(col, uInk, smoothstep(0.55, 0.95, key) * 0.05 * uIntensity);
  }

  // ── Apply the iso-contour glint: a luminous seam in dark (mesh lifted
  //    toward uInk, which is light on dark), a whisper of ink contour in
  //    light. Thin, soft, and it travels with the blobs. ──
  vec3 rimCol = mix(mesh, uInk, 0.55);
  col = mix(col, rimCol, rim * (uTheme < 0.5 ? 0.30 : 0.12) * uIntensity);

  // ── Pointer wash: a soft, slow-cycling halo behind the cursor ──
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.08)) * halo * 0.16
         * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // ── Vignette (protects text legibility over the field; light-handed so
  //    the corners keep their colour) ──
  float vig = smoothstep(1.6, 0.1, length(p));
  col = mix(uBg, col, 0.62 + 0.38 * vig);

  return col;   // MAIN() adds dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}