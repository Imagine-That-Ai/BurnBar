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


// ── Ripple Lattice — breathing accent-dot lattice + cursor sonar ripples ──

// Crisp sonar wavefront: a thin crest line per ring cycle, AA'd with fwidth of
// the phase so the rings read as drawn circles at any DPR (never a sine blur).
float rippleRingLine(float phase) {
  float cyc = abs(fract(phase * 0.15915494 + 0.25) - 0.5);   // 0 on the sin crest (1/2pi + quarter turn)
  float aa  = fwidth(phase) * 0.15915494 + 1e-4;
  return 1.0 - smoothstep(0.012, 0.012 + aa * 1.5, cyc);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 res = uResolution;
  vec2 p = fragCoord;

  // Lattice cell size, clamped so dots stay readable across resolutions.
  float cell = clamp(res.y / 28.0, 18.0, 64.0);

  // Pointer in y-up pixel space (uPointer is 0..1 y-up; fragCoord is y-up).
  vec2 ptr = uPointer * res;
  float d2p = distance(p, ptr) / max(res.y, 1.0);   // normalized pointer distance

  // Concentric sonar ripple + a soft proximity bulge, gated by uPointerActive.
  float phase  = d2p * 18.0 - uTime * 2.6;
  float ripple = sin(phase) * exp(-d2p * 3.2) * uPointerActive;
  float prox   = exp(-d2p * 2.2) * uPointerActive;

  // Wandering phantom source — a noise-driven position on a ~20 s loop pings the
  // same sonar rings at low amplitude, so the lattice speaks even at rest.
  vec2 php = res * (vec2(0.5) + 0.36 * vec2(
      snoise(vec3(uTime * 0.05, 3.1, 7.7)),
      snoise(vec3(9.2, uTime * 0.05, 2.4))));
  float dphp    = distance(p, php) / max(res.y, 1.0);
  float phaseP  = dphp * 18.0 - uTime * 2.6;
  float rippleP = sin(phaseP) * exp(-dphp * 3.2) * 0.35;

  // Radially shove the sampling space outward from each source (the "push").
  vec2 dir  = normalize(p - ptr + vec2(1e-4));
  vec2 dirP = normalize(p - php + vec2(1e-4));
  vec2 sp   = p + (dir * ripple + dirP * rippleP) * cell * 0.6;

  // Slow traveling wave over the lattice (FBM keeps the breathing organic).
  float bgWave = fbm(vec3(sp / cell * 0.16, uTime * 0.14));
  vec2 gid = floor(sp / cell);
  vec2 cuv = fract(sp / cell) - 0.5;
  float wave = 0.5 + 0.5 * sin((gid.x + gid.y) * 0.55 - uTime * 1.4 + bgWave * 2.0);

  // Dot radius breathes with the wave, swells near the cursor + on ripple crests
  // (the phantom's crests swell it too, at its lower amplitude).
  float radius = mix(0.12, 0.32, wave) + prox * 0.20 + (ripple + rippleP) * 0.12;
  radius = max(radius, 0.04);
  float dd = length(cuv);
  // Well-defined smoothstep (edge0 < edge1): 1 inside the dot, 0 outside.
  float dotMask = 1.0 - smoothstep(radius - 0.07, radius, dd);

  // Palette-driven dot color; brighter near the cursor.
  vec3 dotCol = accentRamp(wave * 0.65 + prox * 0.35 + 0.08);

  vec3 col = mix(uBg, mix(uBg, dotCol, 0.9), dotMask);
  // DARK: dots glow additively (bloom near the cursor / on ripple crests).
  col += dotCol * dotMask * (1.0 - uTheme) * (0.22 + prox * 0.55);
  // LIGHT: dots deposit ink onto the warm paper bg (never blows out).
  col = mix(col, mix(col, uInk, dotMask * 0.65), uTheme);
  // Faint accent wash riding the ripple crest (dark only).
  col += accentRamp(0.7) * max(ripple, 0.0) * 0.10 * (1.0 - uTheme);

  // Craft cue: fwidth-crisp sonar wavefronts — thin drawn circles on each ring,
  // full strength from the cursor, low amplitude from the phantom source.
  float rings = rippleRingLine(phase)  * exp(-d2p * 3.2) * uPointerActive
              + rippleRingLine(phaseP) * exp(-dphp * 3.2) * 0.45;
  col += accentRamp(0.82) * rings * 0.30 * (1.0 - uTheme);   // DARK: glow lines
  col  = mix(col, uInk, rings * 0.22 * uTheme);              // LIGHT: inked lines

  col *= uIntensity;

  // Vignette (well-defined form): 1 at center, fades toward the edges.
  float vig = 1.0 - smoothstep(0.32, 0.95, length(uv - 0.5));
  col = mix(uBg * mix(0.62, 1.0, uTheme), col, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}