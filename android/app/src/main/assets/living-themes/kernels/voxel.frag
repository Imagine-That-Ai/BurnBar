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


// ── voxel "Quarry" — tuning (mirror kernels/voxel/voxelMath.ts) ──────────────
// Time coefficients are LIVE-CLOCK tuned: this kernel is reactive (controls),
// so until the frozen-clock fix uTime was 0 forever — the authored rates never
// ran. Camera drift is halved (DDA columns strobe past ~0.15 cells/s) and the
// sun crossing is slowed to read cinematic rather than scanning.
const int   MAX_STEPS  = 64;    // DDA cell cap (hard perf ceiling; expected ~14-22)
const float CELL       = 1.0;   // unit lattice
const float SUN_SPEED  = 0.07;  // slow sun crossing top faces (light is the verb)
const float SWELL_PER  = 0.18;  // ~35s swell period (2pi/0.18) — ambient weather
const float CAM_DRIFT  = 0.12;  // camera drift cells/s (live clock; no DDA strobe)
const float RIDGE_LO   = 14.0;  // far-ridge / island band start (cells, +z)
const float RIDGE_HI   = 20.0;  // far-ridge band end
const float CAM_Y      = 9.0;   // camera eye height (GUARD G1: > H_MAX always)
const float TMAX_H     = 70.0;  // horizontal march bound in cells (GUARD G3)
const float H_MAX      = 5.91;  // documented envelope ceiling (keep in sync w/ seaH)
const float TIDE_AMP   = 2.6;   // pointer tide bulge height (cells)
const float TIDE_K     = 0.06;  // tide gaussian sharpness (sigma ~2.9 cells)
const float TIDE_Y     = 0.0;   // sea-level plane the pointer ray is dropped onto

// POINTER TIDE state — seeded once per frame in renderKernel BEFORE the march.
// gTideA stays 0.0 while the pointer is idle, so seaH pays at most ONE gated
// exp per call and idle frames pay none (the perf contract of the height field).
vec2  gTideC = vec2(0.0);       // tide center in cell coords (xz)
float gTideA = 0.0;             // tide amplitude (0 = no pointer)

// Slow voxel-sea height in cell units. ISLAND snoise is SHORT-CIRCUITED outside
// the far band (perf): islands only exist where smoothstep(RIDGE_LO,RIDGE_HI) is
// non-zero, so near cells skip the priciest term entirely. The pointer TIDE is
// scaled by (1-band) — near-field only — so the height envelope stays at H_MAX:
// near-field max = -1 + 2.7 + TIDE_AMP = 4.3 < 5.91 (GUARDS G1/G3 untouched).
float seaH(vec2 c, float drift){
  float swell = 1.6*sin(c.x*0.16 + uTime*SWELL_PER)
              + 1.1*sin(c.y*0.13 - uTime*SWELL_PER*0.7 + 1.3);
  float band  = smoothstep(RIDGE_LO, RIDGE_HI, c.y);   // 0 for c.y<=14, 1 for c.y>=20
  float ridge = 3.0*band;                              // far ridge frames the top
  float isle  = 0.0;
  if (band > 0.0) {                                    // ← snoise gated to far band ONLY
    isle = 2.2*max(0.0, snoise(vec3(c*0.07, uTime*0.05 + drift)) - 0.45) * band;
  }
  float tide = 0.0;
  if (gTideA > 0.0) {                                  // ← one exp, pointer-gated
    vec2 td = c - gTideC;
    tide = gTideA * exp(-dot(td,td)*TIDE_K) * (1.0 - band);
  }
  return -1.0 + swell + ridge + isle + tide;           // sea sits low (framing)
}
bool occ(vec3 cell, float drift){
  if (cell.y >= H_MAX) return false;                   // cheap reject above envelope
  return cell.y < floor(seaH(cell.xz, drift));
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5*uResolution)/uResolution.y;
  float sN    = uScroll.y > 0.0 ? uScroll.x/uScroll.y : 0.0; // NaN-guard (gyroid parity)
  float drift = uScrollVel*0.04;                        // scroll ripples the sea

  // CAMERA — fixed high overlook; scroll dollies forward (+x,+z) into fresh terrain.
  // GUARD G1: ro.y = CAM_Y (9.0) is constant and > H_MAX, so the eye is ALWAYS
  // above terrain regardless of sN; scroll moves only ro.x/ro.z.
  vec3 ro = vec3(uTime*CAM_DRIFT + sN*8.0, CAM_Y, -8.0 + sN*4.0);
  vec3 ta = ro + vec3(p.x*1.4, p.y*1.4 - 1.6, 1.0);    // -1.6 biases rd.y firmly negative
  vec3 rd = normalize(ta - ro);

  // POINTER TIDE — drop the pointer's ray onto the sea plane and swell seaH
  // under it: columns physically RISE beneath the cursor, read through the
  // canonical face shading + 4-corner AO + silhouette rim (not a screen halo).
  if (uPointerActive > 0.001){
    vec2 pq  = (uPointer*uResolution - 0.5*uResolution)/uResolution.y;
    vec3 pd  = normalize(vec3(pq.x*1.4, pq.y*1.4 - 1.6, 1.0)); // same lens as ta
    float tp = (TIDE_Y - ro.y)/min(pd.y, -1e-3);               // pd.y < 0 (the -1.6 bias)
    gTideC = ro.xz + pd.xz*tp;
    gTideA = TIDE_AMP * uPointerActive;                        // host-smoothed ease in/out
  }

  // ── Amanatides-Woo 3D DDA over the implicit voxel grid ────────────────────
  vec3 cell   = floor(ro/CELL);                         // starting cell (provably empty, G1)
  vec3 stp    = sign(rd);
  vec3 tDelta = abs(CELL/(rd + 1e-5));
  vec3 tMax   = (((cell + max(stp,0.0))*CELL) - ro) / (rd + 1e-5);
  vec3 mask   = vec3(0.0,1.0,0.0);                      // entry face; seed = top (G2 safety)
  bool hit = false; float tHit = 0.0;

  // GUARD G2: mask is computed/refreshed at the TOP of the loop, BEFORE occ(),
  // so the very first cell tested already carries a valid entry-face mask.
  for (int i = 0; i < MAX_STEPS; i++){
    if (occ(cell, drift)){ hit = true; break; }         // first occupied = painter winner
    // advance to next cell; mask = which face we cross to enter it (smallest tMax axis)
    mask = step(tMax, tMax.yzx) * step(tMax, tMax.zxy);
    tHit = dot(mask, tMax);
    tMax += mask * tDelta;
    cell += mask * stp;
    // GUARD G3 (early-outs, in cost order):
    if (cell.y > H_MAX && stp.y > 0.0) break;           // escaped above the envelope (sky)
    float horiz = abs(cell.x - ro.x) + abs(cell.z - ro.z);
    if (horiz > TMAX_H) break;                          // horizontal-distance bound
  }

  vec3 col;
  if (hit){
    // Entry-face values: top bright, two DISTINCT sides (never flat).
    float topF = mask.y, sideA = mask.x, sideB = mask.z;
    float shade = topF*1.0 + sideA*0.78 + sideB*0.55;   // G2: mask valid ⇒ shade>0 always
    // Live sun re-shades top faces as it crosses (light is the verb).
    float sun = 0.5 + 0.5*sin(cell.x*0.12 - uTime*SUN_SPEED);
    shade *= mix(1.0, 1.0 + 0.35*sun, topF);

    // ── TRUE 4-CORNER vertex AO (canonical voxel AO) ────────────────────────
    // Two in-plane edge neighbors + the diagonal corner + the vertical seam tap.
    vec3 e1 = abs(mask.y) > 0.5 ? vec3(1,0,0) : vec3(0,1,0); // top→x ; side→y(up)
    vec3 e2 = abs(mask.z) > 0.5 ? vec3(1,0,0) : vec3(0,0,1); // pick the other in-plane axis
    float s1 = float(occ(cell + e1, drift));
    float s2 = float(occ(cell + e2, drift));
    float sc = float(occ(cell + e1 + e2, drift));        // ← diagonal CORNER tap
    float sv = float(occ(cell + vec3(0,1,0), drift));     // ← vertical seam tap
    float ao = 1.0 - 0.22*(s1 + s2 + sc + 0.5*sv) / 2.5; // in [≈0.34, 1.0]

    // ── REAL silhouette rim: the cube's edge against EMPTY space ─────────────
    float openE = (1.0 - float(occ(cell + e1, drift)))
                + (1.0 - float(occ(cell + e2, drift)));
    float rim = clamp(openE, 0.0, 1.0);                  // edge present ⇒ rim

    // Hue keyed by height + slow iridescence; tinted from palette accents.
    float hue = clamp(0.45 + cell.y*0.06 + 0.08*sin(uTime*0.1), 0.0, 1.0);
    vec3  tint = accentRamp(hue);
    float depthFade = exp(-tHit*0.045);                  // far cubes fade to bg

    if (uTheme < 0.5){
      // DARK: additive — seams glow, light leaks, sea reads luminous on ink.
      col  = uBg;
      col += tint * shade * ao * depthFade * (0.9*uIntensity);
      col += mix(uInk, uAccent2, 0.25) * pow(topF*sun,3.0) * 0.06; // top-face glint (ink = cool light on dark)
      col += tint * rim * 0.10 * depthFade;               // real-edge rim (additive)
    } else {
      // LIGHT: opaque deposit ~0.78, top near-white, AO/rim in ink.
      vec3 face = mix(uBg, tint, 0.85);
      face = mix(face, uBg, topF*0.45);                   // top sun-bleached toward page bg
      col  = mix(uBg, face*shade*ao, 0.78*depthFade*uIntensity);
      col  = mix(col, uInk, (1.0-ao)*0.18);               // AO seated in ink
      col  = mix(col, mix(col, uInk, 0.35), rim*0.5);     // crisp dark contour edge
    }
  } else {
    // SKY: faint haze so the void breathes (gyroid's trick), depth-fades down.
    float haze = 0.5 + 0.5*fbm(vec3(p*1.4, uTime*0.04));
    col = mix(uBg, mix(uBg, accentRamp(0.3), 0.10), haze);
  }

  // Faint pointer glow — a whisper of light riding the PHYSICAL tide bulge
  // above (the bulge is the interaction; this just warms its crest).
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer*uResolution - 0.5*uResolution)/uResolution.y;
    col += accentRamp(fract(0.5 + uTime*0.07)) * exp(-dot(p-pp,p-pp)*4.0)
           * 0.08 * (uTheme<0.5?1.0:0.5);
  }
  // VIGNETTE — protect the center where cards/headings live (FRAME, don't shout).
  float vig = smoothstep(1.7, 0.25, length(p));
  col = mix(uBg, col, 0.35 + 0.65*vig);
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}