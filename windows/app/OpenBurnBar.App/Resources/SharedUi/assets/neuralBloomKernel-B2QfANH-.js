import{c as e}from"./createShaderKernel-DZdzJunW.js";import"./index-CeVJulmk.js";const t=`
// ── Neural Bloom — latent FBM → MLP palette → organic colour field ─────────

// Small MLP: 2 inputs (latent x, y) → 4 hidden → 3 outputs (palette mix weights).
// Weights are baked constants (no external texture / uniform buffer needed).
// This is the "generative AI" part: the network shape and weights were tuned
// by iterative prompt-guided search to produce pleasing, non-repeating colour
// fields that map the site's accent palette.

vec3 neuralPalette(vec2 latent, float t) {
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

  // Pointer warp: when active, pull the latent space toward the cursor.
  vec2 warp = p;
  if (uPointerActive > 0.5) {
    vec2 cursor = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    vec2 d = cursor - p;
    float dist = length(d);
    float influence = exp(-dist * dist * 3.5);
    warp += d * influence * 0.35;
  }

  // Latent feature map: two warped FBM channels at different scales.
  float l0 = latentFbm(warp * 1.60 + vec2(t * 1.7, -t * 1.1));
  float l1 = latentFbm(warp * 2.40 + vec2(-t * 1.3,  t * 0.9) + 17.3);
  vec2 latent = vec2(l0, l1);

  // Neural palette mapping.
  vec3 nlp = neuralPalette(latent, uTime);
  float rampT = fract(nlp.x * 0.5 + 0.5 + uTime * 0.018);
  float sat   = clamp(nlp.y, 0.0, 1.0);
  float bri   = clamp(nlp.z, 0.0, 1.0);

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
    outCol += vec3(0.04, 0.05, 0.08) * (1.0 - bloom); // airglow floor
    outCol *= 1.12;
  } else {
    // LIGHT: pearl deposit. The neural colours sit as a soft wash over the
    // paper background, with ink deepening in the brightest blooms.
    float lum = clamp(dot(col, vec3(0.45)) * bloom * 1.4, 0.0, 1.0);
    vec3 pearl = mix(uBg, col, 0.72 * sat);
    outCol = mix(uBg, pearl, lum * 0.55 * uIntensity);
    outCol = mix(outCol, uInk, smoothstep(0.50, 0.92, lum) * 0.04 * uIntensity);
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
`;function a(){return e({id:"neural-bloom",label:"Neural Bloom",body:t})}export{a as createNeuralBloomKernel};
