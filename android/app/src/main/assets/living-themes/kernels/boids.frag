#version 300 es
precision highp float;
out vec4 fragColor;
uniform vec2 uResolution;
uniform float uTime;
uniform vec2 uPointer;
uniform float uPointerActive;
uniform vec3 uBg;
uniform vec3 uAccent0;
uniform vec3 uAccent1;
uniform vec3 uAccent2;
uniform vec3 uAccent3;
uniform vec3 uInk;
uniform float uIntensity;
uniform float uTheme;

float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 345.45));
  p += dot(p, p + 34.345);
  return fract(p.x * p.y);
}

mat2 rotate2d(float angle) {
  float c = cos(angle);
  float s = sin(angle);
  return mat2(c, -s, s, c);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  const float CELL_PX = 44.0;
  vec2 flockWarp = vec2(
    sin(fragCoord.y * 0.006 + uTime * 0.31),
    cos(fragCoord.x * 0.004 - uTime * 0.24)
  ) * 18.0;
  vec2 grid = (fragCoord + flockWarp + vec2(uTime * 13.0, uTime * 4.0)) / CELL_PX;
  vec2 cell = floor(grid);
  vec2 local = fract(grid) - 0.5;
  float seed = hash21(cell);
  local -= vec2(seed - 0.5, hash21(cell + 7.3) - 0.5) * 0.28;
  float angle = sin(cell.y * 0.37 + uTime * 0.23) * 0.85 + (seed - 0.5) * 1.2;
  local = rotate2d(angle) * local;

  // Two tapered wings and a short body form one velocity-aligned bird per
  // tile. This is deliberately loop-free: visual density scales with pixels,
  // while shader cost remains constant on every phone and power profile.
  float wingDistance = abs(abs(local.x) * 0.34 - local.y);
  float wings = smoothstep(0.075, 0.012, wingDistance) *
    (1.0 - smoothstep(0.27, 0.48, abs(local.x)));
  float body = smoothstep(0.075, 0.015, length(vec2(local.x * 2.8, local.y)));
  float bird = max(wings, body);

  float breath = 0.78 + 0.22 * sin(uTime * 0.29);
  float glow = clamp(bird * breath, 0.0, 1.0);
  vec3 flockTint = mix(uInk, uAccent2, 0.28 + 0.12 * sin(uTime * 0.14));
  vec3 night = vec3(0.008, 0.012, 0.028);
  float skyPulse = 0.03 + 0.02 * sin(uv.y * 9.0 + uTime * 0.17);
  vec3 sky = mix(night, uAccent0 * 0.18, skyPulse);
  return mix(sky, flockTint, glow * uIntensity);
}

void main() {
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / max(uResolution, vec2(1.0));
  fragColor = vec4(clamp(renderKernel(uv, fragCoord), 0.0, 1.0), 1.0);
}
