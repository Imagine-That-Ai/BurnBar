/**
 * CloudField kernel — "Tiny Clouds" demoscene port.
 *
 * A full-screen volumetric cloudscape raymarched in a single fragment shader.
 * Adapted from stubbe's 280-character ShaderToy prod (SH17A) which achieves
 * photorealistic cloud fly-through with a 10-line, 4-octave FBM kernel.
 *
 * The trick: backwards raymarch + signed-distance cloud surface + 4 octaves of
 * bilinear white-noise sampled as 2D FBM, with alpha-blending density derived
 * from vertical penetration depth. The original needs a white-noise texture;
 * we replace it with an inline hash so the kernel is fully self-contained.
 *
 * Pure fragment shader via {@link createShaderKernel}; no per-frame JS.
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
// ── Inline white-noise hash (replaces the original iChannel0 texture) ─────
float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// Bilinear-interpolated white noise at uv (mimics texture(iChannel0, uv).y).
float noiseTex(vec2 uv) {
  vec2 i = floor(uv);
  vec2 f = fract(uv);
  f = f * f * (3.0 - 2.0 * f); // smoothstep for bilinear feel
  float a = hash12(i);
  float b = hash12(i + vec2(1.0, 0.0));
  float c = hash12(i + vec2(0.0, 1.0));
  float d = hash12(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// 4-octave FBM — the original T macro expanded and inlined.
	float fbmCloud(vec4 p, float t) {
  float s = 2.0;
  float sum = 0.0;
  for (int i = 0; i < 4; i++) {
    // Map 3D position to 2D UV (original used ceil(s*p.x) for depth axis).
    vec2 uv = (s * p.zw + ceil(s * p.x)) / 200.0;
    sum += noiseTex(uv) / (s * 4.0);
    s *= 2.0;
  }
  return sum;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  // Aspect-correct pixel coordinates (original: x/iResolution.y - .8).
  vec2 x = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // Sky colour (original c = vec4(.6,.7,d) where d.zw = x - .8).
  vec3 sky = vec3(0.6, 0.7, 0.8);
  sky -= x.y; // vertical gradient: darker top, lighter bottom

  // Ray direction: .8 forward, x.y screen axes.
  vec4 d = vec4(0.8, 0.0, x.x, x.y);

  // Cloud colour: white tinted by reversed sky (original c.zyxw).
  vec3 cloudTint = vec3(sky.b, sky.g, sky.r);

  vec3 col = sky;

  // Back-to-front raymarch (200 steps, original t = 2e2 + sin(dot(x,x))).
  float jitter = sin(dot(x, x));
  for (float t = 200.0 + jitter; t > 0.0; t -= 1.0) {
    vec4 p = vec4(0.05 * t * d.xyz, 0.05 * t * d.w);
    p.xz += uTime; // camera drift forward + right

    float s = 2.0;
    float f = p.w + 1.0; // height + camera lift

    // Inline the original T macro: 4 octaves of noise.
    for (int i = 0; i < 4; i++) {
      vec2 uv = (s * p.zw + ceil(s * p.x)) / 200.0;
      f -= noiseTex(uv) / (s * 4.0);
      s *= 2.0;
    }

    if (f < 0.0) {
      // Alpha blend: lerp(col, white - density * reversedSky, -f * 0.4).
      // Expanded from original: O += (O - 1. - f*c.zyxw) * f * .4
      vec3 cloudCol = vec3(1.0) + f * cloudTint;
      float density = -f * 0.4;
      col = mix(col, cloudCol, density);
    }
  }

  // Theme adaptation: the original is inherently "daytime sky".
  // Dark theme: treat as a moonlit night cloudscape by desaturating and
  // deepening, then adding a subtle blue bias.
  if (uTheme < 0.5) {
    col = col * 0.35 + vec3(0.05, 0.06, 0.12); // deep night base
    col += accentRamp(0.65) * dot(col, vec3(0.3)) * 0.25; // moon-tinted
    col = col / (col + vec3(0.5)); // filmic knee
    col *= 1.1;
  } else {
    // Light theme: warm the sky slightly toward the pearl backdrop.
    col = mix(col, uBg, 0.15);
    col = mix(col, accentRamp(0.35), 0.08 * uIntensity);
  }

  // Gentle vignette.
  float vig = smoothstep(1.4, 0.25, length(x));
  col = mix(uBg, col, 0.3 + 0.7 * vig);
  return col;
}
`;

export function createCloudFieldKernel(): Kernel {
  return createShaderKernel({
    id: "cloudfield",
    label: "Cloud Field",
    body: BODY,
  });
}
