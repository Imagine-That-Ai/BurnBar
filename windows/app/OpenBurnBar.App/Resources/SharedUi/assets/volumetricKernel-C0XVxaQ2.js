import{c as t}from"./createShaderKernel-DZdzJunW.js";import"./index-CeVJulmk.js";const o=`
// ── Tuning (mirror volumetricMath.ts) ────────────────────────────────────
const int   MARCH_STEPS  = 32;
const float MARCH_LEN     = 7.0;
const float T_CUTOFF      = 0.012;
const float FREQ          = 0.85;
const float COVERAGE      = 0.52;
const float DENSITY_GAIN  = 1.7;
const float SIGMA_T       = 1.0;
const float SIGMA_S       = 1.1;
const float SIGMA_L       = 2.2;
const float LIGHT_DIST    = 0.55;
const float HG_G          = 0.45;
// Light-orbit geometry (mirror lightOrbit() in volumetricMath.ts).
const float ORBIT_SPEED   = 0.06;
const vec3  ORBIT_CENTER  = vec3(0.0, 0.35, 2.6);
const vec3  ORBIT_RADIUS  = vec3(1.7, 0.55, 0.9);

// 2-octave inline fbm (cheaper than the injected 3-octave for the hot loop).
float fbm2(vec3 q){
  float s = snoise(q) * 0.5;
  s += snoise(q * 2.0) * 0.25;
  return s; // ~[-0.75, 0.75]
}

// Jimenez interleaved gradient noise — static spatial jitter (no time term).
float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}

// Henyey–Greenstein phase.
float hg(float c, float g){
  float g2 = g * g;
  return (1.0 - g2) / (12.566370614 * pow(max(1.0 + g2 - 2.0 * g * c, 1e-3), 1.5));
}

// Slow-orbiting light. Pointer pulls XY when active; scroll lifts elevation.
vec3 lightOrbit(float t, vec2 puv, float pActive, float scroll){
  float a = t * ORBIT_SPEED;
  vec3 L = ORBIT_CENTER + vec3(
    ORBIT_RADIUS.x * cos(a),
    ORBIT_RADIUS.y * sin(a * 0.7) + (scroll - 0.5) * 0.9,   // scroll → elevation
    ORBIT_RADIUS.z * sin(a * 0.4));
  // Pointer (already inertia-smoothed by the factory) illuminates: pull XY.
  vec2 pp = (puv * uResolution - 0.5 * uResolution) / uResolution.y;
  L.xy = mix(L.xy, vec2(pp.x * 2.0, pp.y * 2.0), pActive * 0.85);
  return L;
}

float densityAt(vec3 pos, vec3 flow, float breath){
  float raw = fbm2(pos * FREQ + flow);
  float d = max(0.0, raw + 0.5 - COVERAGE);
  return d * DENSITY_GAIN * breath;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // CLOCKS. Irrational-ratio breath (never visibly loops); scroll drift.
  // Scroll from the shared D2 control block: uScroll is vec2 (offsetPx, yMax),
  // uScrollVel is px/frame. Normalize to 0..1 here (host gives no normalized form).
  float sN = uScroll.y > 0.0 ? uScroll.x / uScroll.y : 0.0;   // 0..1 scroll position
  float breath = mix(0.86, 1.18,
    0.5 + 0.5 * (0.62 * sin(uTime * 0.2244) + 0.38 * sin(uTime * 0.1013 + 1.3)));
  float drift  = sN * 2.5 + uScrollVel * 0.06;        // scroll drifts medium
  vec3  flow   = vec3(uTime * 0.030 + drift, uTime * 0.018, uTime * 0.020);

  // RAY. Gentle perspective fan so shafts diverge from the light.
  vec3 ro = vec3(p * 2.0, -3.0);
  vec3 rd = normalize(vec3(p * 0.35, 1.0));

  vec3  Lpos = lightOrbit(uTime, uPointer, uPointerActive, sN);
  float dt   = MARCH_LEN / float(MARCH_STEPS);
  float j    = ign(fragCoord);                            // banding → grain

  float T = 1.0;            // running transmittance
  float scatter = 0.0;      // accumulated in-scatter (scalar; tinted later)
  float depthLit = 0.0;     // weighted mean depth of lit samples (for hue)
  float wsum = 0.0;

  for (int i = 0; i < MARCH_STEPS; i++){
    float t   = (float(i) + j) * dt;
    vec3  pos = ro + rd * t;
    float d   = densityAt(pos, flow, breath);
    if (d > 0.001){
      vec3  Ldir = normalize(Lpos - pos);
      float occ  = densityAt(pos + Ldir * LIGHT_DIST, flow, breath); // 1 light tap
      float Tl   = exp(-occ * SIGMA_L);
      float powd = 1.0 - exp(-d * 2.0);                   // Beer–Powder
      float ph   = hg(dot(rd, Ldir), HG_G);
      float s    = T * (d * SIGMA_S) * Tl * powd * ph * dt;
      scatter   += s;
      depthLit  += s * clamp(t / MARCH_LEN, 0.0, 1.0);
      wsum      += s;
      T *= exp(-d * SIGMA_T * dt);
      if (T < T_CUTOFF) break;                            // early ray termination
    }
  }

  // HUE: shaft color keyed to mean lit depth + a slow iridescence roll.
  float hue = clamp((wsum > 0.0 ? depthLit / wsum : 0.5)
                    + 0.10 * sin(uTime * 0.12), 0.0, 1.0);
  vec3  tint = accentRamp(hue);
  float glow = clamp(scatter, 0.0, 4.0);

  // THEME COMPOSITE (timing identical; only the math flips).
  vec3 col;
  if (uTheme < 0.5){
    // DARK: additive shafts over deep ink, filmic knee blooms cores to white.
    col  = uBg;
    col += tint * glow * (0.9 * uIntensity);
    col += vec3(0.75, 0.85, 1.0) * pow(glow, 3.0) * 0.06;  // hot core whitening
    col  = col / (col + vec3(0.6));
    col *= 1.16;                                          // TONEMAP_KNEE
    // Faint grain floor in the void (dark only) instead of dead black.
    col += vec3(0.8, 0.85, 1.0) * (hash21(fragCoord) - 0.5)
           * 0.012 * (1.0 - clamp(glow * 1.5, 0.0, 1.0));
  } else {
    // LIGHT: pale luminous columns deposited subtractively (no blow-out).
    float v = pow(clamp(glow * 0.7, 0.0, 1.0), 0.8);
    vec3  shaft = accentRamp(clamp(hue + 0.08, 0.0, 1.0));
    vec3  pearl = mix(uBg, shaft, 0.85);
    col = mix(uBg, pearl, v * 0.6 * uIntensity);
    col = mix(col, uInk, smoothstep(0.1, 0.6, v) * 0.04 * uIntensity); // soft contour
  }

  // POINTER HALO (illuminated source bloom; breath-coupled liveliness).
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    col += accentRamp(fract(0.5 + uTime * 0.08))
           * exp(-dd * dd * 4.0) * 0.22 * breath * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // VIGNETTE (protect glass-type legibility).
  float vig = smoothstep(1.6, 0.2, length(p));
  col = mix(uBg, col, 0.4 + 0.6 * vig);
  return col;
}
`;function i(){return t({id:"volumetric",label:"Volumetric",body:o,controls:["scroll"]})}export{i as createVolumetricKernel};
