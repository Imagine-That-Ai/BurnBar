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


const float KF_TAU = 6.28318530717958647692;
const int KF_MARCH_STEPS = 36;

struct KfScene {
  float tube;
  float membrane;
  float flow;
  float component;
};

// Frame-wide state. It is assigned once in renderKernel and read by the map;
// keeping it global avoids threading six invariant arguments through every
// distance call in the hot loop.
float kfMode;
float kfEntangle;
float kfPass;
float kfSceneOpacity;
float kfFlowClock;
float kfPointerForce;
vec3 kfPointerObject;
// Frame-constant trefoil oscillators. These depend only on uTime/kfEntangle, so
// they are identical for every pixel and every march step in a frame; renderKernel
// evaluates the three sines once per pixel and the hot loop (≈40 SDF/normal
// samples) reads these instead of re-deriving them each sample.
float kfTreWob;    // minor-phase wobble
float kfTreMajorR; // major radius
float kfTreMinorR; // minor radius, already scaled by kfEntangle

KfScene kfEmptyScene(){
  KfScene s;
  s.tube = 1e4;
  s.membrane = 1e4;
  s.flow = 0.0;
  s.component = 0.0;
  return s;
}

void kfPushTube(inout KfScene s, float d, float flow, float component){
  if (d < s.tube) {
    s.tube = d;
    s.flow = fract(flow);
    s.component = component;
  }
}

float kfSegmentDistance(vec3 p, vec3 a, vec3 b){
  vec3 ba = b - a;
  float h = clamp(dot(p - a, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
  return length(p - (a + ba * h));
}

float kfDiskXZ(vec3 p, float radius){
  float outside = max(length(p.xz) - radius, 0.0);
  return length(vec2(outside, p.y));
}

float kfDiskXY(vec3 p, float radius){
  float outside = max(length(p.xy) - radius, 0.0);
  return length(vec2(outside, p.z));
}

float kfEllipseDiskXY(vec3 p, float a, float b){
  float scaledRadius = length(vec2(p.x / a, p.y / b));
  float outside = max(scaledRadius - 1.0, 0.0) * min(a, b);
  return length(vec2(outside, p.z));
}

float kfEllipseDiskYZ(vec3 p, float a, float b){
  float scaledRadius = length(vec2(p.y / a, p.z / b));
  float outside = max(scaledRadius - 1.0, 0.0) * min(a, b);
  return length(vec2(outside, p.x));
}

float kfEllipseDiskZX(vec3 p, float a, float b){
  float scaledRadius = length(vec2(p.z / a, p.x / b));
  float outside = max(scaledRadius - 1.0, 0.0) * min(a, b);
  return length(vec2(outside, p.y));
}

vec3 kfRotateX(vec3 p, float a){
  float c = cos(a);
  float s = sin(a);
  return vec3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}

vec3 kfRotateY(vec3 p, float a){
  float c = cos(a);
  float s = sin(a);
  return vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

// An ambient-space inverse warp. The coefficient is intentionally small enough
// to remain smooth and one-to-one: the user can bend the embedding, not cut it.
vec3 kfPointerWarp(vec3 p){
  // Idle frames (no hover) carry zero force, which makes every term below
  // vanish identically — so return the point untouched and skip the exp/sin/
  // length. This runs inside every SDF sample and every normal tap, so the
  // early-out is what keeps the raymarch cheap while the cursor is at rest.
  if (kfPointerForce <= 0.0) return p;
  vec3 delta = p - kfPointerObject;
  float radius2 = dot(delta, delta);
  float influence = kfPointerForce * exp(-radius2 * 2.20);
  p += delta * (0.24 * influence);
  p.z += 0.040 * influence * sin(4.5 * length(delta.xy) - uTime * 1.15);
  return p;
}

KfScene kfTrefoilScene(vec3 p){
  KfScene s = kfEmptyScene();

  float rho = max(length(p.xz), 1e-5);
  vec2 radial = p.xz / rho;
  float majorAngle = atan(radial.y, radial.x);
  if (majorAngle < 0.0) majorAngle += KF_TAU;

  // T(2,3): for a fixed major angle there are exactly two candidate branches.
  // The second branch is the antipode of the torus cross-section, so one set of
  // trig evaluations yields both centerline points.
  float t0 = 0.5 * majorAngle;
  float minorPhase = 1.5 * majorAngle + kfTreWob;
  float majorRadius = kfTreMajorR;
  float minorRadius = kfTreMinorR;
  float tubeRadius = 0.072;

  vec3 base = vec3(radial.x * majorRadius, 0.0, radial.y * majorRadius);
  vec3 spoke = minorRadius * vec3(
    radial.x * cos(minorPhase),
    sin(minorPhase),
    radial.y * cos(minorPhase)
  );
  vec3 c0 = base + spoke;
  vec3 c1 = base - spoke;

  float d0 = length(p - c0) - tubeRadius;
  float d1 = length(p - c1) - tubeRadius;
  kfPushTube(s, d0, t0 / KF_TAU, 0.0);
  kfPushTube(s, d1, t0 / KF_TAU + 0.5, 0.0);

  // A compact Seifert-style spanning membrane: two twisted ruled bands meet a
  // small central disk. As the trefoil collapses, it continuously resolves into
  // the ordinary disk bounded by the unknot.
  vec3 spine = base * 0.21;
  float ruled = min(kfSegmentDistance(p, spine, c0), kfSegmentDistance(p, spine, c1));
  ruled = min(ruled, kfDiskXZ(p, majorRadius * 0.23));
  float unknotDisk = kfDiskXZ(p, majorRadius);
  float surfaceBlend = smoothstep(0.04, 0.34, kfEntangle);
  s.membrane = mix(unknotDisk, ruled, surfaceBlend);
  return s;
}

KfScene kfFigureEightScene(vec3 p){
  KfScene s = kfEmptyScene();

  float rho = max(length(p.xz), 1e-5);
  vec2 radial = p.xz / rho;
  float majorAngle = atan(radial.y, radial.x);
  if (majorAngle < 0.0) majorAngle += KF_TAU;

  // Standard figure-eight embedding: major angle = 3t, hence three candidates.
  float t0 = majorAngle / 3.0;
  vec3 spine = vec3(radial.x * 0.13, 0.0, radial.y * 0.13);
  for (int i = 0; i < 3; i++) {
    float t = t0 + float(i) * KF_TAU / 3.0;
    float radialRadius = 0.80 + 0.26 * cos(2.0 * t + uTime * 0.025);
    float height = 0.36 * sin(4.0 * t);
    vec3 c = vec3(radial.x * radialRadius, height, radial.y * radialRadius);
    float d = length(p - c) - 0.068;
    kfPushTube(s, d, t / KF_TAU, 0.0);
    s.membrane = min(s.membrane, kfSegmentDistance(p, spine, c));
  }
  s.membrane = min(s.membrane, kfDiskXZ(p, 0.16));
  return s;
}

KfScene kfHopfScene(vec3 p){
  KfScene s = kfEmptyScene();

  // Two perpendicular circles with one center displaced by exactly one radius:
  // one crossing of either spanning disk lies inside, one outside. Ray depth
  // therefore supplies the over/under relation without painter-order tricks.
  float radius = 0.70;
  float halfOffset = 0.35;
  float tubeRadius = 0.069;

  vec3 localA = p - vec3(-halfOffset, 0.0, 0.0);
  vec2 qa = localA.xy;
  float la = max(length(qa), 1e-5);
  vec2 na = qa / la;
  vec3 cA = vec3(-halfOffset + radius * na.x, radius * na.y, 0.0);
  float flowA = atan(na.y, na.x) / KF_TAU;
  kfPushTube(s, length(p - cA) - tubeRadius, flowA, 0.0);

  vec3 localB = p - vec3(halfOffset, 0.0, 0.0);
  vec2 qb = localB.xz;
  float lb = max(length(qb), 1e-5);
  vec2 nb = qb / lb;
  vec3 cB = vec3(halfOffset + radius * nb.x, 0.0, radius * nb.y);
  float flowB = atan(nb.y, nb.x) / KF_TAU;
  kfPushTube(s, length(p - cB) - tubeRadius, flowB + 0.23, 1.0);

  s.membrane = min(kfDiskXY(localA, radius), kfDiskXZ(localB, radius));
  return s;
}

KfScene kfBorromeanScene(vec3 p){
  KfScene s = kfEmptyScene();

  // Classical cyclic arrangement of three mutually perpendicular ellipses.
  // Each pair has zero linking number; the three-component configuration is the
  // Borromean interlock. Radial projection in scaled ellipse space is a compact,
  // stable nearest-point approximation and keeps this stage inexpensive.
  float a = 0.98;
  float b = 0.49;
  float tubeRadius = 0.060;

  vec2 qA = vec2(p.x / a, p.y / b);
  vec2 nA = qA / max(length(qA), 1e-5);
  vec3 cA = vec3(a * nA.x, b * nA.y, 0.0);
  float dA = length(p - cA) - tubeRadius;

  vec2 qB = vec2(p.y / a, p.z / b);
  vec2 nB = qB / max(length(qB), 1e-5);
  vec3 cB = vec3(0.0, a * nB.x, b * nB.y);
  float dB = length(p - cB) - tubeRadius;

  vec2 qC = vec2(p.z / a, p.x / b);
  vec2 nC = qC / max(length(qC), 1e-5);
  vec3 cC = vec3(b * nC.y, 0.0, a * nC.x);
  float dC = length(p - cC) - tubeRadius;

  kfPushTube(s, dA, atan(nA.y, nA.x) / KF_TAU, 0.0);
  kfPushTube(s, dB, atan(nB.y, nB.x) / KF_TAU + 0.17, 1.0);
  kfPushTube(s, dC, atan(nC.y, nC.x) / KF_TAU + 0.34, 2.0);

  s.membrane = min(
    kfEllipseDiskXY(p, a, b),
    min(kfEllipseDiskYZ(p, a, b), kfEllipseDiskZX(p, a, b))
  );
  return s;
}

KfScene kfScene(vec3 p){
  p = kfPointerWarp(p);
  if (kfMode < 0.5) return kfTrefoilScene(p);
  if (kfMode < 1.5) return kfFigureEightScene(p);
  if (kfMode < 2.5) return kfHopfScene(p);
  return kfBorromeanScene(p);
}

float kfTubeDistance(vec3 p){
  return kfScene(p).tube;
}

vec3 kfNormal(vec3 p){
  // Tetrahedral gradient: four map calls instead of the six-call central form.
  const float e = 0.0042;
  vec3 n =
      vec3( 1.0, -1.0, -1.0) * kfTubeDistance(p + vec3( 1.0, -1.0, -1.0) * e)
    + vec3(-1.0, -1.0,  1.0) * kfTubeDistance(p + vec3(-1.0, -1.0,  1.0) * e)
    + vec3(-1.0,  1.0, -1.0) * kfTubeDistance(p + vec3(-1.0,  1.0, -1.0) * e)
    + vec3( 1.0,  1.0,  1.0) * kfTubeDistance(p + vec3( 1.0,  1.0,  1.0) * e);
  return normalize(n);
}

vec2 kfSphereInterval(vec3 ro, vec3 rd, float radius){
  float b = dot(ro, rd);
  float c = dot(ro, ro) - radius * radius;
  float h = b * b - c;
  if (h < 0.0) return vec2(-1.0);
  h = sqrt(h);
  return vec2(-b - h, -b + h);
}

float kfCircularDistance(float a, float b){
  return abs(fract(a - b + 0.5) - 0.5);
}

vec3 kfBackground(vec2 p, vec2 uv){
  float radial = length(p * vec2(0.86, 1.0));
  float chamber = exp(-radial * radial * 0.85);
  vec3 fieldColor = accentRamp(0.62 + 0.08 * sin(uTime * 0.035));

  vec3 color;
  if (uTheme < 0.5) {
    color = uBg + fieldColor * chamber * (0.026 + 0.035 * uIntensity);
  } else {
    color = mix(uBg, mix(uBg, uInk, 0.10), chamber * 0.13);
    color = mix(color, fieldColor, chamber * 0.018 * uIntensity);
  }

  // Sparse, stable points and two ghosted diagram circles establish scale without
  // spending a noise octave or competing with foreground typography.
  vec2 grid = uv * vec2(104.0 * uResolution.x / max(uResolution.y, 1.0), 104.0);
  vec2 cell = floor(grid);
  vec2 local = fract(grid);
  float starGate = step(0.994, hash21(cell));
  vec2 starAt = vec2(hash21(cell + 11.7), hash21(cell + 37.1));
  float star = starGate * exp(-dot(local - starAt, local - starAt) * 240.0);
  color += mix(uInk, fieldColor, 0.72) * star * (uTheme < 0.5 ? 0.18 : 0.045);

  float diagram = exp(-abs(length(p - vec2(-0.46, 0.10)) - 0.66) * 31.0);
  diagram += exp(-abs(length(p - vec2(0.52, -0.08)) - 0.52) * 34.0);
  color += mix(uInk, fieldColor, 0.58) * diagram * (uTheme < 0.5 ? 0.010 : 0.007);
  return color;
}

vec3 kfShadeTube(vec3 p, vec3 rd, KfScene hit){
  vec3 n = kfNormal(p);
  vec3 lightDir = normalize(vec3(-0.46, 0.70, 0.54));
  vec3 viewDir = -rd;
  vec3 halfDir = normalize(lightDir + viewDir);

  float diffuse = 0.22 + 0.78 * max(dot(n, lightDir), 0.0);
  float specular = pow(max(dot(n, halfDir), 0.0), 52.0);
  float fresnel = pow(1.0 - max(dot(n, viewDir), 0.0), 3.0);

  float movingPhase = fract(hit.flow - kfFlowClock + hit.component * 0.071);
  float current = pow(0.5 + 0.5 * cos(KF_TAU * movingPhase), 13.0);
  float passage = kfPass * exp(-pow(kfCircularDistance(hit.flow, 0.16) * 10.5, 2.0));
  vec3 ramp = accentRamp(fract(hit.flow + hit.component * 0.19 - uTime * 0.026));

  if (uTheme < 0.5) {
    vec3 body = mix(uInk, ramp, 0.82) * diffuse;
    vec3 emission = ramp * (0.24 * fresnel + 1.10 * current + 0.95 * passage);
    vec3 highlight = mix(uInk, ramp, 0.44) * specular * 0.62;
    return body * 0.58 + (emission + highlight) * uIntensity;
  }

  vec3 warmMetal = mix(uInk, ramp, 0.57);
  vec3 body = mix(uBg, warmMetal, 0.72) * (0.54 + 0.46 * diffuse);
  vec3 highlight = mix(uBg, ramp, 0.28) * specular * 0.32;
  vec3 currentInk = mix(ramp, uInk, 0.22) * (0.12 * current + 0.09 * passage);
  return body + highlight + currentInk * uIntensity;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 resolution = max(uResolution, vec2(1.0));
  vec2 screen = (fragCoord - 0.5 * resolution) / resolution.y;

  float scrollProgress = uScroll.y > 1.0
    ? clamp(uScroll.x / uScroll.y, 0.0, 1.0)
    : 0.0;
  float cycle = fract(0.04 + scrollProgress * 0.93 + uTime * 0.012);

  // Exhibit selection and cross-fades. Brief moments of empty field between
  // topologies prevent a hard model pop and give every structure visual dignity.
  if (cycle < 0.62) {
    kfMode = 0.0;
    kfSceneOpacity = smoothstep(0.0, 0.018, cycle)
      * (1.0 - smoothstep(0.590, 0.620, cycle));
  } else if (cycle < 0.76) {
    kfMode = 1.0;
    kfSceneOpacity = smoothstep(0.620, 0.638, cycle)
      * (1.0 - smoothstep(0.742, 0.760, cycle));
  } else if (cycle < 0.88) {
    kfMode = 2.0;
    kfSceneOpacity = smoothstep(0.760, 0.778, cycle)
      * (1.0 - smoothstep(0.862, 0.880, cycle));
  } else {
    kfMode = 3.0;
    kfSceneOpacity = smoothstep(0.880, 0.898, cycle)
      * (1.0 - smoothstep(0.982, 1.000, cycle));
  }

  // Trefoil → singular collapse → unknot → reverse passage. At the singular
  // instant the double-covered torus centerline has the exact geometry of the
  // ordinary circle, so the topology can change without a visual discontinuity.
  if (cycle < 0.20) {
    kfEntangle = 1.0;
  } else if (cycle < 0.335) {
    kfEntangle = 1.0 - smoothstep(0.20, 0.335, cycle);
  } else if (cycle < 0.435) {
    kfEntangle = 0.0;
  } else {
    kfEntangle = smoothstep(0.435, 0.575, cycle);
  }
  kfPass = max(
    1.0 - smoothstep(0.0, 0.033, abs(cycle - 0.330)),
    1.0 - smoothstep(0.0, 0.033, abs(cycle - 0.442))
  );
  kfFlowClock = uTime * 0.082 + scrollProgress * 0.34 + uScrollVel * 0.0012;
  // Precompute the trefoil's frame-constant oscillators once (kfEntangle is final
  // here). The march + normal taps below read the kfTre* globals per sample.
  kfTreWob = 0.08 * sin(uTime * 0.13);
  kfTreMajorR = 0.80 + 0.022 * sin(uTime * 0.17);
  kfTreMinorR = (0.30 + 0.014 * sin(uTime * 0.23)) * kfEntangle;

  vec3 background = kfBackground(screen, uv);
  if (kfSceneOpacity < 0.002) return background;

  // A calm, symmetric specimen angle at t=0 is the reduced-motion still. The
  // living version rotates by only a few degrees per minute-scale beat.
  float yaw = 0.57 + 0.075 * sin(uTime * 0.061);
  float pitch = -0.34 + 0.050 * cos(uTime * 0.047);
  vec3 ro = vec3(0.0, 0.0, 3.55);
  vec3 rd = normalize(vec3(screen, -1.86));
  ro = kfRotateX(kfRotateY(ro, yaw), pitch);
  rd = kfRotateX(kfRotateY(rd, yaw), pitch);

  vec2 pointerScreen = (uPointer * resolution - 0.5 * resolution) / resolution.y;
  vec3 pointerPlane = vec3(pointerScreen * (3.55 / 1.86), 0.0);
  kfPointerObject = kfRotateX(kfRotateY(pointerPlane, yaw), pitch);
  kfPointerForce = uPointerActive;

  vec2 interval = kfSphereInterval(ro, rd, 1.38);
  if (interval.y <= 0.0) return background;

  float travel = max(interval.x, 0.0);
  float farTravel = interval.y;
  float minTube = 1e4;
  float glowFlow = 0.0;
  float glowComponent = 0.0;
  float hitTravel = -1.0;
  KfScene hitSample = kfEmptyScene();

  vec3 membranePremul = vec3(0.0);
  float transmittance = 1.0;

  for (int step = 0; step < KF_MARCH_STEPS; step++) {
    if (travel > farTravel || transmittance < 0.055) break;

    vec3 samplePos = ro + rd * travel;
    KfScene sampleScene = kfScene(samplePos);

    if (sampleScene.tube < minTube) {
      minTube = sampleScene.tube;
      glowFlow = sampleScene.flow;
      glowComponent = sampleScene.component;
    }

    float hitEpsilon = 0.0048 + travel * 0.00055;
    if (sampleScene.tube < hitEpsilon) {
      hitTravel = travel;
      hitSample = sampleScene;
      break;
    }

    // The membrane participates as a very thin volume. Its distance also guides
    // the march so the tube SDF cannot leap over a translucent sheet.
    float guide = min(max(sampleScene.tube, 0.0), sampleScene.membrane + 0.044);
    float stepLength = clamp(guide * 0.60, 0.018, 0.108);
    float membraneDensity = exp(-sampleScene.membrane * 27.0) * kfSceneOpacity;

    // Only shade + composite where the sheet is actually present. The exp above
    // decays so steeply that past this gate a sample adds < ~0.2% alpha, yet the
    // ramp + shimmer + mixes below are the loop's costliest work. Skipping them
    // on the empty majority of samples is what keeps the fold motion buttery.
    if (membraneDensity > 0.0026) {
      float localAlpha = 1.0 - exp(-membraneDensity * stepLength * 7.20);
      localAlpha *= uTheme < 0.5 ? 0.66 : 0.44;

      float shimmer = 0.70 + 0.30 * sin(
        KF_TAU * (sampleScene.flow * 1.7 - uTime * 0.028)
        + dot(samplePos, vec3(1.7, 2.2, -1.3))
      );
      vec3 membraneRamp = accentRamp(fract(
        sampleScene.flow + sampleScene.component * 0.16 - uTime * 0.018
      ));
      vec3 membraneColor = uTheme < 0.5
        ? mix(uInk, membraneRamp, 0.72) * (0.30 + 0.32 * shimmer)
        : mix(uBg, mix(uInk, membraneRamp, 0.52), 0.42 + 0.16 * shimmer);

      membranePremul += transmittance * localAlpha * membraneColor;
      transmittance *= 1.0 - localAlpha;
    }
    travel += stepLength;
  }

  vec3 color = background;
  if (hitTravel > 0.0) {
    vec3 hitPos = ro + rd * hitTravel;
    vec3 surface = kfShadeTube(hitPos, rd, hitSample);
    color = membranePremul + transmittance * mix(background, surface, kfSceneOpacity);
  } else {
    color = membranePremul + transmittance * background;
  }

  float halo = exp(-max(minTube, 0.0) * 17.0) * kfSceneOpacity;
  vec3 haloColor = accentRamp(fract(glowFlow - kfFlowClock + glowComponent * 0.11));
  if (uTheme < 0.5) {
    color += haloColor * halo * 0.105 * uIntensity;
  } else {
    color = mix(color, mix(color, haloColor, 0.18), halo * 0.075 * uIntensity);
  }

  // Keep page copy readable while retaining the luminous center of gravity.
  float vignette = 1.0 - smoothstep(0.48, 1.22, length(screen * vec2(0.88, 1.0)));
  color = mix(uBg, color, 0.74 + 0.26 * vignette);
  return color;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}