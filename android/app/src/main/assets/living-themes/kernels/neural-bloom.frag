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


// ── Neural Bloom — latent FBM → MLP palette → organic colour field ─────────

// Small MLP: 2 inputs (latent x, y) → 4 hidden → 3 outputs (palette mix weights).
// Weights are baked constants (no external texture / uniform buffer needed).
// This is the "generative AI" part: the network shape and weights were tuned
// by iterative prompt-guided search to produce pleasing, non-repeating colour
// fields that map the site's accent palette.

// The hidden tanh activations are also returned (out vec4) so the render pass
// can draw their zero-crossings as decision-boundary contours — the network
// surfaced as visible structure, at near-zero added cost.
vec3 neuralPalette(vec2 latent, float t, out vec4 hidden) {
  // Input features: the latent coordinate + a slow time phase.
  float i0 = latent.x;
  float i1 = latent.y;
  float i2 = sin(t * 0.13 + latent.x * 2.1) * 0.5 + 0.5;
  float i3 = cos(t * 0.09 - latent.y * 1.7) * 0.5 + 0.5;

  // Hidden layer 1 (4 neurons, tanh activation).
  float h0 = tanh(i0 *  0.72 + i1 *  0.31 + i2 * -0.55 + i3 *  0.44 + 0.12);
  float h1 = tanh(i0 * -0.41 + i1 *  0.63 + i2 *  0.28 + i3 * -0.19 - 0.08);
  float h2 = tanh(i0 *  0.15 + i1 * -0.47 + i2 *  0.61 + i3 *  0.33 + 0.20);
  float h3 = tanh(i0 * -0.29 + i1 * -0.22 + i2 * -0.38 + i3 *  0.74 - 0.05);
  hidden = vec4(h0, h1, h2, h3);

  // Output layer (3 channels → accent-ramp t, saturation boost, brightness).
  float o0 = h0 *  0.58 + h1 * -0.34 + h2 *  0.21 + h3 *  0.49 + 0.10; // ramp position
  float o1 = h0 * -0.21 + h1 *  0.45 + h2 * -0.12 + h3 *  0.31 + 0.55; // saturation
  float o2 = h0 *  0.33 + h1 *  0.27 + h2 * -0.44 + h3 * -0.18 + 0.60; // brightness

  return vec3(o0, o1, o2);
}

// 2D FBM (3 octaves) used as the "latent" feature map.
float latentFbm(vec2 p) {
  float a = 0.5, s = 0.0;
  for (int i = 0; i < 3; i++) {
    s += a * snoise(vec3(p, 0.0));
    p *= 2.0;
    a *= 0.5;
  }
  return s;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // Slow domain drift so the field never repeats on screen.
  float t = uTime * 0.045;

  // Pointer warp: when active, pull the latent space toward the cursor — a
  // "neural attention" spot. Wide falloff + firm pull so the warp reads.
  vec2 warp = p;
  if (uPointerActive > 0.5) {
    vec2 cursor = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    vec2 d = cursor - p;
    float dist = length(d);
    float influence = exp(-dist * dist * 2.2);
    warp += d * influence * 0.5;
  }

  // Latent feature map: two warped FBM channels at different scales.
  float l0 = latentFbm(warp * 1.60 + vec2(t * 1.7, -t * 1.1));
  float l1 = latentFbm(warp * 2.40 + vec2(-t * 1.3,  t * 0.9) + 17.3);
  vec2 latent = vec2(l0, l1);

  // Neural palette mapping (hidden activations captured for the contour cue).
  vec4 hidden;
  vec3 nlp = neuralPalette(latent, uTime, hidden);
  float rampT = fract(nlp.x * 0.5 + 0.5 + uTime * 0.018);
  float sat   = clamp(nlp.y, 0.0, 1.0);
  float bri   = clamp(nlp.z, 0.0, 1.0);

  // Craft cue: decision-boundary contours. Each hidden tanh neuron partitions
  // latent space; its zero-crossing sweeps the screen as a curved iso-line.
  // fwidth-AA keeps the lines pixel-thin at any DPR; each neuron inks with its
  // own accent so the network reads as structure, not framing.
  vec4 aw = fwidth(hidden) * 1.6 + 1e-4;
  vec4 iso = vec4(1.0) - smoothstep(vec4(0.0), aw, abs(hidden));
  float boundary = clamp(iso.x + iso.y + iso.z + iso.w, 0.0, 1.0);
  vec3 boundaryInk = uAccent0 * iso.x + uAccent1 * iso.y
                   + uAccent2 * iso.z + uAccent3 * iso.w;

  // Base colour from the accent ramp.
  vec3 col = accentRamp(rampT);

  // Second, slower ramp layer for depth (like style-transfer "content" + "style").
  float rampT2 = fract(rampT + 0.35 + latent.x * 0.12);
  vec3 col2 = accentRamp(rampT2);
  col = mix(col, col2, 0.35 * sat);

  // Bloom intensity: a large soft gaussian envelope + fine noise detail.
  float bloom = exp(-dot(p, p) * 0.55) * 0.45;
  bloom += 0.18 * latent.y;
  bloom = clamp(bloom * bri * uIntensity, 0.0, 1.0);

  // Theme composite.
  vec3 outCol;
  if (uTheme < 0.5) {
    // DARK: additive bloom on deep ink. The neural palette drives the colour;
    // bloom modulates brightness. Filmic knee prevents blow-out.
    outCol = uBg + col * bloom * 1.25;
    outCol = outCol / (outCol + vec3(0.45));
    // Airglow floor, derived from the palette (never a hard-coded colour).
    outCol += (uBg * 0.5 + uAccent2 * 0.05) * (1.0 - bloom);
    // Decision boundaries glow faintly beneath the bloom.
    outCol += boundaryInk * 0.10 * (1.0 - 0.7 * bloom) * uIntensity;
    outCol *= 1.12;
  } else {
    // LIGHT: pearl deposit. The neural colours sit as a soft wash over the
    // paper background, with ink deepening in the brightest blooms.
    float lum = clamp(dot(col, vec3(0.45)) * bloom * 1.4, 0.0, 1.0);
    vec3 pearl = mix(uBg, col, 0.72 * sat);
    outCol = mix(uBg, pearl, lum * 0.55 * uIntensity);
    outCol = mix(outCol, uInk, smoothstep(0.50, 0.92, lum) * 0.04 * uIntensity);
    // Decision boundaries as faint pencil lines under the pearl wash.
    outCol = mix(outCol, mix(boundaryInk, uInk, 0.5),
                 boundary * 0.08 * (1.0 - 0.5 * bloom) * uIntensity);
    // Subtle warm vignette to keep text legible.
    float vig = smoothstep(1.35, 0.25, length(p));
    outCol = mix(outCol, uBg, (1.0 - vig) * 0.12);
  }

  // Pointer halo (subtle accent glow).
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 4.0);
    outCol += accentRamp(fract(0.55 + uTime * 0.08)) * halo * 0.15
            * (uTheme < 0.5 ? 1.0 : 0.55);
  }

  // Global vignette (protects glass-type legibility).
  float vig = smoothstep(1.5, 0.15, length(p));
  outCol = mix(uBg, outCol, 0.35 + 0.65 * vig);

  return outCol;   // MAIN() adds dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}