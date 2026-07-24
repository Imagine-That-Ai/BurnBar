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
uniform vec2  uScroll;
uniform float uScrollVel;



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


const float FIBER_FREQ = 1.7;
const float LAID_DENS  = 9.0;   // laid lines per unit of p.y
const float LAID_AMP   = 0.5;
const float DECKLE_W   = 1.55;

float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}

float lineHash(float n){
  return fract(sin(n * 127.1) * 43758.5453123);
}

// 3-octave fbm (injected snoise + accumulation) — the fiber body.
float paperFbm(vec3 q){
  float s = snoise(q) * 0.5;
  s += snoise(q * 2.05) * 0.25;
  s += snoise(q * 4.12) * 0.125;
  return s;
}

// Warmest accent (largest red-minus-blue) — the sheet biases its hue toward
// it so the hand-made kozo warmth survives any custom palette.
vec3 warmAccent(){
  vec3 a = uAccent0; float w = uAccent0.r - uAccent0.b;
  float w1 = uAccent1.r - uAccent1.b; if (w1 > w){ a = uAccent1; w = w1; }
  float w2 = uAccent2.r - uAccent2.b; if (w2 > w){ a = uAccent2; w = w2; }
  float w3 = uAccent3.r - uAccent3.b; if (w3 > w){ a = uAccent3; w = w3; }
  return a;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5*uResolution)/uResolution.y;

  float sN = uScroll.y > 0.0 ? uScroll.x/uScroll.y : 0.0;
  float breath = 0.5 + 0.5*sin(uTime*0.5);
  float drift = sN*1.4;
  vec3 flow = vec3(uTime*0.045 + drift, uTime*0.028, 0.0);

  // Domain warping: a low-frequency warp field gives the fibers their organic,
  // hand-pulled non-uniformity. Two taps of fbm feed the sample position.
  vec3 q = vec3(p*FIBER_FREQ, 0.0) + flow;
  vec2 warpOff = vec2(
    paperFbm(q + vec3(13.1, 0.0, 0.0)),
    paperFbm(q + vec3(0.0, 17.7, 0.0))
  ) * 0.4;
  float fiber = paperFbm(vec3(q.xy + warpOff, q.z));  // ~[-0.875, 0.875]

  // Laid lines: the wire-screen imprint. Each line lives in its own cell with
  // a hash-jittered crest offset, a hash-varied weight, and a small live sway,
  // so the imprint reads as irregular hand-laid texture rather than a clean
  // sinusoid band — and every offset is bounded inside the cell, so a line can
  // never tear at a cell seam. The pointer dimples the sheet: lines bow away
  // from the cursor (paper flexing under the hand).
  vec2 pf = (uPointer - 0.5) * vec2(uResolution.x/uResolution.y, 1.0);
  vec2 pd = p - pf;
  float press = exp(-dot(pd, pd)*5.0) * uPointerActive;
  float flex = 0.07 * clamp(pd.y*4.0, -1.0, 1.0) * press;
  float yc = p.y*LAID_DENS + 0.5;
  float cell = floor(yc);
  float jit  = (lineHash(cell) - 0.5) * 0.32;        // per-line crest offset
  float sway = 0.06 * sin(uTime*0.6 + cell*1.7);     // live in-place sway
  float wire = fract(yc) - 0.5 + warpOff.y*0.12 + jit + sway + flex;
  float thick = 0.05 + 0.05*lineHash(cell + 57.0);   // per-line wire weight
  float laid = (1.0 - smoothstep(0.0, thick + 0.04, abs(wire))) * LAID_AMP;

  // Deckle edge: a soft vignette whose boundary is itself warped by the fiber
  // field (a hand-made deckle is irregular, not a clean ellipse).
  float deckleR = length(p * vec2(0.75, 1.0))
    + 0.08 * paperFbm(vec3(p*3.0, uTime*0.05));
  float deckle = smoothstep(DECKLE_W, DECKLE_W*0.55, deckleR);

  // Warm window-light bloom: an off-canvas top-left light catching the sheet.
  vec2 lp = p - vec2(-0.9, 0.85);
  float lit = exp(-dot(lp, lp) * 1.6) * (0.6 + 0.4*breath);

  // Fiber → base tint. Kozo is warm cream; fibers read as subtle tan variation.
  float fib01 = clamp(fiber*0.5 + 0.5, 0.0, 1.0);
  vec3 warm = warmAccent();

  vec3 col;
  if (uTheme < 0.5){
    // DARK: deep warm ink-wash washi under moonlight. The sheet is uBg lifted
    // toward uInk, hue-biased toward the warmest accent.
    vec3 kozoLo = mix(mix(uBg, uInk, 0.04), warm, 0.06);
    vec3 kozoHi = mix(mix(uBg, uInk, 0.15), warm, 0.12);
    vec3 kozo = mix(kozoLo, kozoHi, fib01);
    vec3 tint = accentRamp(0.4 + 0.08*fib01);
    col = mix(uBg, kozo, 0.55*uIntensity);
    col += tint*laid*0.08*uIntensity;          // faint laid sheen
    col += accentRamp(0.6)*lit*0.20*uIntensity; // window bloom
    vec3 grainTint = mix(uInk, warm, 0.35);
    col += grainTint*(ign(fragCoord)-0.5)*0.012*uIntensity; // paper grain
    col *= deckle*0.6 + 0.4;                     // deckle edges fall to bg
    col = col/(col + vec3(0.55));
    col *= 1.10;
  } else {
    // LIGHT: bright cream kozo in window light — uBg pulled toward uInk for
    // the fibrous shadow, lifted for the sheet crest, both warm-biased.
    vec3 kozoLo = mix(mix(uBg, uInk, 0.08), warm, 0.10);
    vec3 kozoHi = mix(uBg + (vec3(1.0) - uBg)*0.5, warm, 0.05);
    vec3 kozo = mix(kozoLo, kozoHi, fib01);
    vec3 tint = accentRamp(0.3 + 0.06*fib01);
    col = mix(uBg, kozo, 0.7*uIntensity);
    col = mix(col, tint, 0.05*laid*uIntensity); // faint laid tint
    col = mix(col, tint*1.1, 0.18*lit*uIntensity); // window warmth
    vec3 grainTint = mix(uInk, warm, 0.45);
    col += grainTint*(ign(fragCoord)-0.5)*0.008*uIntensity; // paper grain
    col *= deckle*0.8 + 0.2;
    col = mix(col, uInk, smoothstep(0.4, 1.4, deckleR)*0.03*uIntensity); // deckle ink-edge
  }

  // Pointer halo: a soft warm disc where the hand presses the sheet, sharing
  // the dimple falloff so light and flex read as one physical touch.
  col += accentRamp(0.45)*press*0.10*breath*uIntensity;

  // Final vignette to protect glass-type legibility.
  float vig = smoothstep(1.7, 0.3, length(p));
  col = mix(uBg, col, 0.45 + 0.55*vig);
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}