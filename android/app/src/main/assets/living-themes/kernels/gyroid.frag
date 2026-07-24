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

uniform float uShellWidth;
uniform float uLevelSet;
uniform float uOrbitSpeed;
uniform float uDensityGain;
uniform float uCamDrift;

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


// ── gyroid — tuning (mirror kernels/gyroid/gyroidMath.ts) ────────────────
const int   MARCH_STEPS     = 40;     // shipped default (proven envelope); 48 is a flagged ceiling (§7)
const int   MARCH_STEPS_CEIL = 48;    // worst-case cap only — perf sub-stream may trial it (NOT a fallback)
const float TMAX        = 6.0;        // bounded march length (the tmax guard)
const float T_CUTOFF    = 0.012;      // transmittance early-out
const float W_FLOOR     = 0.01;       // shell-weight early-out
const float GYR_FREQ    = 0.85;       // lattice scale
const float SIGMA_T     = 1.0;        // extinction
const float SIGMA_S     = 1.1;        // scatter
const float SIGMA_L     = 2.2;        // self-shadow
const float LIGHT_DIST  = 0.55;       // shadow-tap offset
const float HG_G        = 0.45;       // Henyey–Greenstein anisotropy
const float WRAP        = 0.4;        // subsurface wrap-light

// SHELL_SIG0 / MORPH_C0 / ORBIT_SPEED / DENSITY_GAIN / CAM_DRIFT are runtime
// params now: uShellWidth, uLevelSet, uOrbitSpeed, uDensityGain, uCamDrift
// (declared in gyroidKernel.ts; defaults live in gyroidMath.ts).

// Light-orbit geometry (mirror volumetricKernel lightOrbit(); speed = uOrbitSpeed).
const vec3  ORBIT_CENTER = vec3(0.0, 0.35, 2.6);
const vec3  ORBIT_RADIUS = vec3(1.7, 0.55, 0.9);

// ── The gyroid scalar + its analytic gradient (shared transcendentals) ───
float gyroid(vec3 p){
  return sin(p.x)*cos(p.y) + sin(p.y)*cos(p.z) + sin(p.z)*cos(p.x);
}
vec3 gyroidGrad(vec3 p){
  float sx=sin(p.x), cx=cos(p.x);
  float sy=sin(p.y), cy=cos(p.y);
  float sz=sin(p.z), cz=cos(p.z);
  return vec3(cx*cy - sx*sz,   // ∂g/∂x = cos x cos y − sin x sin z
              cy*cz - sx*sy,   // ∂g/∂y = cos y cos z − sin x sin y
              cz*cx - sy*sz);  // ∂g/∂z = cos z cos x − sin y sin z
}

// Gaussian shell weight around the (morphed) level set.
float shellWeight(float g, float sigma, float c){
  float d = (g - c) / sigma;
  return exp(-d*d);
}

// Jimenez interleaved gradient noise — static spatial jitter (banding→grain).
float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}
// Henyey–Greenstein phase.
float hg(float c, float g){
  float g2 = g*g;
  return (1.0-g2)/(12.566370614*pow(max(1.0+g2-2.0*g*c, 1e-3), 1.5));
}

// Slow-orbiting light (pointer pulls XY when active; scroll lifts elevation).
vec3 lightOrbit(float t, vec2 puv, float pActive, float scroll){
  float a = t*uOrbitSpeed;
  vec3 L = ORBIT_CENTER + vec3(
    ORBIT_RADIUS.x*cos(a),
    ORBIT_RADIUS.y*sin(a*0.7) + (scroll-0.5)*0.9,
    ORBIT_RADIUS.z*sin(a*0.4));
  vec2 pp = (puv*uResolution - 0.5*uResolution)/uResolution.y;
  L.xy = mix(L.xy, vec2(pp.x*2.0, pp.y*2.0), pActive*0.85);
  return L;
}

// 1-octave self-shadow tap (no gradient → half the cost of a full sample).
// The dropped 'flow' param was unused; the sample point carries the phase.
float shellShadow(vec3 pos, float sigma, float c){
  float gg = sin(pos.x)*cos(pos.y) + sin(pos.y)*cos(pos.z) + sin(pos.z)*cos(pos.x);
  return shellWeight(gg, sigma, c);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5*uResolution)/uResolution.y;

  // CLOCKS — irrational breath (mirror volumetric); scroll drift (D2 block).
  // Rates are HALF their dead-clock values (frozen-clock retune, see header).
  float sN = uScroll.y > 0.0 ? uScroll.x/uScroll.y : 0.0;
  float breath = mix(0.86, 1.18,
    0.5 + 0.5*(0.62*sin(uTime*0.1122) + 0.38*sin(uTime*0.0507 + 1.3)));
  float drift  = sN*2.5 + uScrollVel*0.06;
  vec3  phase  = vec3(uTime*0.015 + drift, uTime*0.009, uTime*0.010);
  float sigma  = uShellWidth * breath;           // shell breathes (thickness)
  float c      = uLevelSet * (breath - 1.0);     // level-set morphs (the lung)

  // RAY — perspective fan; slow camera-basis drift for parallax past the
  // lattice. A small always-on floor keeps the parallax alive even at page
  // top (the old *sN gate zeroed it unscrolled); scroll still deepens it.
  float ca = cos(uTime*0.015), sa = sin(uTime*0.015);
  vec3  ro = vec3(p*2.0, -3.0);
  vec3  rd = normalize(vec3(p*0.35 + vec2(sa, ca)*uCamDrift*(0.5 + sN), 1.0));

  vec3  Lpos = lightOrbit(uTime, uPointer, uPointerActive, sN);
  float dt   = TMAX / float(MARCH_STEPS);
  float j    = ign(fragCoord);                    // banding → grain

  float T = 1.0, scatter = 0.0, depthLit = 0.0, wsum = 0.0;

  for (int i = 0; i < MARCH_STEPS; i++){
    float t = (float(i) + j)*dt;
    if (t > TMAX) break;                           // bounded depth
    vec3 pos = ro + rd*t;
    float gg = gyroid(pos*GYR_FREQ + phase);
    float wgt= shellWeight(gg, sigma, c);
    if (wgt > W_FLOOR){
      // NaN-safe: clamp the gradient away from zero so a lattice degeneracy
      // (|∇g|≈0) can't produce a NaN normal (gyr2-R3a — mirrors §11 mitigation).
      vec3  grad = gyroidGrad(pos*GYR_FREQ + phase);
      float gl   = length(grad);
      vec3  N    = gl > 1e-4 ? grad/gl : vec3(0.0, 0.0, 1.0);
      vec3  Ldir = normalize(Lpos - pos);
      float occ  = shellShadow(pos*GYR_FREQ + phase + Ldir*LIGHT_DIST, sigma, c);
      float Tl   = exp(-occ*SIGMA_L);
      float powd = 1.0 - exp(-wgt*2.0);            // Beer–Powder
      float ph   = hg(dot(rd, Ldir), HG_G);
      float diff = (dot(N, Ldir) + WRAP)/(1.0 + WRAP); // subsurface wrap
      float s    = T*(wgt*SIGMA_S*uDensityGain)*Tl*powd*ph*diff*dt;
      scatter   += s;
      depthLit  += s*clamp(t/TMAX, 0.0, 1.0);
      wsum      += s;
      T *= exp(-wgt*SIGMA_T*uDensityGain*dt);
      if (T < T_CUTOFF) break;                      // saturated → early-out
    }
  }

  // Faint background haze so the void isn't dead (1-octave snoise, cheap).
  float haze = 0.5 + 0.5*fbm(vec3(p*1.5, uTime*0.025));

  // HUE: depth-keyed + slow iridescence roll (mirror volumetric).
  float hue = clamp((wsum > 0.0 ? depthLit/wsum : 0.5) + 0.10*sin(uTime*0.06), 0.0, 1.0);
  vec3  tint = accentRamp(hue);
  float glow = clamp(scatter, 0.0, 4.0);

  // THEME COMPOSITE (timing identical; only the math flips — mirror volumetric).
  vec3 col;
  if (uTheme < 0.5){
    // DARK: additive luminous lattice over deep ink; filmic knee blooms cores.
    col  = uBg;
    col += mix(uBg, tint, 0.5) * haze * 0.10;       // faint haze floor
    col += tint * glow * (0.9*uIntensity);
    // Hot-core glint: uInk is the light foreground in dark theme, so mixing
    // toward it whitens the cores palette-true (was a hardcoded cool white).
    col += mix(tint, uInk, 0.7) * pow(glow,3.0) * (0.06*uIntensity);
    col  = col/(col + vec3(0.6));
    col *= 1.16;                                     // TONEMAP_KNEE
    col += mix(uInk, tint, 0.35)*(hash21(fragCoord)-0.5)*0.012
           *(1.0 - clamp(glow*1.5,0.0,1.0));         // void grain floor (palette-tinted)
  } else {
    // LIGHT: pearl lattice deposited subtractively (never blow-out).
    float v = pow(clamp(glow*0.7,0.0,1.0),0.8);
    vec3  surf = accentRamp(clamp(hue+0.08,0.0,1.0));
    vec3  pearl= mix(uBg, surf, 0.85);
    col = mix(uBg, pearl, v*0.6*uIntensity);
    col = mix(col, uInk, smoothstep(0.1,0.6,v)*0.04*uIntensity); // soft contour
  }

  // POINTER HALO (the cursor light blooms; breath-gated, mirror volumetric).
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer*uResolution - 0.5*uResolution)/uResolution.y;
    float dd = length(p - pp);
    col += accentRamp(fract(0.5 + uTime*0.04))
           * exp(-dd*dd*4.0)*0.22*breath*(uTheme < 0.5 ? 1.0 : 0.5);
  }

  // VIGNETTE (protect glass-type legibility).
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