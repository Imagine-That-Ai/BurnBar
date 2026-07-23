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


// ── Genesis: bounded procedural planet ──────────────────────────────────────
const float GE_PI = 3.141592653589793;
const float GE_TAU = 6.283185307179586;
const float GE_PLANET_R = 1.0;
const float GE_CLOUD_BASE = 1.018;
const float GE_CLOUD_TOP = 1.074;
const float GE_ATMOS_R = 1.115;
const float GE_AURORA_BASE = 1.055;
const float GE_AURORA_TOP = 1.215;
const int GE_ATMOS_STEPS = 5;
const int GE_CLOUD_STEPS = 4;
const int GE_AURORA_STEPS = 4;

float ge_sat(float x){
  return clamp(x, 0.0, 1.0);
}

mat2 ge_rot(float a){
  float c = cos(a);
  float s = sin(a);
  return mat2(c, -s, s, c);
}

vec3 ge_rotY(vec3 p, float a){
  p.xz = ge_rot(a) * p.xz;
  return p;
}

vec3 ge_rotX(vec3 p, float a){
  p.yz = ge_rot(a) * p.yz;
  return p;
}

// Exact ray/sphere interval. A negative pair means no forward intersection.
vec2 ge_sphereHit(vec3 ro, vec3 rd, float radius){
  float b = dot(ro, rd);
  float c = dot(ro, ro) - radius * radius;
  float h = b * b - c;
  if (h < 0.0) return vec2(-1.0);
  h = sqrt(h);
  return vec2(-b - h, -b + h);
}

// Cornette-Shanks / Henyey-Greenstein-like forward lobe for aerosols.
float ge_miePhase(float mu){
  const float g = 0.76;
  float g2 = g * g;
  float den = max(1.0 + g2 - 2.0 * g * mu, 1e-3);
  return (1.0 - g2) * (1.0 + mu * mu) /
    (8.0 * GE_PI * (2.0 + g2) * pow(den, 1.5));
}

float ge_rayleighPhase(float mu){
  return 3.0 * (1.0 + mu * mu) / (16.0 * GE_PI);
}

// Stable celestial field in direction space. Each layer is one hashed cell;
// point radii stay inside the cell so no neighbour loop is needed.
float ge_starLayer(vec2 skyUv, float scale, float seed, out float hot){
  vec2 q = skyUv * scale;
  vec2 cell = floor(q);
  vec2 local = fract(q);
  float gateHash = hash21(cell + vec2(seed, seed * 1.73));
  vec2 starPos = vec2(
    hash21(cell + vec2(seed + 17.0, seed + 3.0)),
    hash21(cell + vec2(seed + 41.0, seed + 29.0))
  );
  vec2 delta = local - starPos;
  float radius2 = dot(delta, delta);
  float exists = smoothstep(0.915, 0.995, gateHash);
  float core = exp(-radius2 * 1850.0);
  float halo = exp(-radius2 * 280.0) * 0.12;
  hot = smoothstep(0.982, 0.999, gateHash) * exists;
  return (core + halo) * exists;
}

vec3 ge_space(vec3 rd, vec2 fragCoord){
  float longitude = atan(rd.z, rd.x) / GE_TAU + 0.5;
  float latitude = asin(clamp(rd.y, -1.0, 1.0)) / GE_PI + 0.5;
  vec2 skyUv = vec2(longitude, latitude);

  float hotA;
  float hotB;
  float starsA = ge_starLayer(skyUv, 176.0, 7.0, hotA);
  float starsB = ge_starLayer(skyUv + vec2(0.137, 0.071), 293.0, 31.0, hotB);
  float twinkleA = 0.82 + 0.18 * sin(uTime * 0.71 + hash21(floor(skyUv * 176.0)) * GE_TAU);
  float twinkleB = 0.86 + 0.14 * sin(uTime * 0.93 + hash21(floor(skyUv * 293.0)) * GE_TAU);

  vec3 coolStar = mix(accentRamp(0.68), uInk, 0.58);
  vec3 warmStar = mix(accentRamp(0.08), uInk, 0.5);
  vec3 starCol = coolStar * starsA * twinkleA + warmStar * starsB * twinkleB;

  // A single-noise galactic veil: enough depth behind the disc without making
  // the empty sky compete with the planet.
  vec3 galacticAxis = normalize(vec3(0.34, 0.82, -0.46));
  float band = exp(-abs(dot(rd, galacticAxis)) * 8.5);
  float veilNoise = 0.5 + 0.5 * snoise(rd * 2.35 + vec3(0.0, 0.0, uTime * 0.008));
  vec3 veil = accentRamp(0.72) * band * veilNoise * 0.055;

  // Tiny diffraction crosses only on the rare hottest stars.
  vec2 centered = fract(skyUv * 176.0) - 0.5;
  float crossGlow =
    exp(-abs(centered.x) * 210.0 - abs(centered.y) * 18.0) +
    exp(-abs(centered.y) * 210.0 - abs(centered.x) * 18.0);
  starCol += mix(accentRamp(0.12), uInk, 0.7) * crossGlow * hotA * 0.17;

  float nightStrength = 1.0 - uTheme;
  vec3 col = uBg + nightStrength * (veil + starCol * (0.72 + 0.4 * uIntensity));
  col += (hash21(fragCoord) - 0.5) * 0.006 * nightStrength;
  return col;
}

// Low-frequency continents plus great-circle plate boundaries. The ridges are
// continuous on the sphere and read as folded mountain chains rather than
// height noise sprayed over a globe.
float ge_terrain(vec3 q, out float ridge, out float river){
  vec3 n1 = normalize(vec3(0.74, 0.18, -0.65));
  vec3 n2 = normalize(vec3(-0.27, 0.92, 0.28));
  vec3 n3 = normalize(vec3(0.48, -0.58, 0.66));

  float continent = fbm(q * 1.18 + vec3(1.7, -0.6, 2.2));
  float shelf = snoise(q * 2.75 + vec3(-3.1, 1.2, 0.4));

  float plateA = exp(-abs(dot(q, n1)) * 22.0);
  float plateB = exp(-abs(dot(q, n2)) * 25.0);
  float plateC = exp(-abs(dot(q, n3)) * 20.0);
  float plate = max(plateA, max(plateB, plateC));
  float folded = 0.5 + 0.5 * snoise(q * 8.4 + plate * 2.1);
  ridge = plate * folded;

  float elevation = continent * 0.66 + shelf * 0.24 + ridge * 0.22 - 0.025;

  // Thin, branching-looking drainage contours. They are restricted to rolling
  // mid-elevations and subtract from height, so valleys visually connect high
  // country to coasts instead of crossing oceans and summits indiscriminately.
  float drainageNoise = snoise(q * 10.5 + vec3(elevation * 3.1));
  float channel = 1.0 - smoothstep(0.018, 0.075, abs(drainageNoise));
  float upland = smoothstep(0.035, 0.24, elevation);
  float belowSummit = 1.0 - smoothstep(0.48, 0.82, elevation + ridge * 0.2);
  river = channel * upland * belowSummit;
  return elevation - river * 0.055;
}

float ge_cityLayer(vec3 q, float scale, float seed){
  float longitude = atan(q.z, q.x) / GE_TAU + 0.5;
  float latitude = asin(clamp(q.y, -1.0, 1.0)) / GE_PI + 0.5;
  vec2 gridUv = vec2(longitude, latitude) * vec2(scale, scale * 0.52);
  vec2 cell = floor(gridUv);
  vec2 local = fract(gridUv);
  float population = hash21(cell + vec2(seed, seed * 1.9));
  vec2 center = vec2(
    hash21(cell + vec2(seed + 13.0, seed + 71.0)),
    hash21(cell + vec2(seed + 47.0, seed + 19.0))
  );
  float pointGlow = exp(-dot(local - center, local - center) * 260.0);
  return pointGlow * smoothstep(0.82, 0.995, population);
}

// Weather is evaluated in world space so cloud masses drift independently of
// the rotating terrain. Two octaves per query keep the short shell march cheap.
float ge_cloudDensity(vec3 worldPos){
  float radius = length(worldPos);
  float height = (radius - GE_CLOUD_BASE) / (GE_CLOUD_TOP - GE_CLOUD_BASE);
  float vertical = smoothstep(0.0, 0.18, height) * (1.0 - smoothstep(0.72, 1.0, height));
  if (vertical <= 0.0) return 0.0;

  vec3 spherePos = normalize(worldPos);
  vec3 drift = vec3(uTime * 0.012, -uTime * 0.003, uTime * 0.008);
  float weather = snoise(spherePos * 3.65 + drift) * 0.72;
  weather += snoise(spherePos * 11.6 - drift * 1.7) * 0.28;
  float mass = smoothstep(0.08, 0.43, weather + 0.11);
  return mass * vertical;
}

float ge_cloudShadow(vec3 surfaceNormal, vec3 sunDir){
  vec3 probePos = surfaceNormal * mix(GE_CLOUD_BASE, GE_CLOUD_TOP, 0.48);
  probePos += sunDir * 0.026;
  float density = ge_cloudDensity(probePos);
  return exp(-density * 2.65);
}

vec3 ge_surface(
  vec3 hitPos,
  vec3 viewDir,
  vec3 sunDir,
  float worldSpin
){
  vec3 sphereNormal = normalize(hitPos);
  vec3 mapPos = ge_rotY(sphereNormal, worldSpin);

  float ridge;
  float river;
  float elevation = ge_terrain(mapPos, ridge, river);
  float land = smoothstep(-0.018, 0.034, elevation);
  float coast = exp(-abs(elevation) * 34.0);
  float mountain = smoothstep(0.22, 0.68, elevation + ridge * 0.28);

  // Fine relief changes the lighting normal but not the analytic sphere hit.
  // This preserves a perfectly stable silhouette while giving ranges and river
  // basins tactile depth at close scroll altitudes.
  vec3 poleRef = abs(mapPos.y) < 0.92 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
  vec3 tangent = normalize(cross(poleRef, mapPos));
  vec3 bitangent = normalize(cross(mapPos, tangent));
  float reliefA = snoise(mapPos * 18.0 + vec3(2.0, -1.0, 4.0));
  float reliefB = snoise(mapPos * 18.0 + vec3(-5.0, 3.0, 1.0));
  vec3 mapNormal = normalize(
    mapPos + (tangent * reliefA + bitangent * reliefB) * (0.018 + mountain * 0.055) * land
  );
  vec3 normal = ge_rotY(mapNormal, -worldSpin);

  float ndl = dot(normal, sunDir);
  float day = ge_sat(ndl);
  float twilight = smoothstep(-0.18, 0.14, ndl);
  float cloudLight = ge_cloudShadow(sphereNormal, sunDir);
  float direct = day * mix(0.36, 1.0, cloudLight);
  float ambient = mix(0.035, 0.27, uTheme) + 0.06 * ge_sat(normal.y * 0.5 + 0.5);

  // Ocean: depth, coastal shelf, Fresnel sky reflection, and a bounded sun glint.
  vec3 oceanDeep = mix(uBg, accentRamp(0.88), mix(0.76, 0.58, uTheme));
  vec3 oceanShelf = mix(oceanDeep, accentRamp(0.66), 0.48);
  vec3 ocean = mix(oceanDeep, oceanShelf, coast * (1.0 - land));
  float fresnel = pow(1.0 - ge_sat(dot(normal, viewDir)), 5.0);
  vec3 skyReflection = mix(accentRamp(0.78), uBg, 0.36 + 0.32 * uTheme);
  ocean = mix(ocean, skyReflection, fresnel * 0.78);
  vec3 halfVector = normalize(sunDir + viewDir);
  float sunGlint = pow(ge_sat(dot(normal, halfVector)), 240.0) * smoothstep(-0.02, 0.22, ndl);
  ocean += mix(accentRamp(0.08), uInk, 0.62) * sunGlint * (0.75 + 0.55 * uIntensity);
  ocean *= ambient + direct * 0.88;

  // Land: coastal lowlands, folded ranges, river valleys, and polar/alpine snow.
  vec3 lowland = mix(accentRamp(0.36), accentRamp(0.49), 0.42);
  vec3 highland = mix(accentRamp(0.18), accentRamp(0.42), 0.36);
  vec3 snow = mix(uInk, uBg, 0.18 + 0.66 * uTheme);
  vec3 landCol = mix(lowland, highland, mountain);
  float snowLine = smoothstep(0.58, 0.82, mountain + abs(mapPos.y) * 0.55);
  landCol = mix(landCol, snow, snowLine * 0.78);
  landCol = mix(landCol, oceanShelf * 0.72, river * 0.74);
  landCol *= ambient + direct * (0.78 + 0.22 * ridge);

  vec3 col = mix(ocean, landCol, land);

  // Civilization: two sparse grids, concentrated in low coastal land and gated
  // continuously by the physical terminator. Dawn extinguishes the embers.
  float habitableLatitude = 1.0 - smoothstep(0.68, 0.9, abs(mapPos.y));
  float coastalSettlement = land * exp(-max(elevation, 0.0) * 18.0) * coast;
  float cityFine = ge_cityLayer(mapPos, 182.0, 11.0);
  float cityMajor = ge_cityLayer(mapPos, 97.0, 53.0);
  float night = 1.0 - smoothstep(-0.22, 0.08, ndl);
  float cityMask = (cityFine + cityMajor * 1.35) * coastalSettlement * habitableLatitude * night;
  cityMask *= mix(1.0, 0.34, uTheme);
  vec3 cityColor = mix(accentRamp(0.02), accentRamp(0.15), cityMajor);
  col += cityColor * cityMask * (1.45 + 0.9 * uIntensity);

  // A narrow coast sheen reads as surf and keeps the fractal shoreline legible.
  col += mix(accentRamp(0.62), uInk, 0.28) * coast * twilight * 0.055;
  return col;
}

void ge_cloudMarch(
  vec3 ro,
  vec3 rd,
  vec3 sunDir,
  float sceneT,
  vec2 fragCoord,
  out vec3 cloudColor,
  out float cloudTrans
){
  cloudColor = vec3(0.0);
  cloudTrans = 1.0;
  vec2 shellHit = ge_sphereHit(ro, rd, GE_CLOUD_TOP);
  if (shellHit.y <= 0.0) return;

  float startT = max(shellHit.x, 0.0);
  float endT = min(shellHit.y, sceneT);
  if (endT <= startT) return;

  float stepLen = (endT - startT) / float(GE_CLOUD_STEPS);
  float jitter = hash21(fragCoord + 9.7);
  vec3 cloudLight = uTheme < 0.5
    ? mix(uInk, accentRamp(0.67), 0.14)
    : mix(uBg, uInk, 0.035);
  vec3 cloudShade = mix(uBg, accentRamp(0.58), mix(0.48, 0.24, uTheme));
  float forwardLobe = pow(ge_sat(dot(rd, sunDir)), 7.0);

  for (int i = 0; i < GE_CLOUD_STEPS; i++) {
    float travel = startT + (float(i) + jitter) * stepLen;
    vec3 pos = ro + rd * travel;
    float density = ge_cloudDensity(pos);
    if (density > 0.008) {
      vec3 radial = normalize(pos);
      float sunFacing = smoothstep(-0.12, 0.58, dot(radial, sunDir));
      float silver = (1.0 - smoothstep(0.32, 0.78, density)) * sunFacing;
      vec3 localColor = mix(cloudShade, cloudLight, 0.22 + 0.7 * sunFacing);
      localColor += cloudLight * silver * (0.12 + 0.25 * forwardLobe);
      float alpha = 1.0 - exp(-density * stepLen * 31.0);
      cloudColor += cloudTrans * alpha * localColor;
      cloudTrans *= 1.0 - alpha;
      if (cloudTrans < 0.045) break;
    }
  }
}

// Dipole coordinates use r = L sin²(theta). Selecting a narrow L-shell creates
// an auroral oval whose curtains genuinely follow magnetic field geometry.
float ge_auroraDensity(vec3 worldPos, float worldSpin, out float altitude){
  vec3 magneticPos = ge_rotY(worldPos, worldSpin * 0.33 + 0.18);
  magneticPos = ge_rotX(magneticPos, -0.19);
  float radius = length(magneticPos);
  altitude = (radius - GE_AURORA_BASE) / (GE_AURORA_TOP - GE_AURORA_BASE);
  if (altitude <= 0.0 || altitude >= 1.0) return 0.0;

  vec3 direction = magneticPos / radius;
  float sinTheta2 = max(1.0 - direction.y * direction.y, 0.018);
  float lShell = radius / sinTheta2;
  float fieldRibbon = exp(-pow((lShell - 5.9) / 1.15, 2.0));
  if (fieldRibbon < 0.002) return 0.0;

  float longitude = atan(direction.z, direction.x);
  vec3 foldPos = vec3(cos(longitude) * 7.5, sin(longitude) * 7.5, altitude * 13.0);
  float folds = 0.5 + 0.5 * snoise(foldPos + vec3(0.0, 0.0, uTime * 0.075));
  float curtain = smoothstep(0.33, 0.82, folds);
  float vertical = smoothstep(0.0, 0.16, altitude) * (1.0 - smoothstep(0.78, 1.0, altitude));
  return fieldRibbon * vertical * (0.18 + 0.82 * curtain);
}

vec3 ge_auroraMarch(
  vec3 ro,
  vec3 rd,
  vec3 sunDir,
  float sceneT,
  vec2 fragCoord,
  float worldSpin
){
  vec2 shellHit = ge_sphereHit(ro, rd, GE_AURORA_TOP);
  if (shellHit.y <= 0.0) return vec3(0.0);

  float startT = max(shellHit.x, 0.0);
  float endT = min(shellHit.y, sceneT);
  if (endT <= startT) return vec3(0.0);

  // Coherent branch: most screen tiles never approach either magnetic oval.
  vec3 midPos = ro + rd * mix(startT, endT, 0.52);
  vec3 magneticProbe = ge_rotX(ge_rotY(midPos, worldSpin * 0.33 + 0.18), -0.19);
  float probeLatitude = abs(magneticProbe.y) / max(length(magneticProbe), 1e-3);
  if (probeLatitude < 0.55) return vec3(0.0);

  float stepLen = (endT - startT) / float(GE_AURORA_STEPS);
  float jitter = hash21(fragCoord + 37.0);
  vec3 acc = vec3(0.0);
  for (int i = 0; i < GE_AURORA_STEPS; i++) {
    float travel = startT + (float(i) + jitter) * stepLen;
    vec3 pos = ro + rd * travel;
    float altitude;
    float density = ge_auroraDensity(pos, worldSpin, altitude);
    if (density > 0.002) {
      float night = 1.0 - smoothstep(-0.12, 0.2, dot(normalize(pos), sunDir));
      vec3 lowEmission = accentRamp(0.36);
      vec3 highEmission = accentRamp(0.57);
      vec3 emission = mix(lowEmission, highEmission, smoothstep(0.35, 0.9, altitude));
      float ripple = 0.82 + 0.18 * sin(uTime * 0.42 + travel * 21.0);
      acc += emission * density * night * ripple * stepLen * 7.8;
    }
  }
  return acc * mix(1.0, 0.28, uTheme) * (0.65 + 0.55 * uIntensity);
}

// Five-point physical density integral through the thin atmosphere. Rayleigh
// and Mie extinction share the same geometric optical depth, while their phase
// functions and palette-derived spectra remain separate.
void ge_atmosphere(
  vec3 ro,
  vec3 rd,
  vec3 sunDir,
  float sceneT,
  vec2 fragCoord,
  out vec3 inScatter,
  out vec3 transmittance
){
  inScatter = vec3(0.0);
  transmittance = vec3(1.0);
  vec2 atmosHit = ge_sphereHit(ro, rd, GE_ATMOS_R);
  if (atmosHit.y <= 0.0) return;

  float startT = max(atmosHit.x, 0.0);
  float endT = min(atmosHit.y, sceneT);
  if (endT <= startT) return;

  float stepLen = (endT - startT) / float(GE_ATMOS_STEPS);
  float jitter = hash21(fragCoord + 71.0);
  float viewRayleigh = 0.0;
  float viewMie = 0.0;
  vec3 sumRayleigh = vec3(0.0);
  vec3 sumMie = vec3(0.0);

  vec3 betaRayleigh = accentRamp(0.8) * mix(5.7, 4.5, uTheme);
  vec3 betaMie = mix(accentRamp(0.08), uInk, 0.18) * mix(1.55, 1.1, uTheme);
  float mu = dot(rd, sunDir);
  float phaseRayleigh = ge_rayleighPhase(mu);
  float phaseMie = ge_miePhase(mu);

  for (int i = 0; i < GE_ATMOS_STEPS; i++) {
    float travel = startT + (float(i) + jitter) * stepLen;
    vec3 pos = ro + rd * travel;
    float radius = length(pos);
    float height = ge_sat((radius - GE_PLANET_R) / (GE_ATMOS_R - GE_PLANET_R));
    float densityRayleigh = exp(-height * 4.25);
    float densityMie = exp(-height * 12.5);

    viewRayleigh += densityRayleigh * stepLen;
    viewMie += densityMie * stepLen;

    // Direct sunlight is blocked only when the exact sun ray intersects the
    // solid planet. The remaining solar path to the atmosphere boundary gives
    // the long optical depth that naturally creates the golden terminator band.
    vec2 planetTowardSun = ge_sphereHit(pos + sunDir * 0.0015, sunDir, GE_PLANET_R);
    float sunVisible = planetTowardSun.x > 0.0 ? 0.0 : 1.0;
    vec2 outerTowardSun = ge_sphereHit(pos, sunDir, GE_ATMOS_R);
    float solarLength = max(outerTowardSun.y, 0.0);
    float solarRayleigh = densityRayleigh * solarLength * 0.58;
    float solarMie = densityMie * solarLength * 0.72;

    vec3 extinction =
      betaRayleigh * (viewRayleigh + solarRayleigh) +
      betaMie * (viewMie + solarMie);
    vec3 attenuation = exp(-extinction);
    sumRayleigh += attenuation * densityRayleigh * sunVisible * stepLen;
    sumMie += attenuation * densityMie * sunVisible * stepLen;
  }

  transmittance = exp(-(betaRayleigh * viewRayleigh + betaMie * viewMie));
  inScatter =
    sumRayleigh * betaRayleigh * phaseRayleigh +
    sumMie * betaMie * phaseMie;
  inScatter *= mix(1.48, 1.12, uTheme) * (0.7 + 0.42 * uIntensity);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / max(uResolution.y, 1.0);

  // Scroll is altitude. Velocity adds only a tiny inertial nudge and is clamped,
  // so aggressive trackpads can never cross the planet or fling the camera away.
  float scrollNorm = uScroll.y > 0.0 ? ge_sat(uScroll.x / uScroll.y) : 0.0;
  float altitudeMix = ge_sat(smoothstep(0.03, 0.97, scrollNorm) + uScrollVel * 0.0012);
  float cameraDistance = mix(3.46, 1.47, altitudeMix);
  float focalLength = mix(1.48, 1.22, altitudeMix);

  float pointerYaw = (uPointer.x - 0.5) * 5.0;
  float pointerPitch = clamp((uPointer.y - 0.5) * 1.65, -0.82, 0.82);
  float yaw = uTime * 0.018 + pointerYaw * uPointerActive;
  float pitch = mix(0.16, pointerPitch, uPointerActive);

  vec3 ro = cameraDistance * vec3(
    sin(yaw) * cos(pitch),
    sin(pitch),
    cos(yaw) * cos(pitch)
  );
  vec3 forward = normalize(-ro);
  vec3 right = normalize(cross(forward, vec3(0.0, 1.0, 0.0)));
  vec3 cameraUp = normalize(cross(right, forward));
  vec3 rd = normalize(forward * focalLength + right * p.x + cameraUp * p.y);

  // A fixed stellar light with a tiny seasonal arc; the terrain rotates beneath
  // it, so the terminator continuously reveals and extinguishes cities.
  vec3 sunDir = normalize(vec3(
    -0.68 + 0.08 * sin(uTime * 0.011),
    0.29 + 0.04 * cos(uTime * 0.009),
    0.78
  ));
  float worldSpin = uTime * 0.031;

  vec3 col = ge_space(rd, fragCoord);
  vec2 planetHit = ge_sphereHit(ro, rd, GE_PLANET_R);
  vec2 outerHit = ge_sphereHit(ro, rd, GE_AURORA_TOP);
  if (outerHit.y <= 0.0) return col;

  float planetT = planetHit.x > 0.0 ? planetHit.x : -1.0;
  float sceneT = planetT > 0.0 ? planetT : outerHit.y;
  if (planetT > 0.0) {
    vec3 hitPos = ro + rd * planetT;
    col = ge_surface(hitPos, normalize(ro - hitPos), sunDir, worldSpin);
  }

  // Clouds are a real shell volume and composite front-to-back over the surface.
  vec3 cloudColor;
  float cloudTrans;
  ge_cloudMarch(ro, rd, sunDir, sceneT, fragCoord, cloudColor, cloudTrans);
  col = cloudColor + cloudTrans * col;

  // Magnetic emission lives above the cloud deck. Its low/high altitude colors
  // follow the requested green→red/purple palette span.
  col += ge_auroraMarch(ro, rd, sunDir, sceneT, fragCoord, worldSpin);

  // Atmosphere is the final participating medium between the camera and scene.
  vec2 atmosHit = ge_sphereHit(ro, rd, GE_ATMOS_R);
  if (atmosHit.y > 0.0) {
    float atmosEnd = planetT > 0.0 ? planetT : atmosHit.y;
    vec3 inScatter;
    vec3 transmittance;
    ge_atmosphere(ro, rd, sunDir, atmosEnd, fragCoord, inScatter, transmittance);
    col = col * transmittance + inScatter;
  }

  // Protect foreground-glass legibility without flattening the luminous limb.
  float vignette = 1.0 - smoothstep(0.34, 1.45, length(p * vec2(0.88, 1.0)));
  col = mix(uBg, col, 0.88 + 0.12 * vignette);
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}