import{c as e}from"./createShaderKernel-DZdzJunW.js";import"./index-CeVJulmk.js";const t=`
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  // Normalized coordinates with aspect correction
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float t = uTime * 0.035;

  // ── Layer 1: Large slow-moving anchor blobs ──
  vec2 q1 = p * 1.6;
  // Domain warp for organic distortion
  vec2 w1 = vec2(
    fbm(vec3(q1 + vec2(0.0, 1.7), t * 0.7)),
    fbm(vec3(q1 + vec2(4.3, 2.8), t * 0.7))
  );
  vec2 f1 = q1 + 1.2 * w1;

  // Three anchor points orbiting slowly
  float a1 = 0.0;
  for (int i = 0; i < 3; i++) {
    float fi = float(i);
    vec2 center = vec2(
      sin(t * 0.4 + fi * 2.094) * 0.55,
      cos(t * 0.35 + fi * 2.094) * 0.35
    );
    float d = length(f1 - center);
    // Exponential soft-min blend: layers merge like liquid
    a1 += exp(-d * d * 2.8);
  }
  a1 = clamp(a1, 0.0, 1.0);

  // ── Layer 2: Medium detail blobs ──
  vec2 q2 = p * 2.4 + vec2(3.3, 1.1);
  vec2 w2 = vec2(
    fbm(vec3(q2 * 0.8 + vec2(1.7, 9.2), t * 0.9)),
    fbm(vec3(q2 * 0.8 + vec2(8.3, 2.8), t * 0.9))
  );
  vec2 f2 = q2 + 0.8 * w2;

  float a2 = 0.0;
  for (int i = 0; i < 4; i++) {
    float fi = float(i);
    vec2 center = vec2(
      sin(t * 0.55 + fi * 1.5708 + 1.0) * 0.45,
      cos(t * 0.48 + fi * 1.5708 + 2.0) * 0.4
    );
    float d = length(f2 - center);
    a2 += exp(-d * d * 3.5);
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

  // ── Add luminous highlights at blob crests ──
  float crest = pow(a1, 3.0) * 0.4 + pow(a2, 3.0) * 0.25;
  col += vec3(0.85, 0.9, 1.0) * crest * 0.35;

  // ── Subtle surface sheen from layer 3 ──
  col += vec3(0.7, 0.8, 1.0) * a3 * 0.12;

  // ── Pointer reactive: a soft glow follows the cursor ──
  if (uPointerActive > 0.5) {
    vec2 ptr = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float pd = length(p - ptr);
    float pglow = exp(-pd * pd * 5.0) * 0.25;
    // Pointer tint shifts toward the next accent
    vec3 ptrCol = accentRamp(fract(hueShift + 0.25));
    col += ptrCol * pglow;
  }

  // ── Theme composite ──
  vec3 outCol;
  if (uTheme < 0.5) {
    // Dark: additive glow over deep ink background
    outCol = uBg + col * field * (0.85 * uIntensity);
    // Filmic tonemap to prevent blow-out at blob intersections
    outCol = outCol / (outCol + vec3(0.6)) * 1.25;
    // Airglow grain in the void
    outCol += vec3(0.8, 0.85, 1.0) * (hash21(fragCoord) - 0.5) * 0.012;
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
    outCol += vec3(0.9, 0.92, 1.0) * crest * 0.15 * uIntensity;
  }

  // ── Vignette ──
  float vig = smoothstep(1.4, 0.2, length(p));
  outCol = mix(uBg, outCol, 0.25 + 0.75 * vig);

  return outCol;
}
`;function l(){return e({id:"agent1",label:"Agent 1",body:t})}export{l as createAgent1Kernel};
