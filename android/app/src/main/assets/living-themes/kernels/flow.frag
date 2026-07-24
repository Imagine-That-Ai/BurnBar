#version 300 es
precision highp float;
out vec4 fragColor;
uniform vec2  uResolution;
uniform float uTime;
uniform vec2  uPointer;
uniform float uPointerActive;
uniform vec3  uBg;
uniform vec3  uAccent0;
uniform vec3  uAccent1;
uniform vec3  uAccent2;
uniform vec3  uAccent3;
uniform vec3  uInk;
uniform float uIntensity;
uniform float uTheme;

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float t = uTime * 0.2;
  float a = sin(uv.y * 8.0 + t) * 0.5 + cos(uv.x * 6.0 - t * 0.7) * 0.5;
  float b = sin((uv.x + uv.y) * 10.0 - t);
  vec3 c1 = vec3(0.08, 0.12, 0.28);
  vec3 c2 = vec3(0.2, 0.55, 0.9);
  vec3 c3 = vec3(0.55, 0.3, 0.85);
  return mix(c1, mix(c2, c3, 0.5 + 0.5 * b), 0.45 + 0.35 * a);
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / max(uResolution, vec2(1.0));
  vec3 col = renderKernel(uv, fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
