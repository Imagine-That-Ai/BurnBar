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

uniform vec2 uDragRotation;

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


const float HS_PI             = 3.141592653589793;
const float HS_TAU            = 6.283185307179586;
const float HS_PHI_HALF       = 0.809016994374947;
const float HS_INV_PHI_HALF   = 0.309016994374947;
const float HS_INV_SQRT_TWO   = 0.707106781186548;
const float HS_SIMPLEX_RADIUS = 0.559016994374947;

struct HsScene {
  vec4 rotation4;
  vec4 rotation3;
  vec2 parallax;
  float fit;
  float camera4;
  float pixel;
  float aa;
  vec4 light4;
};

struct HsProjected {
  vec2 point;
  float depth;
  float scale;
};

struct HsTrace {
  vec3 emission;
  float coverage;
  float glass;
};

HsTrace hsTraceNew() {
  HsTrace trace;
  trace.emission = vec3(0.0);
  trace.coverage = 0.0;
  trace.glass = 0.0;
  return trace;
}

vec4 hsAxis4(int axis, float value) {
  if (axis == 0) return vec4(value, 0.0, 0.0, 0.0);
  if (axis == 1) return vec4(0.0, value, 0.0, 0.0);
  if (axis == 2) return vec4(0.0, 0.0, value, 0.0);
  return vec4(0.0, 0.0, 0.0, value);
}

vec4 hsRotate4(vec4 p, HsScene scene) {
  // Orthogonal planes commute: this is a genuine SO(4) double rotation.
  // r = cos(XW), sin(XW), cos(YZ), sin(YZ), cached once per fragment.
  vec4 r = scene.rotation4;
  float x = r.x * p.x - r.y * p.w;
  float w = r.y * p.x + r.x * p.w;
  float y = r.z * p.y - r.w * p.z;
  float z = r.w * p.y + r.z * p.z;
  return vec4(x, y, z, w);
}

vec3 hsRotateView(vec3 p, HsScene scene) {
  // r = cos(Y), sin(Y), cos(X), sin(X), likewise cached once.
  vec4 r = scene.rotation3;
  vec3 aroundY = vec3(r.x * p.x + r.y * p.z, p.y, -r.y * p.x + r.x * p.z);
  return vec3(
    aroundY.x,
    r.z * aroundY.y - r.w * aroundY.z,
    r.w * aroundY.y + r.z * aroundY.z
  );
}

HsProjected hsProject4(vec4 vertex, HsScene scene) {
  // First perspective divide: a 4D camera looking along W into XYZ.
  float denominator4 = max(scene.camera4 - vertex.w, 1.75);
  float perspective4 = 1.62 / denominator4;
  vec3 point3 = hsRotateView(vertex.xyz * perspective4, scene);

  // Second perspective divide: the projected XYZ world into the screen.
  float denominator3 = max(3.25 - point3.z, 2.0);
  float perspective3 = 2.25 / denominator3;

  float near4 = clamp(vertex.w * 0.5 + 0.5, 0.0, 1.0);
  float near3 = clamp(point3.z * 0.78 + 0.5, 0.0, 1.0);

  HsProjected projected;
  projected.point = point3.xy * perspective3 * scene.fit;
  projected.depth = mix(0.56, 1.34, near4 * 0.64 + near3 * 0.36);
  projected.scale = clamp(perspective4 * perspective3 * 2.05, 0.62, 1.58);
  return projected;
}

float hsSegmentDistance2(vec2 p, vec2 a, vec2 b, out float along) {
  vec2 ab = b - a;
  float denominator = max(dot(ab, ab), 1e-7);
  along = clamp(dot(p - a, ab) / denominator, 0.0, 1.0);
  vec2 delta = p - (a + ab * along);
  return dot(delta, delta);
}

void hsAddEdge(
  inout HsTrace trace,
  vec2 p,
  vec4 vertexA,
  vec4 vertexB,
  HsScene scene,
  float lineScale,
  float nodeWeight,
  float glassWeight,
  float hueBias
) {
  vec4 rotatedA = hsRotate4(vertexA, scene);
  vec4 rotatedB = hsRotate4(vertexB, scene);
  HsProjected projectedA = hsProject4(rotatedA, scene);
  HsProjected projectedB = hsProject4(rotatedB, scene);

  // Coarse segment-AABB rejection avoids distance, AA, lighting, and palette
  // work for almost every edge at almost every pixel. The larger endpoint
  // perspective makes the bound conservative for a widening segment.
  float maxPerspective = max(projectedA.scale, projectedB.scale);
  float maxWidth = scene.pixel * lineScale * (0.84 + 0.66 * maxPerspective);
  float reach = maxWidth * 7.2 + scene.aa;
  vec2 lower = min(projectedA.point, projectedB.point) - reach;
  vec2 upper = max(projectedA.point, projectedB.point) + reach;
  if (p.x < lower.x || p.y < lower.y || p.x > upper.x || p.y > upper.y) return;

  float along = 0.0;
  float distanceToEdge2 = hsSegmentDistance2(
    p,
    projectedA.point,
    projectedB.point,
    along
  );
  float perspective = mix(projectedA.scale, projectedB.scale, along);
  float depth = mix(projectedA.depth, projectedB.depth, along);
  float width = scene.pixel * lineScale * (0.84 + 0.66 * perspective);
  float haloRadius = width * 7.2 + scene.aa;
  if (distanceToEdge2 > haloRadius * haloRadius) return;
  float distanceToEdge = sqrt(distanceToEdge2);

  float core = 1.0 - smoothstep(width, width + scene.aa, distanceToEdge);
  float filament = 1.0 - smoothstep(
    width * 0.22,
    width * 0.72 + scene.aa * 0.35,
    distanceToEdge
  );
  float halo = 1.0 - smoothstep(width + scene.aa, haloRadius, distanceToEdge);

  // Endpoint lights reuse the segment's projection work. Squared distances
  // avoid two extra roots; nodeWeight compensates for topology vertex degree.
  vec2 toA = p - projectedA.point;
  vec2 toB = p - projectedB.point;
  float nodeDistance2 = min(dot(toA, toA), dot(toB, toB));
  float nodeRadius = width * (2.35 + 0.55 * perspective);
  float node = 1.0 - smoothstep(
    nodeRadius * nodeRadius,
    (nodeRadius + scene.aa) * (nodeRadius + scene.aa),
    nodeDistance2
  );

  vec4 radial = mix(rotatedA, rotatedB, along);
  vec4 normal4 = radial * inversesqrt(max(dot(radial, radial), 1e-6));
  float orientation = clamp(dot(normal4, scene.light4) * 0.5 + 0.5, 0.0, 1.0);
  float rampPosition = clamp(orientation * 0.78 + hueBias, 0.0, 1.0);
  vec3 edgeColor = accentRamp(rampPosition);
  vec3 hotCore = mix(edgeColor, uInk, 0.48);

  float edgeEnergy = (core * 0.74 + halo * 0.11 + node * nodeWeight * 1.2) * depth;
  float coreEnergy = filament * (0.72 + 0.44 * depth);
  trace.emission += edgeColor * edgeEnergy + hotCore * coreEnergy;
  trace.coverage += (core * 0.78 + halo * 0.055 + node * nodeWeight * 0.9) * depth;
  trace.glass += halo * glassWeight * depth;
}

vec4 hsSimplexVertex(int index) {
  float r = HS_SIMPLEX_RADIUS;
  if (index == 0) return vec4( r,  r,  r, -0.25);
  if (index == 1) return vec4( r, -r, -r, -0.25);
  if (index == 2) return vec4(-r,  r, -r, -0.25);
  if (index == 3) return vec4(-r, -r,  r, -0.25);
  return vec4(0.0, 0.0, 0.0, 1.0);
}

void hsSimplexPair(int edge, out int a, out int b) {
  a = 0;
  b = 1;
  if (edge == 1) { a = 0; b = 2; }
  else if (edge == 2) { a = 0; b = 3; }
  else if (edge == 3) { a = 0; b = 4; }
  else if (edge == 4) { a = 1; b = 2; }
  else if (edge == 5) { a = 1; b = 3; }
  else if (edge == 6) { a = 1; b = 4; }
  else if (edge == 7) { a = 2; b = 3; }
  else if (edge == 8) { a = 2; b = 4; }
  else if (edge == 9) { a = 3; b = 4; }
}

void hsRenderSimplex(inout HsTrace trace, vec2 p, HsScene scene) {
  for (int edge = 0; edge < 10; edge++) {
    int a = 0;
    int b = 1;
    hsSimplexPair(edge, a, b);
    hsAddEdge(trace, p, hsSimplexVertex(a), hsSimplexVertex(b), scene, 1.08, 0.25, 0.060, 0.03);
  }
}

vec4 hsTesseractVertex(int index) {
  return vec4(
    ((index & 1) == 0) ? -0.5 : 0.5,
    ((index & 2) == 0) ? -0.5 : 0.5,
    ((index & 4) == 0) ? -0.5 : 0.5,
    ((index & 8) == 0) ? -0.5 : 0.5
  );
}

int hsInsertZeroBit(int compact, int axis) {
  int lowerMask = (1 << axis) - 1;
  int lower = compact & lowerMask;
  int upper = compact >> axis;
  return lower | (upper << (axis + 1));
}

void hsRenderTesseract(inout HsTrace trace, vec2 p, HsScene scene) {
  for (int edge = 0; edge < 32; edge++) {
    int axis = edge / 8;
    int compact = edge - axis * 8;
    int a = hsInsertZeroBit(compact, axis);
    int b = a | (1 << axis);
    hsAddEdge(trace, p, hsTesseractVertex(a), hsTesseractVertex(b), scene, 0.96, 0.25, 0.025, 0.09);
  }
}

void hsAxisPair(int pairIndex, out int a, out int b) {
  a = 0;
  b = 1;
  if (pairIndex == 1) { a = 0; b = 2; }
  else if (pairIndex == 2) { a = 0; b = 3; }
  else if (pairIndex == 3) { a = 1; b = 2; }
  else if (pairIndex == 4) { a = 1; b = 3; }
  else if (pairIndex == 5) { a = 2; b = 3; }
}

void hsRenderSixteenCell(inout HsTrace trace, vec2 p, HsScene scene) {
  for (int edge = 0; edge < 24; edge++) {
    int pairIndex = edge / 4;
    int signs = edge - pairIndex * 4;
    int axisA = 0;
    int axisB = 1;
    hsAxisPair(pairIndex, axisA, axisB);
    float signA = ((signs & 1) == 0) ? -1.0 : 1.0;
    float signB = ((signs & 2) == 0) ? -1.0 : 1.0;
    hsAddEdge(
      trace,
      p,
      hsAxis4(axisA, signA),
      hsAxis4(axisB, signB),
      scene,
      0.91,
      0.166666667,
      0.030,
      0.17
    );
  }
}

void hsTwentyFourTriple(int triple, out int sharedAxis, out int a, out int b) {
  sharedAxis = 0;
  a = 1;
  b = 2;
  if (triple == 1) { sharedAxis = 0; a = 1; b = 3; }
  else if (triple == 2) { sharedAxis = 0; a = 2; b = 3; }
  else if (triple == 3) { sharedAxis = 1; a = 0; b = 2; }
  else if (triple == 4) { sharedAxis = 1; a = 0; b = 3; }
  else if (triple == 5) { sharedAxis = 1; a = 2; b = 3; }
  else if (triple == 6) { sharedAxis = 2; a = 0; b = 1; }
  else if (triple == 7) { sharedAxis = 2; a = 0; b = 3; }
  else if (triple == 8) { sharedAxis = 2; a = 1; b = 3; }
  else if (triple == 9) { sharedAxis = 3; a = 0; b = 1; }
  else if (triple == 10) { sharedAxis = 3; a = 0; b = 2; }
  else if (triple == 11) { sharedAxis = 3; a = 1; b = 2; }
}

void hsRenderTwentyFourCell(inout HsTrace trace, vec2 p, HsScene scene) {
  // Every edge joins two (±1, ±1, 0, 0)/√2 vertices sharing one signed
  // coordinate. 12 shared-axis triples × 8 sign choices = 96 exact edges.
  for (int edge = 0; edge < 96; edge++) {
    int triple = edge / 8;
    int signs = edge - triple * 8;
    int sharedAxis = 0;
    int axisA = 1;
    int axisB = 2;
    hsTwentyFourTriple(triple, sharedAxis, axisA, axisB);
    float signShared = ((signs & 1) == 0) ? -HS_INV_SQRT_TWO : HS_INV_SQRT_TWO;
    float signA = ((signs & 2) == 0) ? -HS_INV_SQRT_TWO : HS_INV_SQRT_TWO;
    float signB = ((signs & 4) == 0) ? -HS_INV_SQRT_TWO : HS_INV_SQRT_TWO;
    vec4 vertexA = hsAxis4(sharedAxis, signShared) + hsAxis4(axisA, signA);
    vec4 vertexB = hsAxis4(sharedAxis, signShared) + hsAxis4(axisB, signB);
    hsAddEdge(trace, p, vertexA, vertexB, scene, 0.74, 0.125, 0.010, 0.25);
  }
}

vec4 hsQuaternionMultiply(vec4 q, vec4 r) {
  // Scalar-first convention: q.x is real and q.yzw is imaginary.
  float scalar = q.x * r.x - dot(q.yzw, r.yzw);
  vec3 vector = q.x * r.yzw + r.x * q.yzw + cross(q.yzw, r.yzw);
  return vec4(scalar, vector);
}

vec4 hsSixHundredSeed(int cycle) {
  // Twelve representatives for the generator's twelve disjoint decagonal
  // orbits: four negative axis vertices, then eight half-coordinate vertices.
  if (cycle < 4) return hsAxis4(cycle, -1.0);
  int bits = cycle - 4;
  return vec4(
    ((bits & 1) == 0) ? -0.5 : 0.5,
    ((bits & 2) == 0) ? -0.5 : 0.5,
    ((bits & 4) == 0) ? -0.5 : 0.5,
    -0.5
  );
}

void hsRenderSixHundredCell(inout HsTrace trace, vec2 p, HsScene scene) {
  // The binary icosahedral vertices decompose into twelve disjoint cycles under
  // right-multiplication by this order-ten unit quaternion. Each multiplication
  // preserves unit length and advances to an exact adjacent 600-cell vertex:
  // dot(q, q·g) = φ/2. Twelve cycles × ten edges visit all 120 vertices once,
  // yielding an exact, bounded geodesic skeleton without 120 index branches or
  // the complete polytope's prohibitively dense 720 projected edges.
  const vec4 generator = vec4(HS_PHI_HALF, 0.0, 0.5, HS_INV_PHI_HALF);
  for (int cycle = 0; cycle < 12; cycle++) {
    vec4 a = hsSixHundredSeed(cycle);
    for (int stepIndex = 0; stepIndex < 10; stepIndex++) {
      vec4 b = hsQuaternionMultiply(a, generator);
      hsAddEdge(trace, p, a, b, scene, 0.60, 0.50, 0.008, 0.35);
      a = b;
    }
  }
}

int hsExhibitionKind(float cycle) {
  int slot = int(mod(floor(cycle), 6.0));
  if (slot == 0 || slot == 5) return 3; // 24-cell: recurring centerpiece.
  if (slot == 1) return 1;              // 8-cell / tesseract.
  if (slot == 2) return 2;              // 16-cell.
  if (slot == 3) return 0;              // 5-cell.
  return 4;                              // 600-cell.
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 p = (fragCoord - 0.5 * uResolution) / max(uResolution.y, 1.0);
  float aspect = uResolution.x / max(uResolution.y, 1.0);

  // Every projected vertex remains inside radius 0.47 for this camera. The
  // extra margin preserves wide low-resolution halos while skipping most of a
  // landscape canvas before any topology work begins.
  if (dot(p, p) > 0.410) return uBg;

  // uTime is exactly zero for renderStatic(). Gating every interaction term
  // makes the still deterministic even after prior drag or scroll input.
  float live = step(0.0001, uTime);
  float scrollProgress = (uScroll.y > 0.5) ? clamp(uScroll.x / uScroll.y, 0.0, 1.0) : 0.0;
  float scrollImpulse = clamp(uScrollVel, -120.0, 120.0) * 0.0025;
  float scrollAngle = scrollProgress * HS_TAU * 1.35 + scrollImpulse;
  vec2 angles = vec2(HS_PI * 0.25, HS_PI * 0.125) + live * vec2(
    uTime * 0.105 + uDragRotation.x,
    uTime * 0.067 + scrollAngle
  );

  HsScene scene;
  scene.parallax = (uPointer - 0.5) * uPointerActive * live;
  scene.fit = min(1.18, aspect * 1.24);
  scene.camera4 = 3.08 + 0.13 * sin(uTime * 0.087) * live;
  scene.pixel = 1.0 / max(uResolution.y, 1.0);
  scene.aa = scene.pixel * 1.15;
  scene.rotation4 = vec4(
    cos(angles.x),
    sin(angles.x),
    cos(angles.y),
    sin(angles.y)
  );
  float viewY = -0.58 + scene.parallax.x * 0.12;
  float viewX = 0.52 + clamp(uDragRotation.y, -0.68, 0.68) * live
    + scene.parallax.y * 0.08;
  scene.rotation3 = vec4(cos(viewY), sin(viewY), cos(viewX), sin(viewX));
  scene.light4 = normalize(vec4(
    0.52 + scene.parallax.x * 1.05,
    0.68 + scene.parallax.y * 0.82,
    0.46 + 0.16 * sin(uTime * 0.17) * live,
    0.72 + 0.18 * cos(uTime * 0.13) * live
  ));

  // Six gallery bays, with the unique 24-cell shown twice. Fading through a
  // brief void avoids evaluating two topologies during transitions.
  float cycle = uTime / 13.0 + 0.35;
  float phase = fract(cycle);
  float reveal = smoothstep(0.04, 0.14, phase)
    * (1.0 - smoothstep(0.86, 0.97, phase));
  int kind = hsExhibitionKind(cycle);

  HsTrace trace = hsTraceNew();
  if (reveal > 0.001) {
    if (kind == 0) hsRenderSimplex(trace, p, scene);
    else if (kind == 1) hsRenderTesseract(trace, p, scene);
    else if (kind == 2) hsRenderSixteenCell(trace, p, scene);
    else if (kind == 3) hsRenderTwentyFourCell(trace, p, scene);
    else hsRenderSixHundredCell(trace, p, scene);
  }

  float aperture = 1.0 - smoothstep(0.50, 0.63, length(p));
  float sceneAlpha = reveal * aperture;
  float coverage = 1.0 - exp(-trace.coverage * sceneAlpha);
  float glass = (1.0 - exp(-trace.glass * 2.4)) * sceneAlpha;
  float peak = max(max(trace.emission.r, trace.emission.g), trace.emission.b);
  vec3 chroma = (peak > 1e-5) ? trace.emission / peak : accentRamp(0.5);

  float stage = exp(-dot(p, p) * 2.8) * sceneAlpha;
  vec3 col;
  if (uTheme < 0.5) {
    // Dark: actual emitted edge energy over the void, compressed only once.
    vec3 light = trace.emission * sceneAlpha * (0.64 + 0.72 * uIntensity);
    light += chroma * glass * (0.08 + 0.12 * uIntensity);
    light += accentRamp(0.52) * stage * 0.012 * uIntensity;
    light = light / (vec3(1.0) + light);
    col = uBg + light * (vec3(1.0) - uBg);
  } else {
    // Light: a crystal specimen printed into pale ground, never additive white.
    vec3 crystalInk = mix(uInk, chroma, 0.58);
    float deposit = coverage * (0.46 + 0.38 * uIntensity);
    col = mix(uBg, crystalInk, deposit);
    col = mix(col, mix(uBg, chroma, 0.62), glass * 0.18 * uIntensity);
  }

  // Edge-of-canvas quieting preserves page text contrast. MAIN supplies the
  // shared ordered dither and final clamp.
  float vignette = 1.0 - smoothstep(0.42, 1.02, length(uv - 0.5) * 1.35);
  col = mix(uBg, col, 0.80 + 0.20 * vignette);
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}