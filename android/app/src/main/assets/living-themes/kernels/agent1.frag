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


vec3 renderKernel(vec2 uv, vec2 fragCoord){
  // Normalized coordinates with aspect correction
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float t = uTime * 0.035;

  // Pointer in the same aspect-corrected space as p (inertially smoothed by
  // the host); used below to physically swell the nearest blob of each layer.
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 pp = (uPointer - 0.5) * vec2(aspect, 1.0);

  // ── Layer 1: Large slow-moving anchor blobs ──
  vec2 q1 = p * 1.6;
  // Domain warp for organic distortion
  vec2 w1 = vec2(
    fbm(vec3(q1 + vec2(0.0, 1.7), t * 0.7)),
    fbm(vec3(q1 + vec2(4.3, 2.8), t * 0.7))
  );
  vec2 f1 = q1 + 1.2 * w1;

  // Three anchor points orbiting slowly
  vec2 ptr1 = pp * 1.6;
  float a1 = 0.0;
  for (int i = 0; i < 3; i++) {
    float fi = float(i);
    vec2 center = vec2(
      sin(t * 0.4 + fi * 2.094) * 0.55,
      cos(t * 0.35 + fi * 2.094) * 0.35
    );
    // Pointer physicality: the blob nearest the cursor leans toward it and
    // its soft-min weight inflates, so the field swells to meet the pointer.
    vec2 toPtr1 = ptr1 - center;
    float near1 = uPointerActive * exp(-dot(toPtr1, toPtr1) * 1.4);
    center += toPtr1 * near1 * 0.35;
    float d = length(f1 - center);
    // Exponential soft-min blend: layers merge like liquid
    a1 += exp(-d * d * 2.8 / (1.0 + near1 * 0.9));
  }
  a1 = clamp(a1, 0.0, 1.0);

  // ── Layer 2: Medium detail blobs ──
  vec2 q2 = p * 2.4 + vec2(3.3, 1.1);
  vec2 w2 = vec2(
    fbm(vec3(q2 * 0.8 + vec2(1.7, 9.2), t * 0.9)),
    fbm(vec3(q2 * 0.8 + vec2(8.3, 2.8), t * 0.9))
  );
  vec2 f2 = q2 + 0.8 * w2;

  vec2 ptr2 = pp * 2.4 + vec2(3.3, 1.1);
  float a2 = 0.0;
  for (int i = 0; i < 4; i++) {
    float fi = float(i);
    // Orbit in q2 space — the +vec2(3.3, 1.1) decorrelation offset included,
    // so the medium blobs live on screen and actually intersect layer 1.
    vec2 center = vec2(3.3, 1.1) + vec2(
      sin(t * 0.55 + fi * 1.5708 + 1.0) * 0.45,
      cos(t * 0.48 + fi * 1.5708 + 2.0) * 0.4
    );
    vec2 toPtr2 = ptr2 - center;
    float near2 = uPointerActive * exp(-dot(toPtr2, toPtr2) * 1.4);
    center += toPtr2 * near2 * 0.35;
    float d = length(f2 - center);
    a2 += exp(-d * d * 3.5 / (1.0 + near2 * 0.9));
  }
  a2 = clamp(a2, 0.0, 1.0);

  // ── Layer 3: Fine detail / texture ──
  vec2 q3 = p * 4.0 + vec2(7.7, 5.5);
  float f3 = fbm(vec3(q3, t * 1.2));
  float a3 = smoothstep(-0.3, 0.6, f3) * 0.35;

  // ── Composite the layers into a mesh-like field ──
  // Layer 1 drives the primary color regions; layer 2 adds detail;
  // layer 3 gives surface texture.
  float field = a1 * 0.55 + a2 * 0.30 + a3 * 0.15;
  field = smoothstep(0.0, 0.85, field);

  // ── Hue mapping: slow drift through palette ──
  // The field value maps to a position on the accent ramp, but the mapping
  // itself drifts over time so the same spatial region changes color slowly.
  float hueShift = t * 0.15 + fbm(vec3(p * 0.6, t * 0.3)) * 0.25;
  float hue = fract(field * 0.9 + hueShift + length(p) * 0.08);
  vec3 col = accentRamp(hue);

  // ── Signature: thin-film interference where the layers overlap ──
  // Each layer carries its own phase (a1 vs a2 at offset rates); where both
  // fields are present the phases beat, and the beat rides the accentRamp so
  // intersections ring with structured color instead of washing out. Reuses
  // a1/a2 directly — zero extra fbm.
  float overlap = a1 * a2;
  float beat = a1 * 5.0 - a2 * 4.0 + t * 3.0;
  float fringeAmt = smoothstep(0.05, 0.30, overlap) * (0.5 + 0.5 * cos(beat * 6.2831));
  vec3 fringe = accentRamp(fract(beat * 0.45 + hueShift));
  col = mix(col, fringe, fringeAmt * 0.5);

  // ── Palette-derived light tints (no hardcoded whites) ──
  // Dark theme lights from the bg-complement; light theme lifts toward the
  // pearl bg itself — every highlight stays inside the palette.
  vec3 lightSrc = mix(clamp(vec3(1.0) - uBg, 0.0, 1.0), uBg, uTheme);
  vec3 crestTint = mix(lightSrc, uAccent3, 0.4);
  vec3 sheenTint = mix(lightSrc, uAccent1, 0.55);

  // ── Add luminous highlights at blob crests ──
  float crest = pow(a1, 3.0) * 0.4 + pow(a2, 3.0) * 0.25;
  col += crestTint * crest * 0.35;

  // ── Subtle surface sheen from layer 3 ──
  col += sheenTint * a3 * 0.12;

  // ── Theme composite ──
  vec3 outCol;
  if (uTheme < 0.5) {
    // Dark: additive glow over deep ink background
    outCol = uBg + col * field * (0.85 * uIntensity);
    // Filmic tonemap to prevent blow-out at blob intersections
    outCol = outCol / (outCol + vec3(0.6)) * 1.25;
    // Airglow grain in the void
    outCol += sheenTint * (hash21(fragCoord) - 0.5) * 0.012;
  } else {
    // Light: soft watercolor wash on pearl background
    // The field darkens/saturates the background rather than adding light
    float v = pow(field, 0.85) * 0.55 * uIntensity;
    vec3 wash = mix(uBg, col, 0.75);
    outCol = mix(uBg, wash, v);
    // Subtle ink contour at blob edges for definition
    float edge = smoothstep(0.35, 0.55, field) * (1.0 - smoothstep(0.55, 0.85, field));
    outCol = mix(outCol, uInk, edge * 0.04 * uIntensity);
    // Brighten crests slightly
    outCol += crestTint * crest * 0.15 * uIntensity;
  }

  // ── Vignette ──
  float vig = smoothstep(1.4, 0.2, length(p));
  outCol = mix(uBg, outCol, 0.25 + 0.75 * vig);

  return outCol;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}