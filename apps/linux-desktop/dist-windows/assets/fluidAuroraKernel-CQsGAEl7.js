import{c as e}from"./createShaderKernel-DNT32VLs.js";import"./index-PmASUbTN.js";const o=`
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  // Normalised centred coordinates, y-up, aspect-correct.
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // ── Time clocks (multi-frequency so the loop never visually repeats) ──
  float t  = uTime * 0.05;   // master drift
  float t2 = uTime * 0.023;  // slower hue roll

  // ── Domain warp: two layers of fbm advection ──
  // q = first warp field, r = second warp field, f = final scalar warp.
  vec2 q = vec2(
    fbm(vec3(p * 1.6, t)),
    fbm(vec3(p * 1.6 + 5.2, t)));
  vec2 r = vec2(
    fbm(vec3(p * 1.6 + 1.3 * q + vec2(1.7, 9.2), t * 1.1)),
    fbm(vec3(p * 1.6 + 1.3 * q + vec2(8.3, 2.8), t * 1.1)));
  float f = fbm(vec3(p * 1.6 + 1.5 * r, t * 0.9));
  vec2 flow = 1.5 * r + 0.6 * q;

  // ── Three layered curtains (pure trig, zero extra noise) ──
  vec3 acc = vec3(0.0);
  for (int i = 0; i < 3; i++) {
    float di = float(i);
    float depth = 1.0 - 0.30 * di;
    float lt = t * (1.0 + 0.22 * di) + di * 2.39996; // golden-angle offset
    vec2 lp = p * (1.0 - 0.14 * di);
    lp.x += t2 * (1.0 + 0.2 * di) * 1.4;

    float x = lp.x * 3.0 + flow.x * (1.1 * depth) + lt;
    float hgt = lp.y * 1.3 + f * 0.85 + flow.y * 0.45;

    // Cheap fractal filaments (3 octaves abs(sin)) — no extra snoise.
    float fil = 0.0, amp = 1.0, fq = 1.0;
    for (int k = 0; k < 3; k++) {
      fil += amp * abs(sin(x * fq + hgt * 1.2));
      fq *= 2.2;
      amp *= 0.5;
    }
    fil *= 0.571;

    float edge = smoothstep(0.0, 1.0, fil);
    float core = 1.0 - edge;
    core = core * core * (3.0 - 2.0 * core); // smootherstep
    float glow = core * core;

    // Vertical envelope (fade top/bottom for legibility).
    float env = smoothstep(-1.1, -0.2, lp.y) * smoothstep(1.2, 0.1, lp.y);

    // Altitude-keyed hue via the shared accent ramp.
    float hue = clamp(0.5 + hgt * 0.5 + 0.1 * f + di * 0.05, 0.0, 1.0);
    vec3 accent = accentRamp(hue);

    float lum = glow * env;
    acc += accent * lum * (0.60 / (1.0 + 0.45 * di));
    acc += vec3(0.7, 0.85, 1.0) * pow(glow, 4.0) * env * 0.16 * (1.0 - 0.25 * di);
  }

  // ── Theme composite (identical timing, math flips for light) ──
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: additive over deep ink, filmic knee bloom.
    col = uBg;
    col += acc * (0.95 * uIntensity);
    col = col / (col + vec3(0.55));
    col *= 1.18;
  } else {
    // LIGHT: pearl watermark — soft, never muddy.
    col = uBg;
    float v = pow(clamp(dot(acc, vec3(0.45)) * 1.6, 0.0, 1.0), 0.72);
    vec3 ribbon = accentRamp(clamp(0.40 + 0.36 * v + 0.08 * f, 0.0, 1.0));
    vec3 pearl = mix(uBg, ribbon, 0.88);
    col = mix(col, pearl, v * 0.58 * uIntensity);
    col = mix(col, uInk, smoothstep(0.10, 0.58, v) * 0.04 * uIntensity);
    col = mix(col, ribbon, pow(v, 2.4) * 0.16 * uIntensity);
  }

  // ── Pointer halo (subtle, breath-cycled) ──
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.22 * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // ── Vignette (protects text legibility) ──
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.35 + 0.65 * vig);
  return col;
}
`;function c(){return e({id:"fluid-aurora",label:"Fluid Aurora",body:o})}export{c as createFluidAuroraKernel};
