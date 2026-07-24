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
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // STEP 1 — CLOCKS. Multi-clock decomposition so the rhythm never visibly loops.
  float tBase  = uTime * 0.045;                                  // master (hypnotic)
  float tDrift = uTime * 0.018;                                  // horizontal sweep + hue roll
  float breath = smoothstep(0.15, 0.85, 0.5 + 0.5 * sin(uTime * 0.224)); // ~28s eased inhale (brightness only)
  float tCalm  = 0.5 + 0.5 * sin(uTime * 0.11);                  // coprime-ish hush: gates lit layers

  // STEP 2 — SHARED WARP, COMPUTED ONCE (the perf spine: 5 fbm = 20 snoise, same as before).
  // Inigo-Quilez double domain warp; keep q/r as vectors and derive a single advection flow.
  vec2 q = vec2(
    fbm(vec3(p * 1.4, tBase)),
    fbm(vec3(p * 1.4 + 5.2, tBase)));
  vec2 r = vec2(
    fbm(vec3(p * 1.4 + 1.2 * q + vec2(1.7, 9.2), tBase * 1.15)),
    fbm(vec3(p * 1.4 + 1.2 * q + vec2(8.3, 2.8), tBase * 1.15)));
  float fWarp = fbm(vec3(p * 1.4 + 1.6 * r, tBase * 0.9));
  vec2 flow = 1.6 * r + 0.7 * q;                                 // magnetic advection every curtain rides

  // MAGNETOSPHERIC GUST — the pointer locally drags the shared warp so every
  // curtain bows around the cursor. Analytic only (zero extra fbm; the 5-fbm
  // warp above is the budget ceiling). Aspect-corrected to match p.
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 pp = (uPointer - 0.5) * vec2(aspect, 1.0);
  vec2 toPtr = p - pp;
  float gust = uPointerActive * exp(-6.0 * dot(toPtr, toPtr));
  flow += 0.6 * gust * toPtr / (length(toPtr) + 1e-3);
  fWarp += 0.3 * gust;                                           // local altitude lift: hue leans toward the crown

  // STEP 3 — THREE CURTAINS (pure trig inside, ZERO extra fbm). Accumulate emission + luminance.
  vec3 acc = vec3(0.0);
  float totalLum = 0.0;
  for (int i = 0; i < 3; i++) {
    float di = float(i);
    float depth = 1.0 - 0.33 * di;                              // parallax magnitude on flow
    float lt = tBase * (1.0 + 0.25 * di) + di * 2.39989;        // golden-angle offset: never phase-locks
    vec2 lp = p * (1.0 - 0.16 * di);                            // near layers slightly zoomed
    lp.x += tDrift * (1.0 + 0.25 * di) * 1.6;                   // horizontal drift, nearer faster
    float x = lp.x * 3.2 + flow.x * (1.2 * depth) + lt;         // advected horizontal phase
    float hgt = lp.y * 1.4 + fWarp * 0.9 + flow.y * 0.5;        // warped vertical (altitude) coordinate

    // Fractal vertical filaments — 3 octaves of cheap abs(sin()), no noise.
    float fil = 0.0, amp = 1.0, fq = 1.0;
    for (int k = 0; k < 3; k++) {
      fil += amp * abs(sin(x * fq + hgt * 1.3));
      fq *= 2.3;
      amp *= 0.5;
    }
    fil *= 0.571;                                               // normalize ~ /1.75
    float edge = smoothstep(0.0, 1.0, fil);
    float core = 1.0 - edge;
    core = core * core * (3.0 - 2.0 * core);                    // smootherstep: soft bloom -> snap bright
    float glow = core * core;

    // Curtain hem envelope (fades top/bottom) — also the legibility guard.
    float env = smoothstep(-1.1, -0.2, lp.y) * smoothstep(1.3, 0.1, lp.y);

    // ALTITUDE-KEYED HUE: bottom cyan/iris, top violet/rose, with slow thin-film iridescence.
    float irid = 0.12 * sin(hgt * 6.2831 + length(r) * 4.0 + tBase * 0.5);
    float hue = clamp(0.5 + hgt * 0.5 + 0.12 * fWarp + irid + di * 0.05, 0.0, 1.0);
    vec3 accent = accentRamp(hue);

    // Hush gate: far layers fade during the calm so the field truly rests sometimes.
    float layerGate = smoothstep(0.0, 1.0, tCalm * 1.4 - di * 0.35);
    float lum = glow * env * layerGate;
    acc += accent * lum * (0.62 / (1.0 + 0.5 * di));            // far layers dimmer
    // Whiter-than-accent hot cores derived from the palette: the bg complement
    // blooms toward white over ink and stays quiet on pearl (no hardcoded ice).
    vec3 hotCore = mix(accent, clamp(vec3(1.0) - uBg, 0.0, 1.0), 0.6);
    acc += hotCore * pow(glow, 4.0) * env * 0.18 * (1.0 - 0.3 * di);
    totalLum += lum;
  }

  // STEP 4 — SIGNATURE PILLAR. A sparse traveling shaft, gated by per-cell noise so only 1-2 glow.
  float pCell = floor(p.x * 0.6 + tDrift * 1.3);
  float pPhase = fract(p.x * 0.6 + tDrift * 1.3);
  float pillar = exp(-pow((pPhase - 0.5) * 7.0, 2.0));
  float pillarGate = smoothstep(0.55, 0.95, snoise(vec3(pCell * 3.1, 0.0, tDrift * 0.5)) * 0.5 + 0.5);
  float rise = 0.5 + 0.5 * sin(uv.y * 3.14159 - uTime * 1.1);   // light visibly shoots upward
  vec3 pillarHue = accentRamp(clamp(0.35 + uv.y * 0.5, 0.0, 1.0));
  acc += pillarHue * pillar * pillarGate * rise * 0.7 * breath;

  // STEP 5 — BREATH TO BRIGHTNESS ONLY (never position).
  acc *= mix(0.86, 1.18, breath);

  // STEP 6 — THEME COMPOSITE (timing identical; only the math flips).
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: additive over deep ink, then a filmic knee blooms stacked cores toward white.
    col = uBg;
    col += acc * (0.95 * uIntensity);
    col = col / (col + vec3(0.55));
    col *= 1.18;                                                // TONEMAP_KNEE — overexposed-aurora bloom
    // Airglow grain floor (dark only): quietness in the void instead of dead
    // black, tinted from the palette (accent midpoint toward the bg complement).
    vec3 airglow = mix(accentRamp(0.45), clamp(vec3(1.0) - uBg, 0.0, 1.0), 0.5);
    col += airglow * (hash21(fragCoord) - 0.5) * 0.015 * (1.0 - clamp(totalLum * 2.0, 0.0, 1.0));
  } else {
    // LIGHT: subtractive pearl watermark. The curtains PRINT a saturated accent
    // pigment onto the page (multiply toward the accent), so they can never
    // collapse to near-white and never form muddy gray blobs.
    float v = pow(clamp(dot(acc, vec3(0.45)) * 1.65, 0.0, 1.0), 0.72);
    vec3 ribbon = accentRamp(clamp(0.40 + 0.36 * v + 0.08 * fWarp, 0.0, 1.0));
    // Pull the pigment away from its own luma so the deposit stays saturated.
    float ribbonLuma = dot(ribbon, vec3(0.299, 0.587, 0.114));
    vec3 pigment = clamp(ribbon + (ribbon - vec3(ribbonLuma)) * 0.55, 0.0, 1.0);
    float deposit = v * 0.83 * uIntensity;
    col = uBg * mix(vec3(1.0), pigment, deposit);
    // Filament spines print a second, denser coat so each curtain keeps a core.
    col *= mix(vec3(1.0), pigment * pigment, pow(v, 2.4) * 0.28 * uIntensity);
    // A tiny ink contour keeps the hem readable on pearl without gray mud.
    col = mix(col, uInk, smoothstep(0.10, 0.58, v) * 0.045 * uIntensity);
  }

  // STEP 7 — POINTER HALO (rides the gust; breath drives brightness, hue slowly cycles).
  if (uPointerActive > 0.5) {
    float halo = exp(-dot(toPtr, toPtr) * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.25 * breath * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // STEP 8 — VIGNETTE (tightened to protect glass-type legibility).
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.35 + 0.65 * vig);
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}