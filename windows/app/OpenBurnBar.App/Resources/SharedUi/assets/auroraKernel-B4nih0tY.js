import{c as e}from"./createShaderKernel-DZdzJunW.js";import"./index-CeVJulmk.js";const t=`
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
    acc += vec3(0.7, 0.85, 1.0) * pow(glow, 4.0) * env * 0.18 * (1.0 - 0.3 * di); // whiter-than-accent hot cores
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
    // Airglow grain floor (dark only): quietness in the void instead of dead black.
    col += vec3(0.8, 0.85, 1.0) * (hash21(fragCoord) - 0.5) * 0.015 * (1.0 - clamp(totalLum * 2.0, 0.0, 1.0));
  } else {
    // LIGHT: visible pearl aurora. The old watermark math was too polite and
    // collapsed to near-white on the lab pages; keep it soft, but make the
    // ribbons read as real cyan/violet/rose curtains.
    col = uBg;
    float v = pow(clamp(dot(acc, vec3(0.45)) * 1.65, 0.0, 1.0), 0.72);
    vec3 ribbon = accentRamp(clamp(0.40 + 0.36 * v + 0.08 * fWarp, 0.0, 1.0));
    vec3 pearl = mix(uBg, ribbon, 0.88);
    col = mix(col, pearl, v * 0.62 * uIntensity);
    // A tiny ink component gives the soft curtains a contour on pearl without
    // turning them into muddy gray blobs.
    col = mix(col, uInk, smoothstep(0.10, 0.58, v) * 0.045 * uIntensity);
    col = mix(col, ribbon, pow(v, 2.4) * 0.18 * uIntensity);
  }

  // STEP 7 — POINTER (keep the halo; multiply by breath for liveliness, hue slowly cycles).
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.25 * breath * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // STEP 8 — VIGNETTE (tightened to protect glass-type legibility).
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.35 + 0.65 * vig);
  return col;
}
`;function l(){return e({id:"aurora",label:"Aurora",body:t})}export{l as createAuroraKernel};
