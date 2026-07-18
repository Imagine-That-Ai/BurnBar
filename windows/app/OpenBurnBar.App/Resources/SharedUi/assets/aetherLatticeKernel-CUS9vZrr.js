import{c as e}from"./createShaderKernel-DZdzJunW.js";import{Q as t,a as o,b as l}from"./quasicrystalWaves-BD0dAad5.js";import"./index-CeVJulmk.js";const a=`
// ── Aether Lattice — tuning (hybrid volumetric + quasicrystal) ──────────
// Mobile perf note: reduce MARCH_STEPS to 20 for 30-45fps on mid-tier Android.
const int   MARCH_STEPS  = 32;
const float MARCH_LEN    = 7.0;
const float T_CUTOFF     = 0.012;
const float W_FLOOR      = 0.01;   // QC-density early-out
const float SIGMA_T      = 1.0;    // extinction
const float SIGMA_S      = 1.1;    // scatter
const float SIGMA_L      = 2.2;    // self-shadow
const float LIGHT_DIST   = 0.55;   // shadow-tap offset
const float HG_G         = 0.45;   // Henyey–Greenstein anisotropy
const float QC_SPIN      = 0.012;  // basis-rotation clock
const float QC_SCRUB     = 0.05;   // global phase-drift clock
const float QC_PI        = 3.14159265;

// Light-orbit geometry (mirror volumetricKernel lightOrbit()).
const float ORBIT_SPEED  = 0.06;
const vec3  ORBIT_CENTER = vec3(0.0, 0.35, 2.6);
const vec3  ORBIT_RADIUS = vec3(1.7, 0.55, 0.9);

// ── Quasicrystal density field (3D) ─────────────────────────────────────
// Returns a scalar in ~[-1, 1] used to modulate volumetric density.
float quasicrystal3D(vec3 pos, float freq, float spin, float scrub){
  float q = 0.0;
  for (int j = 0; j < ${t}; j++){
    float a  = QC_PI * float(j) / float(${t}) + spin;
    vec3  k  = vec3(cos(a), sin(a), 0.0) * freq; // 2D wave basis extended into Z
    float ph = float(j) * ${o.toFixed(10)};
	    q += cos(dot(k, pos) + ph + scrub);
  }
  q /= float(${t});
  return q;
}

// 2-octave inline fbm for the flow/drift term (cheaper than injected 3-octave).
float fbm2_qc(vec3 q){
  float s = snoise(q) * 0.5;
  s += snoise(q * 2.0) * 0.25;
  return s;
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
    ORBIT_RADIUS.y * sin(a * 0.7) + (scroll - 0.5) * 0.9,
    ORBIT_RADIUS.z * sin(a * 0.4));
  vec2 pp = (puv * uResolution - 0.5 * uResolution) / uResolution.y;
  L.xy = mix(L.xy, vec2(pp.x * 2.0, pp.y * 2.0), pActive * 0.85);
  return L;
}

// Density at a point: quasicrystal modulated by fbm flow + breath.
float densityAt(vec3 pos, float freq, float spin, float scrub, vec3 flow, float breath){
  float qc = quasicrystal3D(pos, freq, spin, scrub);
  // Shift and scale QC into a positive density with soft clamping.
  float d = max(0.0, qc * 0.5 + 0.5 - 0.48); // threshold tuned for lacy shafts
  // Add low-frequency fbm drift so the lattice breathes and warps.
  float drift = fbm2_qc(pos * 0.7 + flow) * 0.25 + 0.75;
  return d * drift * breath * 1.6;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // CLOCKS. Irrational-ratio breath; scroll drift (D2 control block).
  float sN = uScroll.y > 0.0 ? uScroll.x / uScroll.y : 0.0;
  float breath = mix(0.86, 1.18,
    0.5 + 0.5 * (0.62 * sin(uTime * 0.2244) + 0.38 * sin(uTime * 0.1013 + 1.3)));
  float drift  = sN * 2.5 + uScrollVel * 0.06;
  vec3  flow   = vec3(uTime * 0.030 + drift, uTime * 0.018, uTime * 0.020);
  float spin   = uTime * QC_SPIN;
  float scrub  = uTime * QC_SCRUB;
  float freq   = ${l.toFixed(1)} * (0.9 + 0.2 * breath);

  // RAY. Gentle perspective fan so shafts diverge from the light.
  vec3 ro = vec3(p * 2.0, -3.0);
  vec3 rd = normalize(vec3(p * 0.35, 1.0));

  vec3  Lpos = lightOrbit(uTime, uPointer, uPointerActive, sN);
  float dt   = MARCH_LEN / float(MARCH_STEPS);
  float j    = ign(fragCoord); // banding → grain

  float T = 1.0;
  float scatter = 0.0;
  float depthLit = 0.0;
  float wsum = 0.0;

  for (int i = 0; i < MARCH_STEPS; i++){
    float t   = (float(i) + j) * dt;
    vec3  pos = ro + rd * t;
    float d   = densityAt(pos, freq, spin, scrub, flow, breath);
    if (d > W_FLOOR){
      vec3  Ldir = normalize(Lpos - pos);
      float occ  = densityAt(pos + Ldir * LIGHT_DIST, freq, spin, scrub, flow, breath);
      float Tl   = exp(-occ * SIGMA_L);
      float powd = 1.0 - exp(-d * 2.0); // Beer–Powder
      float ph   = hg(dot(rd, Ldir), HG_G);
      float s    = T * (d * SIGMA_S) * Tl * powd * ph * dt;
      scatter   += s;
      depthLit  += s * clamp(t / MARCH_LEN, 0.0, 1.0);
      wsum      += s;
      T *= exp(-d * SIGMA_T * dt);
      if (T < T_CUTOFF) break; // early ray termination
    }
  }

  // HUE: shaft color keyed to mean lit depth + slow iridescence roll.
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
    col += vec3(0.75, 0.85, 1.0) * pow(glow, 3.0) * 0.06; // hot core whitening
    col  = col / (col + vec3(0.6));
    col *= 1.16; // TONEMAP_KNEE
    col += vec3(0.8, 0.85, 1.0) * (hash21(fragCoord) - 0.5)
           * 0.012 * (1.0 - clamp(glow * 1.5, 0.0, 1.0));
  } else {
    // LIGHT: pale luminous columns deposited subtractively (no blow-out).
    float v = pow(clamp(glow * 0.7, 0.0, 1.0), 0.8);
    vec3  shaft = accentRamp(clamp(hue + 0.08, 0.0, 1.0));
    vec3  pearl = mix(uBg, shaft, 0.85);
    col = mix(uBg, pearl, v * 0.6 * uIntensity);
    col = mix(col, uInk, smoothstep(0.1, 0.6, v) * 0.04 * uIntensity);
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
`;function s(){return e({id:"aether-lattice",label:"Aether Lattice",body:a,controls:["scroll"]})}export{s as createAetherLatticeKernel};
