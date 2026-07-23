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
uniform vec2  uScroll;
uniform float uScrollVel;



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


const float CELL_FREQ = 0.85;
const float CELL_COVERAGE = 0.46;
const float DENSITY_GAIN = 1.6;
const float FLASH_RATE = 0.9;     // Hz of sheet-lightning attempts
const float FLASH_DECAY = 3.2;    // exponential decay of a flash

float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}

// 3-octave fbm (injected snoise + accumulation).
float stormFbm(vec3 q){
  float s = snoise(q)*0.5;
  s += snoise(q*2.03)*0.25;
  s += snoise(q*4.07)*0.125;
  return s; // ~[-0.875, 0.875]
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5*uResolution)/uResolution.y;

  float sN = uScroll.y > 0.0 ? uScroll.x/uScroll.y : 0.0;
  float breath = mix(0.88, 1.12,
    0.5 + 0.5*(0.62*sin(uTime*0.2144) + 0.38*sin(uTime*0.0913 + 1.3)));
  float drift = sN*2.0;
  vec3 flow = vec3(uTime*0.048 + drift, uTime*0.029, uTime*0.033);

  // Pointer = lightning rod: proximity (smooth falloff) thickens the cell
  // and raises the local strike rate below. Computed once, reused everywhere.
  vec2 pp = (uPointer*uResolution - 0.5*uResolution)/uResolution.y;
  vec2 toPtr = p - pp;
  float rod = uPointerActive * exp(-dot(toPtr, toPtr)*3.5);

  // Rolling cell: fbm gated above a coverage threshold; the rod lowers the
  // threshold locally so the cloud mass bunches toward the cursor.
  vec3 q = vec3(p*1.4, 0.0) + flow;
  float raw = stormFbm(q);
  float cell = max(0.0, raw + 0.5 - CELL_COVERAGE + rod*0.28)
             * DENSITY_GAIN * breath;

  // Sheet lightning: a strobe that lights the whole cell from within.
  // Drive it off uTime so every pixel agrees; gate by a per-strobe seed.
  // A second, decorrelated strobe fires more often but only near the rod,
  // its reach scaled by the smooth falloff (no hard iso-edges).
  float strobePhase = uTime*FLASH_RATE;
  float strobeIdx = floor(strobePhase);
  float strobeFrac = strobePhase - strobeIdx;
  float strobeSeed = fract(sin(strobeIdx*12.9898)*43758.5453);
  float strobeAlive = step(0.55, strobeSeed);   // ~45% of attempts fire
  float rodSeed = fract(sin((strobeIdx + 37.0)*12.9898)*43758.5453);
  float rodAlive = step(0.30, rodSeed);         // rod strikes ~70% of attempts
  float flash = (strobeAlive + rod*rodAlive*1.4)
              * exp(-strobeFrac*FLASH_DECAY) * cell;

  vec3 tint = accentRamp(0.5 + 0.05*sin(uTime*0.1));
  vec3 hot  = accentRamp(0.72);

  vec3 col;
  if (uTheme < 0.5){
    // DARK: charged slate + electric-blue in-scatter, filmic knee.
    col  = uBg;
    col += tint*cell*0.55*uIntensity;
    col += hot*flash*1.6*uIntensity;
    col += mix(vec3(1.0), tint, 0.6)*(ign(fragCoord)-0.5)*0.012*(1.0-cell);
    col = col/(col+vec3(0.6));
    col *= 1.16;
  } else {
    // LIGHT: cool wash, flash reads as a pale brightening.
    float v = pow(clamp(cell*0.7, 0.0, 1.0), 0.85);
    vec3 pearl = mix(uBg, tint, 0.6);
    col = mix(uBg, pearl, v*0.4*uIntensity);
    col = mix(col, hot, clamp(flash*0.6, 0.0, 1.0)*0.25*uIntensity);
    col = mix(col, uInk, smoothstep(0.1, 0.6, v)*0.03*uIntensity);
  }

  // Pointer halo: a charged glow at the rod's tip, brightening with strikes.
  col += hot*rod*(0.16 + flash*0.35)*breath*(uTheme < 0.5 ? 1.0 : 0.5);

  float vig = smoothstep(1.6, 0.2, length(p));
  col = mix(uBg, col, 0.4 + 0.6*vig);
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}