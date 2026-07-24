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


// ── Mycelium Mesh — domain-warped ridged-fbm transport network ────────────
// Ridged fbm filament: folds an fbm field into a thin bright ridge. Declared
// before renderKernel so it is in scope at the call sites below. Every fbm()
// call passes a vec3 (the chunk's signature is float fbm(vec3)).
float ridged(vec2 p) {
  float v = fbm(vec3(p, 0.0));
  v = 1.0 - abs(2.0 * v - 1.0);
  return v * v;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 aspect = vec2(uResolution.x / uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * aspect;
  float t = uTime * 0.18;   // growth crawl — visible within ~2s

  // ── Pointer nutrient source: inverse-square pull + local exp feed ──
  // pull bends the inner warp (the network leans in); feed is a tight
  // exponential dimple that thickens + brightens the veins around the cursor.
  vec2 nutrient = (uPointer - 0.5) * aspect;
  vec2 toPtr = p - nutrient;
  float pull = uPointerActive * 0.35 / (0.15 + dot(toPtr, toPtr));
  float feed = uPointerActive * exp(-6.0 * dot(toPtr, toPtr));

  // ── Two-stage domain warp (the network's meandering coordinate field) ──
  vec2 q = vec2(
    fbm(vec3(p * 1.3 + vec2(0.0, t), 0.0)),
    fbm(vec3(p * 1.3 + vec2(5.2, -t), 0.0))
  );
  vec2 r = vec2(
    fbm(vec3(p * 2.1 + 2.0 * q + vec2(1.7, 9.2) + pull, 0.0)),
    fbm(vec3(p * 2.1 + 2.0 * q + vec2(8.3, 2.8) - pull * 0.5, 0.0))
  );

  // ── Ridged veins: a coarse trunk + a finer capillary octave ──
  // feed folds in pre-clamp so ridges near the cursor widen through the
  // color thresholds below (nutrient thickening, not just a lean).
  float veins = ridged(p * 3.0 + 3.0 * r + t);
  veins += 0.45 * ridged(p * 7.0 + 4.0 * r - t * 1.3);
  veins = clamp(veins * (1.0 + 0.55 * feed) + 0.12 * feed, 0.0, 1.0);

  // ── Breathing: reuse the q-warp fbm sample as the phase (saves an fbm) ──
  float breathe = 0.85 + 0.15 * sin(uTime * 0.4 + q.x * 6.2831);
  veins *= breathe;

  // ── Junction sparks (the craft cue): a ~4s pulse, staggered by the warp
  // so nodes twinkle asynchronously instead of strobing in lockstep ──
  float pulse = 0.55 + 0.45 * sin(uTime * 1.57 + (r.x + r.y) * 6.2831);
  float nodes = pow(veins, 6.0) * pulse;
  vec3 spark = accentRamp(0.5 + 0.5 * sin(t)); // slow hue cycle for the sparks

  // ── Dark theme: luminous veins over deep ink, with sparking nodes ──
  vec3 col = uBg;
  vec3 net = accentRamp(veins);
  col = mix(col, net, smoothstep(0.25, 0.9, veins));
  col = mix(col, uInk, smoothstep(0.82, 1.0, veins) * 0.6);
  col += spark * nodes * (0.7 + 0.6 * feed);     // fed junctions flare brighter

  // ── Light theme: keep veins as ink-on-pearl, never blown-out glow ──
  if (uTheme > 0.5) {
    col = mix(uBg, mix(uBg, net, 0.7), smoothstep(0.25, 0.95, veins));
    col = mix(col, uInk, smoothstep(0.8, 1.0, veins) * 0.25);
    // sparks read as saturated accent pips on pearl, never additive white
    col = mix(col, spark * 0.75, nodes * (0.6 + 0.4 * feed));
  }

  // ── Vignette (keeps foreground text legible) ──
  float vig = smoothstep(1.25, 0.2, length(p));
  col *= mix(0.55, 1.0, vig);

  col *= uIntensity;
  return col;   // MAIN() appends dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}