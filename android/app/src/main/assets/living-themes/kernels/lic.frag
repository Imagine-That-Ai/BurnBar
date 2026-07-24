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
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

vec2 flowDirection(vec2 p, float t) {
  float a = sin(p.y * 2.7 + t * 0.31) + cos(p.x * 2.1 - t * 0.23);
  float b = sin((p.x + p.y) * 1.6 - t * 0.19);
  return normalize(vec2(cos(a + b), sin(a - b)));
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 aspect = vec2(uResolution.x / max(uResolution.y, 1.0), 1.0);
  vec2 p = (uv * 2.0 - 1.0) * aspect;
  vec2 direction = flowDirection(p, uTime);
  float sum = 0.0;
  float weight = 0.0;

  // A compact, texture-free LIC pass. Ten taps in each direction preserve the
  // silky streamline identity while staying practical for an always-on surface.
  for (int i = -10; i <= 10; i++) {
    float fi = float(i);
    float w = 0.5 + 0.5 * cos(3.14159265 * fi / 10.0);
    vec2 samplePoint = fragCoord + direction * fi * 2.15;
    float grain = hash21(floor(samplePoint * 0.72));
    float travelingBand = 0.64 + 0.36 * cos(fi * 0.72 - uTime * 1.8);
    sum += grain * w * travelingBand;
    weight += w;
  }

  float silk = clamp((sum / max(weight, 0.001) - 0.34) * 2.2, 0.0, 1.0);
  float contour = 0.5 + 0.5 * sin(dot(p, vec2(-direction.y, direction.x)) * 13.0);
  vec3 tint = mix(uAccent1, uAccent3, contour);
  vec3 color = mix(uBg, mix(tint, uInk, silk * 0.2), silk * uIntensity);
  float vignette = smoothstep(1.55, 0.2, length(p));
  return mix(uBg, color, 0.46 + 0.54 * vignette);
}

void main() {
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / max(uResolution, vec2(1.0));
  fragColor = vec4(clamp(renderKernel(uv, fragCoord), 0.0, 1.0), 1.0);
}
