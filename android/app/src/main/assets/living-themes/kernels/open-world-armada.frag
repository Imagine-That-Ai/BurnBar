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

uniform float uWarp;
uniform float uSeed;

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


const int   SHIP_DDA_STEPS = 78;
const int   MAX_SHIPS      = 8;
const float VOX_CELL       = 0.048;
const float STATIC_SN      = 0.72;

// ── Tiny helpers (hash21 injected — never redefine) ─────────────────────────
float hash11(float n){ return fract(sin(n) * 43758.5453123); }
float hash31(vec3 p){ return hash21(p.xy + p.z * vec2(17.13, 9.71)); }
vec3  hash33(vec3 p){
  return vec3(
    hash21(p.xy + p.z),
    hash21(p.yz + p.x * 19.1),
    hash21(p.zx + p.y * 37.7)
  );
}
float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}
// CPU twin: seedUnit() in openWorldArmadaMath.ts — keep in sync.
float seedN(float i){
  return fract(sin(uSeed * 0.0007919 + i * 19.19) * 43758.5453123);
}

mat3 rotY(float a){ float c = cos(a), s = sin(a); return mat3(c, 0.0, -s, 0.0, 1.0, 0.0, s, 0.0, c); }
mat3 rotX(float a){ float c = cos(a), s = sin(a); return mat3(1.0, 0.0, 0.0, 0.0, c, s, 0.0, -s, c); }
mat3 rotZ(float a){ float c = cos(a), s = sin(a); return mat3(c, s, 0.0, -s, c, 0.0, 0.0, 0.0, 1.0); }

// ── Occupancy primitives ────────────────────────────────────────────────────
float sdBox(vec3 p, vec3 b){
  vec3 q = abs(p) - b;
  return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}
float sdEll(vec3 p, vec3 r){
  float k0 = length(p / r);
  float k1 = length(p / (r * r));
  return k0 * (k0 - 1.0) / k1;
}

// ── Hull occupancy (local, nose +Z, unscaled) — voxelized at trace time ─────
float hullCapital(vec3 p){
  float d = sdBox(p, vec3(0.16, 0.08, 0.72));                                 // main slab
  d = min(d, sdBox(p - vec3(0.0, 0.0, 0.80), vec3(0.105, 0.055, 0.16)));      // stepped bow
  d = min(d, sdBox(p - vec3(0.0, 0.0, 1.00), vec3(0.055, 0.035, 0.10)));      // prow
  d = min(d, sdBox(p - vec3(0.0, 0.13, -0.26), vec3(0.075, 0.06, 0.13)));     // bridge
  d = min(d, sdBox(p - vec3(0.0, 0.235, -0.26), vec3(0.014, 0.05, 0.014)));   // mast
  d = min(d, sdBox(p - vec3(0.0, -0.10, 0.12), vec3(0.05, 0.04, 0.46)));      // keel
  vec3 q = vec3(abs(p.x), p.y, p.z);
  d = min(d, sdBox(q - vec3(0.21, -0.01, -0.16), vec3(0.05, 0.035, 0.32)));   // sponsons
  d = min(d, sdBox(q - vec3(0.10, 0.0, -0.80), vec3(0.055, 0.05, 0.10)));     // engine blocks
  return d;
}
float hullDestroyer(vec3 p){
  float d = sdBox(p, vec3(0.09, 0.05, 0.50));
  d = min(d, sdBox(p - vec3(0.0, 0.0, 0.58), vec3(0.05, 0.032, 0.12)));       // bow
  d = min(d, sdBox(p - vec3(0.0, 0.095, -0.30), vec3(0.014, 0.07, 0.10)));    // dorsal fin
  d = min(d, sdBox(p - vec3(0.0, -0.005, -0.10), vec3(0.27, 0.014, 0.10)));   // wings
  vec3 q = vec3(abs(p.x), p.y, p.z);
  d = min(d, sdBox(q - vec3(0.26, -0.005, -0.10), vec3(0.032, 0.032, 0.15))); // wingtip pods
  d = min(d, sdBox(p - vec3(0.0, 0.0, -0.56), vec3(0.05, 0.035, 0.07)));      // engine
  return d;
}
float hullCutter(vec3 p){
  float d = sdBox(p, vec3(0.05, 0.03, 0.22));
  d = min(d, sdBox(p - vec3(0.0, 0.0, 0.28), vec3(0.026, 0.02, 0.09)));       // nose
  d = min(d, sdBox(p - vec3(0.0, -0.006, -0.06), vec3(0.16, 0.011, 0.075)));  // wings
  d = min(d, sdBox(p - vec3(0.0, 0.042, 0.06), vec3(0.024, 0.02, 0.07)));     // canopy hump
  d = min(d, sdBox(p - vec3(0.0, 0.0, -0.27), vec3(0.032, 0.024, 0.05)));     // engine
  return d;
}
float hullSaucer(vec3 p){
  float d = sdEll(p, vec3(0.34, 0.05, 0.34));
  d = min(d, sdEll(p - vec3(0.0, 0.06, 0.0), vec3(0.13, 0.06, 0.13)));        // dome
  d = min(d, sdEll(p - vec3(0.0, -0.05, 0.0), vec3(0.11, 0.035, 0.11)));      // underside
  return d;
}
float shipHull(int cls, vec3 p){
  if (cls == 0) return hullCapital(p);
  if (cls == 1) return hullDestroyer(p);
  if (cls == 2) return hullCutter(p);
  return hullSaucer(p);
}
vec3 classBound(int cls){
  if (cls == 0) return vec3(0.28, 0.31, 1.13);
  if (cls == 1) return vec3(0.30, 0.18, 0.72);
  if (cls == 2) return vec3(0.18, 0.08, 0.38);
  return vec3(0.36, 0.14, 0.36);
}
// mat: 0 hull plate, 1 engine, 2 canopy glass, 3 gold stripe
float shipMat(int cls, vec3 c){
  if (cls == 0){
    if (c.z < -0.70) return 1.0;
    if (c.y > 0.10 && c.z > -0.36 && c.z < -0.16) return 2.0;
    if (abs(c.z - 0.30) < 0.05 && c.y > -0.04) return 3.0;
  } else if (cls == 1){
    if (c.z < -0.50) return 1.0;
    if (c.y > 0.025 && c.z > 0.28 && c.z < 0.52) return 2.0;
    if (abs(c.z + 0.05) < 0.04 && abs(c.x) < 0.11) return 3.0;
  } else if (cls == 2){
    if (c.z < -0.22) return 1.0;
    if (c.y > 0.030 && c.z > 0.00 && c.z < 0.14) return 2.0;
  } else {
    if (c.y > 0.048) return 2.0;
    if (c.y < -0.048) return 1.0;
  }
  return 0.0;
}

// ── Fleet frame (shared per pixel) ──────────────────────────────────────────
struct FleetFrame { vec3 anchor; float yaw; float mir; float tighten; float drive; };

FleetFrame fleetFrame(float t, float sN, float warpDrive){
  FleetFrame F;
  F.mir = seedN(2.0) < 0.5 ? -1.0 : 1.0;
  F.anchor = vec3(
    F.mir * (0.48 + 0.30 * seedN(3.0)),
    0.25 + 0.35 * seedN(4.0),
    -2.1 - 0.6 * seedN(5.0)
  );
  F.yaw = F.mir * -0.93 + (seedN(6.0) - 0.5) * 0.40;
  // Parade float: the whole fleet breathes slowly along its heading
  vec3 heading = rotY(F.yaw) * vec3(0.0, 0.0, 1.0);
  F.anchor += heading * sin(t * 0.07) * 0.15;
  F.tighten = smoothstep(0.05, 0.45, sN);
  F.drive = max(smoothstep(0.85, 1.0, sN), warpDrive);
  return F;
}

// Echelon slots (fleet-local; x lateral, z along heading) + per-slot scale
const vec4 SLOTS[8] = vec4[8](
  vec4( 0.00,  0.00,  0.00, 1.45),   // capital
  vec4(-0.92, -0.10, -0.62, 0.98),   // destroyer port
  vec4( 0.88,  0.14, -0.55, 0.94),   // destroyer starboard
  vec4(-1.38,  0.28, -1.15, 0.68),   // cutters…
  vec4( 1.42, -0.22, -1.20, 0.66),
  vec4(-0.52, -0.40, -1.05, 0.62),
  vec4( 0.50,  0.46, -1.32, 0.60),
  vec4( 0.00,  0.00,  0.00, 0.80)    // patrol saucer (orbit path, slot unused)
);
const int CLS[8] = int[8](0, 1, 1, 2, 2, 2, 2, 3);

int shipCount(){ return 5 + int(seedN(7.0) * 2.9); } // 5..7 formation ships (+saucer)

void shipDef(int i, FleetFrame F, float t, out vec3 pos, out mat3 R, out float scl, out float phase){
  vec4 slot = SLOTS[i];
  scl = slot.w;
  phase = hash11(float(i) * 7.31 + seedN(9.0) * 43.0) * 6.28318;

  if (i == 7){
    // Banked patrol saucer on a slow circuit around the formation
    float pa = t * 0.12 + seedN(8.0) * 6.28318;
    pos = F.anchor + vec3(cos(pa) * 2.3, 0.55 + 0.25 * sin(t * 0.21 + phase), sin(pa) * 2.3);
    R = rotY(-pa) * rotZ(0.14 * sin(t * 0.5 + phase));
    return;
  }

  // Loose cruise → tight echelon, with a per-ship arrival stagger
  vec3 jitter = (hash33(vec3(float(i) * 3.7, seedN(9.0) * 17.0, 1.3)) - 0.5) * vec3(1.2, 0.8, 1.2);
  float arrive = smoothstep(0.0, 1.0, clamp((F.tighten - 0.12 * hash11(float(i) * 2.1)) * 1.35, 0.0, 1.0));
  vec3 lp = mix(slot.xyz * 1.35 + jitter, slot.xyz, arrive);
  pos = F.anchor + rotY(F.yaw) * lp;
  pos.y += sin(t * 0.5 + phase) * 0.045 * scl;

  float sway  = 0.05 * sin(t * 0.31 + phase);
  float pitch = 0.04 * sin(t * 0.43 + phase * 1.7) - 0.15 * F.drive;
  float roll  = 0.06 * sin(t * 0.37 + phase * 2.3);
  R = rotY(F.yaw + sway) * rotX(pitch) * rotZ(roll);
}

// ── Voxel DDA (Amanatides–Woo in ship-local space) ──────────────────────────
struct VoxHit { float t; vec3 nl; vec2 fuv; float mat; float cid; };

bool traceShip(vec3 ro, vec3 rd, vec3 pos, mat3 R, float scl, int cls, out VoxHit vh){
  vh.t = 1e4; vh.nl = vec3(0.0); vh.fuv = vec2(0.0); vh.mat = 0.0; vh.cid = 0.0;
  vec3 rl = (ro - pos) * R;  // world→local (R orthonormal, columns = ship axes)
  vec3 dl = rd * R;
  vec3 dlSafe = dl + step(abs(dl), vec3(1e-6)) * 1e-6;

  vec3 bb = classBound(cls) * scl + VOX_CELL;
  vec3 tLo = (-bb - rl) / dlSafe;
  vec3 tHi = ( bb - rl) / dlSafe;
  vec3 tmin = min(tLo, tHi);
  vec3 tmax = max(tLo, tHi);
  float tN = max(max(tmin.x, tmin.y), tmin.z);
  float tF = min(min(tmax.x, tmax.y), tmax.z);
  if (tN > tF || tF < 0.0) return false;
  float tE = max(tN, 0.0);

  // Entry face normal (axis owning tN)
  vec3 en = step(tmin.yzx, tmin.xyz) * step(tmin.zxy, tmin.xyz);
  vec3 nl = -sign(dlSafe) * en;
  if (dot(nl, nl) < 0.5) nl = vec3(0.0, 0.0, -sign(dlSafe.z));

  vec3 pe = rl + dl * (tE + 1e-4);
  vec3 cell = floor(pe / VOX_CELL);
  vec3 sgn = sign(dlSafe);
  vec3 tDelta = VOX_CELL / abs(dlSafe);
  vec3 nextB = (cell + max(sgn, 0.0)) * VOX_CELL;
  vec3 tSide = (nextB - rl) / dlSafe;
  float tCur = tE;

  for (int s = 0; s < SHIP_DDA_STEPS; s++){
    vec3 cc = (cell + 0.5) * VOX_CELL;
    // Half-cell inflation so thin wings survive lattice sampling
    if (shipHull(cls, cc / scl) * scl < VOX_CELL * 0.45){
      vh.t = tCur;
      vh.nl = nl;
      vec3 hp = rl + dl * tCur;
      vec3 lf = clamp((hp - cell * VOX_CELL) / VOX_CELL, 0.0, 1.0);
      vh.fuv = abs(nl.x) > 0.5 ? lf.zy : (abs(nl.y) > 0.5 ? lf.xz : lf.xy);
      vh.mat = shipMat(cls, cc / scl);
      vh.cid = hash31(cell + float(cls) * 7.7);
      return true;
    }
    if (tSide.x < tSide.y && tSide.x < tSide.z){
      cell.x += sgn.x; tCur = tSide.x; tSide.x += tDelta.x; nl = vec3(-sgn.x, 0.0, 0.0);
    } else if (tSide.y < tSide.z){
      cell.y += sgn.y; tCur = tSide.y; tSide.y += tDelta.y; nl = vec3(0.0, -sgn.y, 0.0);
    } else {
      cell.z += sgn.z; tCur = tSide.z; tSide.z += tDelta.z; nl = vec3(0.0, 0.0, -sgn.z);
    }
    if (tCur > tF) break;
  }
  return false;
}

// ── Voxel shading — flat cube faces, grout seams, lit windows ───────────────
vec3 shadeShip(VoxHit vh, vec3 nw, vec3 rd, vec3 L, float drive){
  vec3 keyC = vec3(1.05, 0.92, 0.74);           // warm sun key
  vec3 amb  = vec3(0.10, 0.14, 0.24);           // navy sky ambient
  float ndl = max(dot(nw, L), 0.0);
  float rim = pow(1.0 - max(dot(nw, -rd), 0.0), 3.0);

  vec3 alb;
  float emis = 0.0;
  vec3 emisCol = vec3(0.0);
  if (vh.mat > 2.5){                            // gold stripe
    alb = vec3(1.0, 0.72, 0.28);
  } else if (vh.mat > 1.5){                     // canopy glass
    alb = vec3(0.06, 0.10, 0.14);
    emisCol = vec3(0.35, 0.85, 0.95);
    emis = 0.55 + 0.30 * sin(uTime * 1.7 + vh.cid * 6.28318);
  } else if (vh.mat > 0.5){                     // engine
    alb = vec3(0.12, 0.09, 0.07);
    emisCol = vec3(1.0, 0.62, 0.22);
    emis = 1.4 + 0.5 * sin(uTime * 9.0 + vh.cid * 20.0) + 2.4 * drive;
  } else {                                      // hull plate
    alb = vec3(0.58, 0.64, 0.75) * (0.90 + 0.20 * vh.cid);
    alb += vec3(0.05) * max(nw.y, 0.0);         // lighter topside
  }

  vec3 col = alb * (amb + keyC * (0.25 + 0.95 * ndl));
  // Front-upper bounce fill — the sun is a backlight; without this the
  // camera-facing hull reads as flat navy silhouette
  float fill = max(dot(nw, normalize(vec3(0.25, 0.45, 0.86))), 0.0);
  col += alb * vec3(0.42, 0.46, 0.55) * fill;
  col += vec3(0.30, 0.75, 0.95) * rim * 0.30;
  float specW = vh.mat > 1.5 && vh.mat < 2.5 ? 1.2 : 0.35;
  col += keyC * pow(max(dot(reflect(rd, nw), L), 0.0), 20.0) * specW;
  col += emisCol * emis;

  // Grout: darken toward cube-face edges — the made-of-cubes read
  float eg = min(min(vh.fuv.x, 1.0 - vh.fuv.x), min(vh.fuv.y, 1.0 - vh.fuv.y));
  col *= 0.78 + 0.22 * smoothstep(0.0, 0.10, eg);

  // Sparse lit windows on hull side faces — the fleet is inhabited
  if (vh.mat < 0.5 && vh.cid > 0.82 && abs(nw.y) < 0.7){
    float win = smoothstep(0.24, 0.10, length(vh.fuv - 0.5));
    float wglow = 0.55 + 0.45 * sin(uTime * 0.8 + vh.cid * 40.0);
    col += vec3(1.0, 0.85, 0.55) * win * wglow * 0.9;
  }
  return col;
}

// ── Analytic planet (smooth spheres stay smooth — never voxelized) ──────────
float tracePlanet(vec3 ro, vec3 rd, vec3 pc, float pr){
  vec3 oc = ro - pc;
  float b = dot(oc, rd);
  float h = b * b - dot(oc, oc) + pr * pr;
  if (h < 0.0) return -1.0;
  float t = -b - sqrt(h);
  return t > 0.0 ? t : -1.0;
}

vec3 shadePlanet(vec3 pos, vec3 pc, float pr, vec3 rd, vec3 L){
  vec3 n = (pos - pc) / pr;
  vec3 keyC = vec3(1.05, 0.92, 0.74);
  float dayN = dot(n, L);
  float day = smoothstep(-0.12, 0.35, dayN);

  // Banded surface — seeded hue lane between ocean-teal and dune-sand
  float lat = n.y * 4.0 + fbm(n * 3.0 + seedN(34.0) * 7.0) * 2.2;
  float band = 0.5 + 0.5 * sin(lat * 3.1);
  vec3 baseA = mix(vec3(0.10, 0.55, 0.62), vec3(0.75, 0.55, 0.35), seedN(35.0));
  vec3 baseB = baseA * vec3(0.45, 0.52, 0.62);
  vec3 col = mix(baseA, baseB, band) * keyC * (0.12 + 0.95 * day);

  // Night side: sparse city lights along the terminator's dark shore
  float city = step(0.978, hash31(floor(n * 42.0))) * (1.0 - day);
  col += vec3(1.0, 0.80, 0.45) * city * 0.85;

  // Atmosphere rim + warm terminator kiss
  float fres = pow(1.0 - max(dot(n, -rd), 0.0), 2.5);
  col += vec3(0.30, 0.70, 1.00) * fres * (0.25 + 0.35 * day);
  col += vec3(1.0, 0.55, 0.25) * pow(1.0 - abs(dayN), 9.0) * 0.30;
  return col;
}

// ── Gallery deep field (sparse stars + soft veil — NOT purple mush) ─────────
vec2 spaceWarp(vec2 p, float t){
  vec2 q = vec2(
    fbm(vec3(p * 1.2, t * 0.05)),
    fbm(vec3(p * 1.2 + 5.2, t * 0.05)));
  float r = fbm(vec3(p * 1.8 + q, t * 0.04));
  return 0.45 * q + 0.2 * vec2(r, fbm(vec3(p * 1.8 + q + 3.7, t * 0.04)));
}

vec3 starField(vec2 p, float t, float dens){
  vec2 gv = fract(p) - 0.5;
  vec2 id = floor(p);
  float n = hash21(id + uSeed * 0.0001);
  float d = length(gv);
  float bright = smoothstep(0.18, 0.0, d) * step(dens, n);
  float spike = 0.0;
  if (n > dens + 0.08){
    spike = exp(-abs(gv.x) * 42.0) * exp(-abs(gv.y) * 6.0) * 0.7
          + exp(-abs(gv.y) * 42.0) * exp(-abs(gv.x) * 6.0) * 0.7;
  }
  float tw = 0.65 + 0.35 * sin(t * (2.2 + 3.0 * n) + n * 17.0);
  float hue = mix(0.2, 0.88, hash21(id + 3.1));
  vec3 tip = mix(vec3(0.95, 0.97, 1.0), accentRamp(hue), 0.55);
  tip = mix(tip, vec3(1.0, 0.82, 0.45), step(0.92, n) * 0.55);
  return tip * (bright * 1.35 + spike) * tw;
}

vec3 deepField(vec3 rd, vec2 p, vec2 warp, float t, float hush, float breath){
  vec3 col = vec3(0.010, 0.020, 0.055);       // intentional navy ink
  float veil = fbm(rd * 1.5 + vec3(warp * 0.5, t * 0.035 + uSeed * 1e-5)) * 0.5 + 0.5;
  float veil2 = fbm(rd.yzx * 2.1 + vec3(t * 0.028, warp.yx)) * 0.5 + 0.5;
  veil = smoothstep(0.45, 0.88, veil) * (0.35 + 0.25 * breath) * hush;
  veil2 = smoothstep(0.58, 0.92, veil2) * 0.20 * hush;
  vec3 veilA = mix(vec3(0.05, 0.18, 0.38), accentRamp(0.2), 0.65);
  vec3 veilB = mix(vec3(0.28, 0.12, 0.04), accentRamp(0.82), 0.55);
  col += mix(veilA, veilB, veil) * veil * 0.55;
  col += accentRamp(0.55) * veil2 * 0.30;

  col += starField(p * 38.0 + rd.xy * 4.0 + warp * 2.0, t, 0.84) * 1.5 * hush;
  col += starField(p * 18.0 + 4.7 + rd.xy * 1.8, t * 0.85, 0.90) * 0.6 * hush;
  col += starField(p * 9.0 + 11.3 + warp * 0.8, t * 0.4, 0.95) * 0.3 * hush;
  return col;
}

// Colorful drifting motes — quiet foreground parallax dust
vec3 accretionDust(vec3 ro, vec3 rd, float t, float breath, vec2 warp){
  vec3 col = vec3(0.0);
  for (int i = 0; i < 10; i++){
    float fi = float(i);
    vec3 hv = hash33(vec3(fi * 1.7 + uSeed * 0.001, fi * 3.1, 2.3));
    float rad = mix(1.2, 4.6, hv.x);
    float ang = hv.y * 6.28318 + t * (0.05 + 0.12 * hv.z) + warp.x * 0.6;
    vec3 c = vec3(cos(ang) * rad, (hv.z - 0.5) * 1.6 + 0.12 * sin(t * 0.6 + fi), sin(ang) * rad - 1.2);
    vec3 oc = c - ro;
    float tq = dot(oc, rd);
    if (tq > 0.3){
      float dp = length(oc - rd * tq);
      float w = exp(-dp * dp * 620.0) * exp(-tq * 0.16) * (0.4 + 0.4 * breath);
      col += accentRamp(0.25 + 0.5 * hv.x) * w * 0.8;
    }
  }
  return col;
}

float warpRing(vec2 p, float sN, float warpDrive){
  float drive = max(smoothstep(0.85, 1.0, sN), warpDrive);
  if (drive < 0.001) return 0.0;
  float r = length(p);
  float ring = exp(-abs(r - 0.52) * 28.0) * drive;
  float streaks = exp(-abs(p.y) * 12.0) * smoothstep(0.12, 0.85, abs(p.x)) * drive * 0.4;
  return ring + streaks;
}

// ── Camera — wide gallery → over-shoulder → close pass → warp axis ─────────
void camAt(float sN, float t, FleetFrame F, out vec3 ro, out vec3 ta){
  float t0 = smoothstep(0.02, 0.30, sN);
  float t1 = smoothstep(0.34, 0.62, sN);
  float t2 = smoothstep(0.66, 0.90, sN);

  vec3 roA = vec3(-F.mir * 0.30, 0.32, 4.40);
  vec3 roB = vec3(-F.mir * 0.90, 0.60, 3.05);
  vec3 roC = F.anchor + vec3(-F.mir * 1.60, 0.35, 2.00);
  vec3 roD = vec3(0.0, 0.25, 1.20);

  vec3 taA = F.anchor * 0.65 + vec3(0.0, 0.08, -0.50);
  vec3 taB = F.anchor * 0.80;
  vec3 taC = F.anchor;
  vec3 taD = vec3(F.anchor.x * 0.2, 0.15, -8.0);

  ro = mix(roA, roB, t0); ro = mix(ro, roC, t1); ro = mix(ro, roD, t2);
  ta = mix(taA, taB, t0); ta = mix(ta, taC, t1); ta = mix(ta, taD, t2);
  ro += 0.025 * vec3(sin(t * 0.23), sin(t * 0.31 + 2.0), 0.0);   // handheld drift
}

mat3 lookAt(vec3 ro, vec3 ta){
  vec3 f = normalize(ta - ro);
  vec3 r = normalize(cross(vec3(0.0, 1.0, 0.0), f));
  if (dot(r, r) < 1e-4) r = vec3(1.0, 0.0, 0.0);
  vec3 u = cross(f, r);
  return mat3(r, u, f);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float sN = uScroll.y > 0.0 ? clamp(uScroll.x / uScroll.y, 0.0, 1.0) : STATIC_SN;

  // Rhythm system — coprime breath + hush (one pulse for the whole exhibit)
  float breath = 0.5 + 0.5 * sin(uTime * 0.093);
  breath = breath * breath * (3.0 - 2.0 * breath);
  float hush = 0.72 + 0.28 * (0.5 + 0.5 * sin(uTime * 0.11));

  FleetFrame F = fleetFrame(uTime, sN, uWarp);
  F.drive = clamp(F.drive + abs(uScrollVel) * 0.004, 0.0, 1.0);

  vec2 warp = spaceWarp(p, uTime * 0.09);
  vec3 ro, ta;
  camAt(sN, uTime, F, ro, ta);
  mat3 ca = lookAt(ro, ta);
  vec3 rd = normalize(ca * vec3(p + warp * 0.05, 1.60));

  // One seeded sun — key light for hulls, planet, terminator, rim
  vec3 sunDir = normalize(vec3(F.mir * (0.45 + 0.35 * seedN(40.0)), 0.30 + 0.25 * seedN(41.0), -0.65));
  vec3 L = normalize(mix(
    sunDir,
    vec3((uPointer.x - 0.5) * 2.0, (uPointer.y - 0.5) * 1.8 + 0.35, 0.7),
    uPointerActive
  ));

  // Sky
  vec3 sky = deepField(rd, p, warp, uTime, hush, breath);
  vec3 col = sky;

  // Analytic planet
  vec3 pc = vec3(-F.mir * (1.8 + 0.8 * seedN(30.0)), -0.6 + 0.9 * seedN(31.0), -5.2 - 1.4 * seedN(32.0));
  float pr = 1.05 + 0.5 * seedN(33.0);
  float tBest = 1e4;
  float tPl = tracePlanet(ro, rd, pc, pr);
  if (tPl > 0.0){
    tBest = tPl;
    col = shadePlanet(ro + rd * tPl, pc, pr, rd, L);
  }

  // The armada — per-ship slab test → voxel DDA, nearest hit wins
  int count = shipCount();
  VoxHit best; best.t = 1e4; best.nl = vec3(0.0); best.fuv = vec2(0.0); best.mat = 0.0; best.cid = 0.0;
  mat3 bestR = mat3(1.0);
  vec3 trail = vec3(0.0);
  for (int i = 0; i < MAX_SHIPS; i++){
    if (i >= count && i != 7) continue;
    vec3 sp; mat3 R; float scl; float phase;
    shipDef(i, F, uTime, sp, R, scl, phase);
    int cls = CLS[i];

    VoxHit vh;
    if (traceShip(ro, rd, sp, R, scl, cls, vh) && vh.t < best.t && vh.t < tBest){
      best = vh; bestR = R;
    }

    // Additive life: engine trails, nav blinker, saucer under-glow
    float flick = 0.5 + 0.5 * sin(uTime * 9.0 + phase * 17.0);
    if (cls == 3){
      vec3 g = sp + R * vec3(0.0, -0.09 * scl, 0.0);
      vec3 og = g - ro; float tg = dot(og, rd);
      if (tg > 0.0 && tg < best.t + 0.4){
        float dp = length(og - rd * tg);
        float pulse = 0.6 + 0.4 * sin(uTime * 2.6 + phase);
        trail += vec3(0.35, 0.85, 0.95) * exp(-dp * dp * 900.0) * pulse * 0.55;
      }
    } else {
      float tailZ = cls == 0 ? -0.90 : (cls == 1 ? -0.63 : -0.32);
      vec3 E = sp + R * vec3(0.0, 0.0, tailZ * scl);
      vec3 B = R * vec3(0.0, 0.0, -1.0);
      float tlen = (0.55 + 1.6 * F.drive) * scl;
      for (int k = 0; k < 3; k++){
        float fk = float(k);
        vec3 q = E + B * tlen * (0.18 + 0.38 * fk + 0.03 * sin(uTime * 7.0 + fk * 2.0 + phase));
        vec3 oq = q - ro; float tq = dot(oq, rd);
        if (tq > 0.0 && tq < best.t + 0.5){
          float dp = length(oq - rd * tq);
          float w = exp(-dp * dp * (260.0 - 60.0 * fk)) * (1.0 - fk * 0.28);
          trail += mix(vec3(1.0, 0.62, 0.22), vec3(0.45, 0.85, 1.0), fk * 0.35)
                 * w * (0.55 + 0.35 * flick + 1.5 * F.drive) * 0.55;
        }
      }
      // Mast blinker — slow red heartbeat
      float mastY = cls == 0 ? 0.29 : (cls == 1 ? 0.17 : 0.07);
      vec3 M = sp + R * vec3(0.0, mastY * scl, cls == 0 ? -0.26 * scl : 0.0);
      vec3 om = M - ro; float tm = dot(om, rd);
      if (tm > 0.0 && tm < best.t + 0.2){
        float dp = length(om - rd * tm);
        float blink = smoothstep(0.90, 0.99, fract(uTime * 0.45 + phase * 0.16));
        trail += vec3(1.0, 0.32, 0.28) * exp(-dp * dp * 5200.0) * blink * 0.9;
      }
    }
  }

  if (best.t < 1e3){
    tBest = best.t;
    vec3 nw = bestR * best.nl;
    vec3 surface = shadeShip(best, nw, rd, L, F.drive);
    float fog = exp(-best.t * 0.05);
    col = mix(sky, surface, fog);
  }

  // Seeded thin ring around the planet (draw when nothing sits in front)
  if (seedN(36.0) > 0.45){
    vec3 rn = normalize(vec3(0.18 * F.mir, 1.0, 0.24));
    float denom = dot(rd, rn);
    if (abs(denom) > 1e-4){
      float tR = dot(pc - ro, rn) / denom;
      if (tR > 0.0 && tR < tBest){
        float rr = length(ro + rd * tR - pc);
        float ringA = smoothstep(1.45 * pr, 1.60 * pr, rr) * smoothstep(2.30 * pr, 2.00 * pr, rr);
        ringA *= 0.5 + 0.5 * sin(rr / pr * 26.0);
        col += vec3(0.85, 0.75, 0.55) * ringA * 0.20;
      }
    }
  }

  // Sun bloom — suppressed when geometry owns the pixel
  float sunA = max(dot(rd, sunDir), 0.0);
  float glow = pow(sunA, 900.0) * 2.2 + pow(sunA, 60.0) * 0.55 + pow(sunA, 8.0) * 0.16;
  col += vec3(1.0, 0.86, 0.60) * glow * (tBest < 1e3 ? 0.15 : 1.0);

  col += trail;
  col += accretionDust(ro, rd, uTime, breath, warp);

  // Warp ceremony
  float wr = warpRing(p, sN, uWarp);
  col += vec3(1.0, 0.7, 0.38) * wr * 1.25;
  col += vec3(0.32, 0.72, 1.0) * wr * 0.28;

  // Filmic knee that keeps chroma (less white crush than Reinhard alone)
  float luma = dot(col, vec3(0.299, 0.587, 0.114));
  vec3 mapped = col / (1.0 + col * 0.4);
  col = mix(mapped, col / (1.0 + luma * 0.55), 0.45);
  col += (ign(fragCoord + uTime) - 0.5) * 0.014;
  col *= 0.92 + 0.2 * uIntensity;

  // Soft vignette — no hard band through the cosmos
  float vig = smoothstep(1.85, 0.45, length(p));
  col *= mix(0.9, 1.08, vig);

  if (uTheme > 0.5){
    col = mix(vec3(0.93, 0.95, 0.98), col, 0.78);
  }
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}