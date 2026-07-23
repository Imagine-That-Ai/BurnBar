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
  float t = uTime * 0.08;
  vec2 p = uv * 2.0 - 1.0;
  p.x *= uResolution.x / max(uResolution.y, 1.0);
  float field = 0.0;
  for (int i = 0; i < 12; i++) {
    float fi = float(i);
    vec2 c = vec2(sin(fi * 1.7 + t), cos(fi * 1.3 - t * 0.7)) * 0.65;
    float d = length(p - c);
    field += 0.012 / max(d * d, 1e-4);
  }
  return vec3(0.02, 0.03, 0.08) + vec3(0.75, 0.82, 1.0) * field;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / max(uResolution, vec2(1.0));
  vec3 col = renderKernel(uv, fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
