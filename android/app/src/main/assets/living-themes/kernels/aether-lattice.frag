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


// ── Aether Lattice — tuning (hybrid volumetric + quasicrystal) ──────────
// Mobile perf note: reduce MARCH_STEPS to 20 for 30-45fps on mid-tier Android.
const int   MARCH_STEPS  = 32;
const float MARCH_LEN    = 7.0;
const float T_CUTOFF     = 0.012;
const float W_FLOOR      = 0.02;   // QC-density early-out (tightened for perf)
const float SHADOW_EPS   = 0.05;   // min density before the shadow tap is worth it
const float SIGMA_T      = 1.0;    // extinction
const float SIGMA_S      = 1.1;    // scatter
const float SIGMA_L      = 1.6;    // self-shadow (eased so dense shafts keep interior detail)
const float LIGHT_DIST   = 0.55;   // shadow-tap offset
const float HG_G         = 0.45;   // Henyey–Greenstein anisotropy
// Clock coefficients were authored against the frozen reactive-path clock
// (uTime==0); re-tuned at half value now that the display clock is live, so
// the aperiodic shafts drift instead of churning.
const float QC_SPIN      = 0.006;  // basis-rotation clock
const float QC_SCRUB     = 0.025;  // global phase-drift clock
const float QC_PI        = 3.14159265;

// Light-orbit geometry (mirror volumetricKernel lightOrbit()).
const float ORBIT_SPEED  = 0.03;
const vec3  ORBIT_CENTER = vec3(0.0, 0.35, 2.6);
const vec3  ORBIT_RADIUS = vec3(1.7, 0.55, 0.9);

// ── Quasicrystal density field (3D) ─────────────────────────────────────
// Returns a scalar in ~[-1, 1] used to modulate volumetric density.
float quasicrystal3D(vec3 pos, float freq, float spin, float scrub){
  float q = 0.0;
  for (int j = 0; j < 7; j++){
    float a  = QC_PI * float(j) / float(7) + spin;
    vec3  k  = vec3(cos(a), sin(a), 0.0) * freq; // 2D wave basis extended into Z
    float ph = float(j) * 2.3999632297;
    q += cos(dot(k, pos) + ph + scrub);
  }
  q /= float(7);
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

// Slow-orbiting light; scroll lifts elevation. The (inertially smoothed)
// pointer tilts the orbit axis — the light banks toward the finger and swings
// forward in Z, so every scattered shaft physically leans toward the cursor
// while the orbit keeps breathing underneath.
vec3 lightOrbit(float t, vec2 puv, float pActive, float scroll){
  float a = t * ORBIT_SPEED;
  vec3 L = ORBIT_CENTER + vec3(
    ORBIT_RADIUS.x * cos(a),
    ORBIT_RADIUS.y * sin(a * 0.7) + (scroll - 0.5) * 0.9,
    ORBIT_RADIUS.z * sin(a * 0.4));
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 lean = (puv - 0.5) * vec2(aspect, 1.0) * (2.4 * pActive);
  L.xy += lean;
  L.z  -= length(lean) * 0.5;
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
    0.5 + 0.5 * (0.62 * sin(uTime * 0.1122) + 0.38 * sin(uTime * 0.0507 + 1.3)));
  float drift  = sN * 2.5 + uScrollVel * 0.06;
  vec3  flow   = vec3(uTime * 0.015 + drift, uTime * 0.009, uTime * 0.010);
  float spin   = uTime * QC_SPIN;
  float scrub  = uTime * QC_SCRUB;
  float freq   = 9.0 * (0.9 + 0.2 * breath);

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
      // Self-shadow tap only where the primary density can carry it — thin
      // fringe samples skip the second densityAt (the march's heaviest cost).
      float Tl   = 1.0;
      if (d > SHADOW_EPS){
        float occ = densityAt(pos + Ldir * LIGHT_DIST, freq, spin, scrub, flow, breath);
        Tl = exp(-occ * SIGMA_L);
      }
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
                    + 0.10 * sin(uTime * 0.06), 0.0, 1.0);
  vec3  tint = accentRamp(hue);
  float glow = clamp(scatter, 0.0, 3.0); // eased clamp keeps dense-core structure

  // THEME COMPOSITE (timing identical; only the math flips).
  vec3 col;
  if (uTheme < 0.5){
    // DARK: additive shafts over deep ink, filmic knee blooms cores to white.
    vec3 hot = mix(vec3(1.0), uAccent3, 0.35); // palette-tinted core whitening
    col  = uBg;
    col += tint * glow * (0.9 * uIntensity);
    col += hot * pow(glow, 3.0) * 0.05;
    col  = col / (col + vec3(0.6));
    col *= 1.16; // TONEMAP_KNEE
    col += mix(vec3(1.0), uAccent2, 0.4) * (hash21(fragCoord) - 0.5)
           * 0.012 * (1.0 - clamp(glow * 1.5, 0.0, 1.0));
  } else {
    // LIGHT: pale luminous columns deposited subtractively (no blow-out).
    float v = pow(clamp(glow * 0.7, 0.0, 1.0), 0.8);
    vec3  shaft = accentRamp(clamp(hue + 0.08, 0.0, 1.0));
    vec3  pearl = mix(uBg, shaft, 0.85);
    col = mix(uBg, pearl, v * 0.6 * uIntensity);
    // Ink deposit deepens with density so dense shafts keep a readable core
    // instead of washing out at the mix ceiling.
    col = mix(col, uInk, smoothstep(0.25, 1.0, v) * 0.10 * uIntensity);
  }

  // POINTER HALO (illuminated source bloom; breath-coupled liveliness).
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    col += accentRamp(fract(0.5 + uTime * 0.04))
           * exp(-dd * dd * 4.0) * 0.22 * breath * (uTheme < 0.5 ? 1.0 : 0.5);
  }

  // VIGNETTE (protect glass-type legibility).
  float vig = smoothstep(1.6, 0.2, length(p));
  col = mix(uBg, col, 0.4 + 0.6 * vig);
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}