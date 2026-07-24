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
uniform sampler2D uGlyphField;
uniform float uGlyphActive;
uniform vec4  uGlyphRect;
uniform float uGlyphPhase;



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


const float PRISMATICA_FLOOR_Y = -1.72;
const float PRISMATICA_NAVE_HALF_WIDTH = 4.34;
const float PRISMATICA_SPRING_Y = 2.18;
const float PRISMATICA_BAY_LENGTH = 4.80;
const float PRISMATICA_MAX_DISTANCE = 36.0;
// Quality budget: ray quality is in step *efficiency* (empty-space skip + SDF
// bounds), not raw step count. Glyphs are analytic billboards (4 texels/px).
const int PRISMATICA_TRACE_STEPS = 36;
const int PRISMATICA_VOLUME_STEPS = 6;

const float PRISMATICA_MAT_FLOOR = 1.0;
const float PRISMATICA_MAT_WALL = 2.0;
const float PRISMATICA_MAT_VAULT = 3.0;
const float PRISMATICA_MAT_COLUMN = 4.0;
const float PRISMATICA_MAT_RIB = 5.0;

float prismaticaSaturate(float value) {
  return clamp(value, 0.0, 1.0);
}

float prismaticaRepeat(float value, float period) {
  return mod(value + 0.5 * period, period) - 0.5 * period;
}

float prismaticaSafeSign(float value) {
  return value < 0.0 ? -1.0 : 1.0;
}

float prismaticaSdBox(vec3 point, vec3 halfSize) {
  vec3 q = abs(point) - halfSize;
  return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float prismaticaSdCappedCylinderY(vec3 point, float halfHeight, float radius) {
  vec2 q = vec2(length(point.xz) - radius, abs(point.y) - halfHeight);
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0));
}

// Polynomial smooth-min — soft unions (base/shaft/capital) without hard creases.
float prismaticaSmin(float a, float b, float k) {
  float h = clamp(0.5 + 0.5 * (b - a) / max(k, 1e-4), 0.0, 1.0);
  return mix(b, a, h) - k * h * (1.0 - h);
}

// Octagonal shaft with beveled edges (roundR softens the 8 hard dihedrals).
// Pure octagon reads as chunky low-poly; a small fillet is what you want here,
// not full MSAA — the silhouette still benefits from the edge AA below.
float prismaticaSdOctagonalPrismY(
  vec3 point,
  float halfHeight,
  float radius
) {
  const float roundR = 0.045;
  vec2 q = abs(point.xz);
  float radial = max(
    q.x * 0.92387953 + q.y * 0.38268343,
    q.x * 0.38268343 + q.y * 0.92387953
  ) - (radius - roundR);
  // Soft blend toward a circle so facets stay present but no longer knife-edge.
  float circle = length(point.xz) - (radius - roundR);
  radial = mix(radial, circle, 0.28);
  radial = radial - roundR;
  vec2 d = vec2(radial, abs(point.y) - halfHeight + roundR);
  return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - roundR;
}

float prismaticaVaultHeight(float x) {
  float halfWidth = PRISMATICA_NAVE_HALF_WIDTH;
  float radius = 2.0 * halfWidth;
  float horizontal = min(abs(x), halfWidth) + halfWidth;
  float arc = sqrt(max(radius * radius - horizontal * horizontal, 0.0));
  return PRISMATICA_SPRING_Y + arc;
}

vec2 prismaticaNearest(vec2 current, vec2 candidate) {
  return candidate.x < current.x ? candidate : current;
}

vec2 prismaticaScene(vec3 point) {
  float floorDistance = point.y - PRISMATICA_FLOOR_Y;
  float wallDistance = PRISMATICA_NAVE_HALF_WIDTH - abs(point.x);
  float vaultY = prismaticaVaultHeight(point.x);
  float vaultDistance = (vaultY - point.y) * 0.56;

  vec2 result = vec2(floorDistance, PRISMATICA_MAT_FLOOR);
  result = prismaticaNearest(
    result,
    vec2(wallDistance, PRISMATICA_MAT_WALL)
  );
  result = prismaticaNearest(
    result,
    vec2(vaultDistance, PRISMATICA_MAT_VAULT)
  );

  float bayZ = prismaticaRepeat(point.z, PRISMATICA_BAY_LENGTH);
  float shaftBottom = PRISMATICA_FLOOR_Y + 0.08;
  float shaftTop = PRISMATICA_SPRING_Y + 0.92;
  float shaftCenter = 0.5 * (shaftBottom + shaftTop);
  float shaftHalfHeight = 0.5 * (shaftTop - shaftBottom);

  // Columns: outer bound first — skip full octagon+smin when clearly farther
  // than the current nearest surface (biggest march win; looks identical).
  for (int sideIndex = 0; sideIndex < 2; sideIndex += 1) {
    float side = sideIndex == 0 ? -1.0 : 1.0;
    float columnX = side * 3.18;
    // Inflated cylinder bound around base (widest part of the column stack).
    float colBound = length(vec2(point.x - columnX, bayZ)) - 0.58;
    if (colBound >= result.x) continue;

    vec3 shaftPoint = vec3(
      point.x - columnX,
      point.y - shaftCenter,
      bayZ
    );
    float shaft = prismaticaSdOctagonalPrismY(
      shaftPoint,
      shaftHalfHeight,
      0.27
    );

    vec3 basePoint = vec3(
      point.x - columnX,
      point.y - (PRISMATICA_FLOOR_Y + 0.17),
      bayZ
    );
    float base = prismaticaSdCappedCylinderY(basePoint, 0.15, 0.43);

    vec3 capitalPoint = vec3(
      point.x - columnX,
      point.y - (shaftTop - 0.06),
      bayZ
    );
    float capital = prismaticaSdCappedCylinderY(
      capitalPoint,
      0.17,
      0.46
    );

    // Soft join base + capital into the shaft so rings don't hard-crease.
    float column = prismaticaSmin(shaft, prismaticaSmin(base, capital, 0.08), 0.07);
    result = prismaticaNearest(
      result,
      vec2(column, PRISMATICA_MAT_COLUMN)
    );
  }

  // Ribs: same bound-then-detail pattern.
  float crossBound = max(abs(bayZ) - 0.2, abs(point.y - vaultY) * 0.4 - 0.25);
  if (crossBound < result.x) {
    float crossRib = max(
      abs(bayZ) - 0.075,
      abs(point.y - vaultY) * 0.52 - 0.078
    );
    result = prismaticaNearest(result, vec2(crossRib, PRISMATICA_MAT_RIB));
  }

  float vaultY0 = prismaticaVaultHeight(0.0);
  float centerBound = length(vec2(point.x, point.y - vaultY0)) - 0.2;
  if (centerBound < result.x) {
    float centerRib = length(vec2(point.x, point.y - vaultY0)) - 0.074;
    result = prismaticaNearest(result, vec2(centerRib, PRISMATICA_MAT_RIB));
  }

  float sideRibX = 1.72;
  float sideRibY = prismaticaVaultHeight(sideRibX);
  float sideBound = length(vec2(abs(point.x) - sideRibX, point.y - sideRibY)) - 0.18;
  if (sideBound < result.x) {
    float sideRibs = length(
      vec2(abs(point.x) - sideRibX, point.y - sideRibY)
    ) - 0.064;
    result = prismaticaNearest(result, vec2(sideRibs, PRISMATICA_MAT_RIB));
  }

  // Cornice: only when near the spring line / wall.
  if (abs(point.y - PRISMATICA_SPRING_Y) < 0.35 && abs(point.x) > 3.5) {
    vec3 cornicePoint = vec3(
      abs(point.x) - (PRISMATICA_NAVE_HALF_WIDTH - 0.055),
      point.y - PRISMATICA_SPRING_Y,
      0.0
    );
    float cornice = prismaticaSdBox(
      cornicePoint,
      vec3(0.085, 0.095, 1000.0)
    );
    result = prismaticaNearest(result, vec2(cornice, PRISMATICA_MAT_RIB));
  }

  return result;
}

vec3 prismaticaNormal(vec3 point, float distanceAlongRay) {
  // Slightly larger eps + tetrahedral gradient reduces faceted normal noise.
  float epsilon = 0.0035 * (1.0 + 0.03 * distanceAlongRay);
  vec2 e = vec2(1.0, -1.0) * 0.57735027 * epsilon;

  return normalize(
    e.xyy * prismaticaScene(point + e.xyy).x +
    e.yyx * prismaticaScene(point + e.yyx).x +
    e.yxy * prismaticaScene(point + e.yxy).x +
    e.xxx * prismaticaScene(point + e.xxx).x
  );
}

vec2 prismaticaTrace(vec3 rayOrigin, vec3 rayDirection) {
  float distanceAlongRay = 0.0;
  float material = 0.0;

  for (int stepIndex = 0; stepIndex < PRISMATICA_TRACE_STEPS; stepIndex += 1) {
    vec2 sceneSample = prismaticaScene(
      rayOrigin + rayDirection * distanceAlongRay
    );
    // Pixel-cone-ish threshold: tighter up close, looser far (same silhouette
    // acuity, fewer wasted micro-steps in empty nave air).
    float hitThreshold = 0.0012 * (1.0 + 0.04 * distanceAlongRay);

    if (sceneSample.x < hitThreshold) {
      material = sceneSample.y;
      break;
    }

    // Over-relax empty space (0.92) — still conservative enough with bounds.
    float step = sceneSample.x * 0.92;
    distanceAlongRay += clamp(step, 0.01, 1.15);

    if (distanceAlongRay > PRISMATICA_MAX_DISTANCE) {
      distanceAlongRay = PRISMATICA_MAX_DISTANCE;
      material = 0.0;
      break;
    }
  }

  return vec2(distanceAlongRay, material);
}

float prismaticaAmbientOcclusion(vec3 point, vec3 normal) {
  // 2 taps (was 3) — columns don't need the third when scrolling.
  float occlusion = 0.0;
  float weight = 0.7;

  for (int sampleIndex = 1; sampleIndex <= 2; sampleIndex += 1) {
    float sampleDistance = 0.13 * float(sampleIndex);
    float sceneDistance = prismaticaScene(
      point + normal * sampleDistance
    ).x;
    occlusion += max(sampleDistance - sceneDistance, 0.0) * weight;
    weight *= 0.5;
  }

  return clamp(1.0 - occlusion * 1.55, 0.34, 1.0);
}

float prismaticaWindowTop(float localZ) {
  const float halfWidth = 1.43;
  const float archSpring = 2.26;
  const float archApex = 5.48;
  float normalized = clamp(abs(localZ) / halfWidth, 0.0, 1.0);
  return mix(archApex, archSpring, pow(normalized, 0.72));
}

vec4 prismaticaWindowSample(vec3 point, float side) {
  const float halfWidth = 1.43;
  const float bottom = -0.58;
  const float archApex = 5.48;

  float localZ = prismaticaRepeat(point.z, PRISMATICA_BAY_LENGTH);
  float bayIndex = floor(
    (point.z + 0.5 * PRISMATICA_BAY_LENGTH) / PRISMATICA_BAY_LENGTH
  );
  float top = prismaticaWindowTop(localZ);

  float horizontalMask = 1.0 - smoothstep(
    halfWidth - 0.055,
    halfWidth + 0.025,
    abs(localZ)
  );
  float bottomMask = smoothstep(bottom - 0.045, bottom + 0.055, point.y);
  float topMask = 1.0 - smoothstep(top - 0.065, top + 0.025, point.y);
  float shapeMask = horizontalMask * bottomMask * topMask;

  float xNormalized = clamp(
    localZ / (2.0 * halfWidth) + 0.5,
    0.0,
    0.9999
  );
  float yNormalized = clamp(
    (point.y - bottom) / (archApex - bottom),
    0.0,
    0.9999
  );

  float paneX = floor(xNormalized * 5.0);
  float paneY = floor(yNormalized * 8.0);
  float palettePosition = fract(
    paneX * 0.173 +
    paneY * 0.119 +
    bayIndex * 0.071 +
    side * 0.137
  );
  vec3 glassColor = accentRamp(palettePosition);

  float verticalPhase = fract(xNormalized * 5.0);
  float horizontalPhase = fract(yNormalized * 8.0);
  float verticalLeadDistance = min(verticalPhase, 1.0 - verticalPhase);
  float horizontalLeadDistance = min(horizontalPhase, 1.0 - horizontalPhase);
  float gridLead = 1.0 - smoothstep(
    0.015,
    0.045,
    min(verticalLeadDistance, horizontalLeadDistance)
  );

  float centerMullion = 1.0 - smoothstep(
    0.010,
    0.030,
    abs(xNormalized - 0.5)
  );

  float traceryZone = smoothstep(2.10, 2.55, point.y);
  vec2 rosePoint = vec2(
    localZ,
    (point.y - 3.10) * 0.78
  );
  float roseRingDistance = abs(length(rosePoint) - 0.56);
  float roseLead = traceryZone * (
    1.0 - smoothstep(0.025, 0.070, roseRingDistance)
  );

  float lead = clamp(max(gridLead, max(centerMullion, roseLead)), 0.0, 1.0);
  float transmission = shapeMask * (1.0 - 0.90 * lead);

  float jewelVariation = 0.88 + 0.12 * hash21(vec2(
    paneX + bayIndex * 7.0,
    paneY + side * 11.0
  ));

  return vec4(glassColor * jewelVariation, transmission);
}

vec3 prismaticaSunDirection() {
  float phase = 0.42 + uTime * 0.018;
  float elevation = -0.31 + 0.055 * sin(phase);
  float longitudinalSweep = 0.16 + 0.075 * sin(phase * 0.71 + 1.30);
  return normalize(vec3(1.0, elevation, longitudinalSweep));
}

vec4 prismaticaProjectedWindow(vec3 point, vec3 sunDirection) {
  float sourceWallX = -PRISMATICA_NAVE_HALF_WIDTH;
  float travel = (point.x - sourceWallX) / max(sunDirection.x, 0.12);

  if (travel < 0.0 || travel > 12.0) {
    return vec4(0.0);
  }

  vec3 wallPoint = point - sunDirection * travel;
  vec4 glass = prismaticaWindowSample(wallPoint, -1.0);
  float depthFade = exp(-0.016 * travel * travel);
  float heightFade = smoothstep(
    PRISMATICA_FLOOR_Y - 0.15,
    PRISMATICA_FLOOR_Y + 0.35,
    point.y
  );

  return vec4(glass.rgb, glass.a * depthFade * heightFade);
}

vec4 prismaticaBeamField(vec3 point, vec3 sunDirection) {
  vec4 projected = prismaticaProjectedWindow(point, sunDirection);
  // Cheap hash flicker instead of snoise — same vibe, far less ALU in the
  // volume loop (called every volume step).
  float airVariation = 0.86 + 0.14 * hash21(floor(point.xz * 2.5) + floor(uTime * 2.0));
  float vaultFade = 1.0 - smoothstep(
    prismaticaVaultHeight(point.x) - 0.55,
    prismaticaVaultHeight(point.x) + 0.10,
    point.y
  );

  projected.a *= airVariation * vaultFade;
  return projected;
}

// ── Glyph wisps (analytic billboards — NOT sampled every volume step) ───────
// 4 medium marks; each costs ~1 texture fetch per pixel, not per volume sample.
// That was the scroll freefall: 18 vol × 5 wisps × 4 snoise.

const int PRISMATICA_WISP_COUNT = 4;

float prismaticaWalkGate() {
  float scrollAbs = abs(uScroll.x);
  float velAbs = abs(uScrollVel);
  float fromScroll = smoothstep(10.0, 70.0, scrollAbs);
  float fromVel = smoothstep(0.05, 0.32, velAbs);
  return clamp(fromScroll + fromVel * 0.95, 0.0, 1.0);
}

float prismaticaWalkDepth() {
  float s = uScroll.x;
  float dir = s < 0.0 ? -1.0 : 1.0;
  return dir * log(1.0 + abs(s)) * 7.2;
}

float prismaticaSmooth1(float x) {
  float i = floor(x);
  float f = fract(x);
  float u = f * f * (3.0 - 2.0 * f);
  float a = hash21(vec2(i, 0.17));
  float b = hash21(vec2(i + 1.0, 0.17));
  return mix(a, b, u);
}

// Intersect camera ray with one fluid billboard mark. Returns emissive rgb +
// optical density contribution (and writes hit distance via out-style hack:
// density is in .a; caller composites front-to-back).
vec4 prismaticaWispAlongRay(
  vec3 rayOrigin,
  vec3 rayDirection,
  float maxDist,
  int slot,
  float walkGate,
  float walkDepth
) {
  float fi = float(slot);
  float camZ = 1.22 + walkDepth;

  float corridorT = fract(
    walkDepth * 0.072 +
    fi * 0.2 +
    uTime * 0.012 * walkGate
  );
  float easeT = corridorT * corridorT * (3.0 - 2.0 * corridorT);
  float ahead = mix(9.0, 1.5, easeT);
  float band =
    smoothstep(1.25, 2.3, ahead) *
    (1.0 - smoothstep(8.1, 9.2, ahead));
  if (band * walkGate < 0.02) return vec4(0.0);

  // Continuous path — one octave only (was two + 4 snoise warps).
  float hx = prismaticaSmooth1(walkDepth * 0.18 + fi * 5.13);
  float hy = prismaticaSmooth1(walkDepth * 0.14 + fi * 3.91);
  float hs = prismaticaSmooth1(walkDepth * 0.11 + fi * 2.4);
  float scale = mix(0.58, 1.05, hs);
  float t = uTime * walkGate;

  vec3 center = vec3(
    (hx - 0.5) * 3.1 + sin(t * 0.31 + fi * 2.1) * 0.12,
    mix(-0.2, 1.1, hy) + cos(t * 0.27 + fi * 1.6) * 0.08,
    camZ + ahead + sin(t * 0.19 + fi) * 0.1
  );

  // Plane faces the camera (constant-Z billboard in nave space).
  float denom = rayDirection.z;
  if (abs(denom) < 1e-4) return vec4(0.0);
  float hitT = (center.z - rayOrigin.z) / denom;
  if (hitT < 0.05 || hitT > maxDist) return vec4(0.0);

  vec3 hitP = rayOrigin + rayDirection * hitT;
  vec2 delta = hitP.xy - center.xy;

  // Mild hash warp — fluid, not 4× simplex.
  float w = 0.07 * scale * (0.6 + 0.4 * sin(corridorT * 6.28318));
  vec2 warp = vec2(
    hash21(delta * 3.1 + fi + t * 0.2) - 0.5,
    hash21(delta.yx * 2.7 + fi * 1.3 - t * 0.15) - 0.5
  ) * w * 2.0;
  vec2 glyphUv = (delta + warp) / scale * 0.5 + 0.5;
  if (
    glyphUv.x < -0.04 || glyphUv.x > 1.04 ||
    glyphUv.y < -0.04 || glyphUv.y > 1.04
  ) {
    return vec4(0.0);
  }

  // 2×2 atlas: each wisp slot samples a different mark tile.
  // Layout (texture y-down): 0=TL, 1=TR, 2=BL, 3=BR.
  float tileX = float(slot - (slot / 2) * 2); // slot % 2
  float tileY = float(slot / 2);
  vec2 localUv = vec2(
    clamp(glyphUv.x, 0.0, 1.0),
    clamp(glyphUv.y, 0.0, 1.0)
  );
  // y-down within tile, then offset into atlas.
  vec2 tileLocal = vec2(localUv.x, 1.0 - localUv.y);
  vec2 sampleUv = (vec2(tileX, tileY) + tileLocal) * 0.5;
  vec4 glyphSample = texture(uGlyphField, sampleUv);
  float sdf = glyphSample.r * 2.0 - 1.0;
  float coverage = max(glyphSample.g, 0.001);

  float form = smoothstep(0.06, 0.4, corridorT) *
               smoothstep(0.94, 0.66, corridorT);
  float dissolve = smoothstep(0.0, 0.16, corridorT) *
                   smoothstep(1.0, 0.7, corridorT);
  float body = smoothstep(0.15, -0.32, sdf) * coverage;
  float rim = exp(-sdf * sdf * 34.0) * coverage;
  float filament = exp(-sdf * sdf * 400.0) * coverage;
  float shape = mix(
    rim * 1.1 + filament * 0.95,
    body * 0.9 + rim * 0.65 + filament * 0.5,
    form
  );
  float fade = dissolve * dissolve * (3.0 - 2.0 * dissolve);
  float density = shape * fade * band * walkGate *
    max(clamp(uGlyphPhase, 0.0, 1.0), 0.9);
  density = min(density, 1.1);
  if (density < 0.01) return vec4(0.0);

  float hueT = fract(fi * 0.27 + hx * 0.45);
  vec3 accent = mix(
    mix(uAccent0, uAccent1, smoothstep(0.0, 0.5, hueT)),
    mix(uAccent1, uAccent2, smoothstep(0.5, 1.0, hueT)),
    smoothstep(0.25, 0.75, hueT)
  );
  vec3 lit = mix(accent * 0.45, accent * mix(0.5, 1.25, form), body * 0.55 + rim * 0.5);
  lit = mix(lit, accent * 1.3, filament * 0.45);

  // Premultiplied rgb + raw density.
  return vec4(lit * density, density);
}

// Composite the 4 billboard marks along the primary ray (O(slots), not O(vol×slots)).
vec3 prismaticaCompositeWisps(
  vec3 rayOrigin,
  vec3 rayDirection,
  float maxDist,
  vec3 baseColor
) {
  float walkGate = prismaticaWalkGate();
  if (uGlyphActive < 0.5 || walkGate < 0.02) return baseColor;

  float walkDepth = prismaticaWalkDepth();
  vec3 color = baseColor;
  for (int i = 0; i < PRISMATICA_WISP_COUNT; i += 1) {
    vec4 w = prismaticaWispAlongRay(
      rayOrigin,
      rayDirection,
      maxDist,
      i,
      walkGate,
      walkDepth
    );
    // Premultiplied additive glow — readable marks without fog stacking.
    color += w.rgb * 1.15;
  }
  return color;
}

vec3 prismaticaEnvironmentProbe(
  vec3 point,
  vec3 direction,
  vec3 sunDirection
) {
  float upward = prismaticaSaturate(direction.y * 0.5 + 0.5);
  float sideFacing = pow(abs(direction.x), 4.0);
  float forwardFacing = prismaticaSaturate(direction.z * 0.5 + 0.5);

  vec3 ambient = mix(
    uBg,
    uInk,
    0.17 + 0.26 * upward + 0.08 * forwardFacing
  );
  float palettePosition = fract(
    point.z * 0.075 +
    direction.y * 0.31 +
    direction.z * 0.17 +
    direction.x * 0.11
  );
  vec3 stainedReflection = accentRamp(palettePosition);

  float windowGlint = sideFacing * smoothstep(-0.25, 0.48, direction.y);
  float sunGlint = pow(
    max(dot(direction, -sunDirection), 0.0),
    18.0
  );

  return ambient + stainedReflection * (0.34 * windowGlint + 0.78 * sunGlint);
}

vec3 prismaticaTwoBounceDirection(
  vec3 incident,
  vec3 normal,
  float indexOfRefraction
) {
  vec3 inside = refract(incident, normal, 1.0 / indexOfRefraction);
  if (dot(inside, inside) < 0.0001) {
    return reflect(incident, normal);
  }

  vec3 tangent = normalize(
    cross(normal, abs(normal.y) < 0.92 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0))
  );
  float curvature = 0.11 * dot(inside, tangent);
  vec3 exitNormal = normalize(normal - inside * 0.18 + tangent * curvature);
  vec3 outside = refract(inside, exitNormal, indexOfRefraction);

  if (dot(outside, outside) < 0.0001) {
    outside = reflect(inside, exitNormal);
  }

  return normalize(outside);
}

vec3 prismaticaCrystalTransmission(
  vec3 point,
  vec3 incident,
  vec3 normal,
  vec3 sunDirection
) {
  // One mid-IOR path + cheap spectral fan (was 3 full bounce+probe pairs).
  // Visual: same crystal read; saves ~2/3 of column shading ALU.
  vec3 midDir = prismaticaTwoBounceDirection(incident, normal, 1.505);
  vec3 mid = prismaticaEnvironmentProbe(point, midDir, sunDirection);
  float disp = pow(1.0 - max(dot(normal, -incident), 0.0), 2.4);
  vec3 spectrum = accentRamp(fract(
    point.z * 0.09 + point.y * 0.05 + dot(midDir, normal) * 0.35
  ));
  // RGB split without extra probes: fan mid toward spectrum at grazing.
  return mid * vec3(1.04, 1.0, 0.96) + spectrum * disp * 0.28;
}

vec3 prismaticaSpectralCaustic(vec3 point) {
  float bayIndex = floor(
    (point.z + 0.5 * PRISMATICA_BAY_LENGTH) / PRISMATICA_BAY_LENGTH
  );
  float localZ = prismaticaRepeat(
    point.z + point.x * 0.19,
    PRISMATICA_BAY_LENGTH
  );
  float randomOffset = hash21(vec2(bayIndex, 4.73)) - 0.5;
  float fanCoordinate =
    localZ * 0.24 +
    point.x * 0.082 +
    randomOffset * 0.38;
  float phase = fract(fanCoordinate) - 0.5;
  float band = 1.0 - smoothstep(0.055, 0.19, abs(phase));
  float reach = smoothstep(-3.20, -0.55, point.x) *
    (1.0 - smoothstep(2.70, 4.00, point.x));
  float bayGate = 1.0 - smoothstep(0.55, 1.85, abs(localZ));
  vec3 spectrum = accentRamp(fract(fanCoordinate * 0.72 + bayIndex * 0.13));

  return spectrum * band * reach * bayGate;
}

vec3 prismaticaMaterialColor(
  vec3 point,
  vec3 normal,
  vec3 rayDirection,
  float material,
  vec3 sunDirection,
  vec3 pointerPosition,
  float pointerActive
) {
  vec3 viewDirection = -rayDirection;
  float viewFacing = max(dot(normal, viewDirection), 0.0);
  float fresnel = 0.04 + 0.96 * pow(1.0 - viewFacing, 5.0);
  // AO only when the pointer is quiet — scrolling already skips heavy paths.
  float ambientOcclusion = abs(uScrollVel) > 0.55
    ? 0.78
    : prismaticaAmbientOcclusion(point, normal);

  vec3 lightToPointer = pointerPosition - point;
  float pointerDistanceSquared = max(dot(lightToPointer, lightToPointer), 0.001);
  vec3 pointerDirection = lightToPointer * inversesqrt(pointerDistanceSquared);
  float pointerAttenuation = pointerActive /
    (1.0 + 0.20 * pointerDistanceSquared);
  vec3 pointerColor = accentRamp(fract(
    0.58 + point.z * 0.015 + uTime * 0.012
  ));

  float sunDiffuse = max(dot(normal, -sunDirection), 0.0);
  float pointerDiffuse = max(dot(normal, pointerDirection), 0.0) *
    pointerAttenuation;
  // Projected glass only when it will be seen (not deep in shadow materials).
  vec4 projectedLight = prismaticaProjectedWindow(
    point + normal * 0.025,
    sunDirection
  );

  vec3 baseAmbient = mix(
    uBg,
    uInk,
    mix(0.24, 0.13, uTheme)
  );
  vec3 color = baseAmbient;

  if (material < 1.5) {
    vec2 tileCoordinates = point.xz * vec2(0.52, 0.34);
    vec2 tilePhase = fract(tileCoordinates);
    vec2 tileEdgeDistance = min(tilePhase, 1.0 - tilePhase);
    float grout = 1.0 - smoothstep(
      0.015,
      0.046,
      min(tileEdgeDistance.x, tileEdgeDistance.y)
    );
    // Hash grain (was snoise) — same floor grit, far less ALU.
    float stoneVariation = 0.94 + 0.06 * hash21(floor(point.xz * 6.0));
    vec3 floorBase = mix(
      uBg,
      uInk,
      mix(0.18, 0.09, uTheme)
    ) * stoneVariation;
    floorBase = mix(floorBase, uInk * 0.42, grout * 0.30);

    vec3 reflected = prismaticaEnvironmentProbe(
      point,
      reflect(rayDirection, normal),
      sunDirection
    );
    vec3 caustic = prismaticaSpectralCaustic(point) *
      mix(1.18, 0.46, uTheme);

    color = floorBase * ambientOcclusion;
    color += reflected * (0.10 + 0.13 * fresnel);
    color += projectedLight.rgb * projectedLight.a *
      mix(1.26, 0.92, uTheme);
    color += caustic;
    color += pointerColor * pointerDiffuse * 0.72;
  } else if (material < 2.5) {
    float side = prismaticaSafeSign(point.x);
    vec4 glass = prismaticaWindowSample(point, side);
    float facetPattern = 0.5 + 0.5 * sin(
      point.y * 4.7 + point.z * 2.4 + side * 0.8
    );
    vec3 wallBase = mix(
      uBg,
      uInk,
      mix(0.28, 0.12, uTheme)
    );
    wallBase *= 0.90 + 0.10 * facetPattern;

    vec3 glassSurface = glass.rgb * (
      mix(0.88, 1.20, 1.0 - uTheme) +
      0.26 * fresnel
    );
    color = mix(wallBase, glassSurface, glass.a);
    color *= ambientOcclusion;
    color += wallBase * sunDiffuse * 0.18;
    color += pointerColor * pointerDiffuse * (0.44 + 0.80 * glass.a);
  } else if (material < 3.5) {
    float facet = 0.5 + 0.5 * sin(
      point.x * 5.2 + point.z * 1.7 + point.y * 0.85
    );
    vec3 vaultBase = mix(
      uBg,
      uInk,
      mix(0.23, 0.10, uTheme)
    );
    color = vaultBase * (0.90 + 0.10 * facet) * ambientOcclusion;
    color += projectedLight.rgb * projectedLight.a * 0.36;
    color += pointerColor * pointerDiffuse * 0.54;
    color += uInk * pow(fresnel, 1.35) * 0.12;
  } else {
    // Crystal path: skip multi-bounce transmission while scrolling (was a
    // major scroll hitch — 6 environment probes × column pixels).
    float scrollFast = smoothstep(0.18, 0.7, abs(uScrollVel));
    vec3 transmission;
    if (scrollFast > 0.55) {
      transmission = mix(uBg, uInk, 0.2) +
        accentRamp(fract(point.z * 0.08 + point.y * 0.04)) * 0.35;
    } else {
      transmission = prismaticaCrystalTransmission(
        point,
        rayDirection,
        normal,
        sunDirection
      );
    }
    float sunSpecular = pow(
      max(dot(reflect(sunDirection, normal), viewDirection), 0.0),
      material < 4.5 ? 72.0 : 96.0
    );
    float pointerSpecular = pow(
      max(dot(reflect(-pointerDirection, normal), viewDirection), 0.0),
      60.0
    ) * pointerAttenuation;

    float spectrumPosition = fract(
      point.z * 0.086 +
      point.y * 0.041 +
      dot(normal, vec3(0.27, 0.41, 0.19))
    );
    vec3 edgeSpectrum = accentRamp(spectrumPosition);
    float edgeDispersion = pow(1.0 - viewFacing, 2.7) *
      (0.30 + 0.70 * max(sunDiffuse, pointerAttenuation));

    vec3 crystalAmbient = mix(
      uBg,
      uInk,
      material < 4.5 ? 0.17 : 0.24
    );
    color = mix(transmission, crystalAmbient, 0.22 + 0.18 * fresnel);
    color *= mix(0.62, 1.0, ambientOcclusion);
    color += projectedLight.rgb * projectedLight.a * 0.72;
    color += edgeSpectrum * edgeDispersion *
      mix(1.12, 0.48, uTheme);
    color += vec3(1.0) * sunSpecular * mix(1.34, 0.86, uTheme);
    color += pointerColor * pointerSpecular * 1.42;
    color += pointerColor * pointerDiffuse * 0.42;
  }

  return color;
}

// Beams + haze only — glyphs are billboarded outside this loop for speed.
vec4 prismaticaIntegrateVolume(
  vec3 rayOrigin,
  vec3 rayDirection,
  float maximumDistance,
  vec3 sunDirection,
  vec3 pointerPosition,
  float pointerActive,
  vec2 fragCoord
) {
  // Short hits need fewer steps; long nave air keeps full budget.
  float velAbs = abs(uScrollVel);
  float fast = smoothstep(0.12, 0.7, velAbs);
  float rangeScale = clamp(maximumDistance / 18.0, 0.45, 1.0);
  int steps = int(float(PRISMATICA_VOLUME_STEPS) * rangeScale - fast * 1.5);
  steps = clamp(steps, 3, PRISMATICA_VOLUME_STEPS);

  float integrationDistance = min(maximumDistance, 22.0);
  float stepLength = integrationDistance / float(steps);
  float jitter = hash21(fragCoord) - 0.5;

  vec3 accumulated = vec3(0.0);
  float transmittance = 1.0;
  vec3 pointerColor = accentRamp(fract(
    0.61 + uPointer.x * 0.19 + uPointer.y * 0.11
  ));
  bool wantPointer = pointerActive > 0.02;

  for (int sampleIndex = 0; sampleIndex < PRISMATICA_VOLUME_STEPS; sampleIndex += 1) {
    if (sampleIndex >= steps) break;
    float sampleDistance = (
      float(sampleIndex) + 0.5 + jitter * 0.5
    ) * stepLength;
    vec3 point = rayOrigin + rayDirection * sampleDistance;

    vec4 beam = prismaticaBeamField(point, sunDirection);
    float pointerField = 0.0;
    if (wantPointer) {
      vec3 pointerDelta = pointerPosition - point;
      float pointerDistanceSquared = dot(pointerDelta, pointerDelta);
      pointerField = pointerActive / (1.0 + 0.24 * pointerDistanceSquared);
    }

    float baseHaze = mix(0.0030, 0.0019, uTheme);
    float beamDensity = beam.a * mix(0.085, 0.055, uTheme);
    float pointerDensity = pointerField * 0.04;

    float extinction = (
      baseHaze + beamDensity + pointerDensity
    ) * stepLength;

    vec3 scattering = beam.rgb * beamDensity *
      mix(2.2, 1.55, uTheme);
    if (wantPointer) {
      scattering += pointerColor * pointerDensity * 1.2;
    }

    accumulated += transmittance * scattering * stepLength;
    transmittance *= exp(-extinction);
    if (transmittance < 0.05) break;
  }

  return vec4(accumulated, transmittance);
}

vec3 prismaticaDistantApse(vec2 screen, vec3 rayDirection) {
  vec2 apsePoint = vec2(screen.x * 0.76, screen.y - 0.04);
  float archRadius = length(vec2(
    apsePoint.x,
    max(apsePoint.y, -0.10) * 0.78
  ));
  float roseWindow = 1.0 - smoothstep(0.17, 0.24, archRadius);
  float roseLead = 1.0 - smoothstep(
    0.010,
    0.030,
    abs(fract(atan(apsePoint.y, apsePoint.x) * 1.2732395) - 0.5)
  );
  float horizon = pow(max(rayDirection.z, 0.0), 10.0);
  vec3 roseColor = accentRamp(fract(
    atan(apsePoint.y, apsePoint.x) * 0.15915494 + 0.5
  ));
  vec3 base = mix(uBg, uInk, mix(0.13, 0.06, uTheme));

  return base + roseColor * roseWindow * (1.0 - 0.72 * roseLead) *
    horizon * mix(1.28, 0.72, uTheme);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 screen = (2.0 * fragCoord - uResolution) /
    max(uResolution.y, 1.0);

  // Host control block: uScroll = vec2(offsetPx, yMax); uScrollVel = px/frame.
  float scrollOffset = uScroll.x;
  float scrollDirection = prismaticaSafeSign(scrollOffset);
  float scrollTravel = scrollDirection * log(1.0 + abs(scrollOffset)) * 7.2;
  float scrollVelocity = uScrollVel / (1.0 + abs(uScrollVel));

  vec3 rayOrigin = vec3(
    scrollVelocity * 0.12,
    0.12 + 0.035 * sin(uTime * 0.085),
    1.22 + scrollTravel
  );
  vec3 cameraTarget = rayOrigin + vec3(
    -scrollVelocity * 0.09,
    0.42,
    8.0
  );
  vec3 cameraForward = normalize(cameraTarget - rayOrigin);
  vec3 cameraRight = normalize(cross(vec3(0.0, 1.0, 0.0), cameraForward));
  vec3 cameraUp = normalize(cross(cameraForward, cameraRight));
  vec3 rayDirection = normalize(
    cameraForward * 1.58 +
    cameraRight * screen.x +
    cameraUp * screen.y
  );

  vec2 pointerUv = uPointer;
  if (max(pointerUv.x, pointerUv.y) > 1.5) {
    pointerUv /= max(uResolution, vec2(1.0));
  }
  vec2 pointerScreen = pointerUv * 2.0 - 1.0;
  pointerScreen.x *= uResolution.x / max(uResolution.y, 1.0);
  pointerScreen.y = -pointerScreen.y;
  vec3 pointerRay = normalize(
    cameraForward * 1.58 +
    cameraRight * pointerScreen.x +
    cameraUp * pointerScreen.y
  );
  float pointerPlaneDistance = 6.4 / max(pointerRay.z, 0.18);
  vec3 pointerPosition = rayOrigin + pointerRay * pointerPlaneDistance;
  float pointerActive = clamp(uPointerActive, 0.0, 1.0);

  vec3 sunDirection = prismaticaSunDirection();

  vec2 hit = prismaticaTrace(rayOrigin, rayDirection);
  float hitDistance = hit.x;
  float material = hit.y;

  vec3 surfaceColor = prismaticaDistantApse(screen, rayDirection);
  if (material > 0.5) {
    vec3 hitPoint = rayOrigin + rayDirection * hitDistance;
    vec3 normal = prismaticaNormal(hitPoint, hitDistance);
    if (material > 3.5 && material < 4.5) {
      float bayZ = prismaticaRepeat(hitPoint.z, PRISMATICA_BAY_LENGTH);
      float side = hitPoint.x < 0.0 ? -1.0 : 1.0;
      float columnX = side * 3.18;
      vec3 cyl = normalize(vec3(hitPoint.x - columnX, 0.0, bayZ) + vec3(1e-4));
      float graze = pow(1.0 - max(dot(normal, -rayDirection), 0.0), 2.0);
      normal = normalize(mix(normal, cyl, 0.24 + 0.32 * graze));
    }
    surfaceColor = prismaticaMaterialColor(
      hitPoint,
      normal,
      rayDirection,
      material,
      sunDirection,
      pointerPosition,
      pointerActive
    );
  }
  // Edge AA second ray DROPPED — it doubled raymarch cost while scrolling.
  // Rounded column SDF + normal blend covers most of the aliasing.

  vec4 volume = prismaticaIntegrateVolume(
    rayOrigin,
    rayDirection,
    hitDistance,
    sunDirection,
    pointerPosition,
    pointerActive,
    fragCoord
  );

  float distanceFog = exp(
    -hitDistance * mix(0.0125, 0.0085, uTheme)
  );
  vec3 fogColor = mix(
    uBg,
    uInk,
    mix(0.10, 0.045, uTheme)
  );
  vec3 color = mix(fogColor, surfaceColor, distanceFog);
  color = color * volume.a + volume.rgb;

  // Glyphs: analytic billboards along this ray (4 texels, not 4×volume steps).
  color = prismaticaCompositeWisps(
    rayOrigin,
    rayDirection,
    hitDistance,
    color
  );

  float exposure = mix(1.24, 0.96, uTheme);
  color = vec3(1.0) - exp(-max(color, vec3(0.0)) * exposure);
  color = mix(color, sqrt(max(color, vec3(0.0))), 0.12 * uTheme);

  float vignetteRadius = length(screen * vec2(0.54, 0.78));
  float vignetteShape = 1.0 - smoothstep(
    0.28,
    1.20,
    vignetteRadius
  );
  float vignette = mix(
    1.0,
    vignetteShape,
    mix(0.24, 0.13, uTheme)
  );
  color *= vignette;

  // Static dither (no floor(uTime*60) — that was a free dep on every pixel).
  float dither = (hash21(fragCoord) - 0.5) / 255.0;
  color += dither;

  return mix(uBg, color, clamp(uIntensity, 0.0, 1.0));
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}