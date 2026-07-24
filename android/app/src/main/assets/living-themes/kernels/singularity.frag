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

uniform float uAbsorb;

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


// ── PHYSICAL / CINEMATIC SCALE ───────────────────────────────────────────────
// World units are normalized around a Schwarzschild radius of 0.34. The disk's
// inner edge is 3 r_s (the Schwarzschild ISCO), while the photon sphere is
// 1.5 r_s. The integrator uses the correct weak-field 2 r_s / b deflection and
// a near-field relativistic correction to resolve capture and winding paths.
const float SG_PI               = 3.141592653589793;
const float SG_TAU              = 6.283185307179586;
const float SG_RS               = 0.34;
const float SG_HORIZON          = SG_RS * 1.02;
const float SG_PHOTON_SPHERE    = SG_RS * 1.50;
const float SG_DISK_INNER       = SG_RS * 3.00;
const float SG_DISK_OUTER       = 3.15;
const float SG_ESCAPE_RADIUS    = 8.00;
const float SG_INFLUENCE_RADIUS = 3.60;
const int   SG_TRACE_STEPS      = 76;

struct SGTrace {
  vec3 direction;
  vec3 diskEmission;
  float throughput;
  float captured;
  float minRadius;
  float photonDwell;
};

float sg_saturate(float x) {
  return clamp(x, 0.0, 1.0);
}

vec3 sg_safeNormalize(vec3 v) {
  return v * inversesqrt(max(dot(v, v), 1e-10));
}

// Continuous octahedral projection of a direction onto a procedural sky atlas.
vec2 sg_octahedralUv(vec3 n) {
  n /= max(abs(n.x) + abs(n.y) + abs(n.z), 1e-6);
  vec2 p = n.xy;
  if (n.z < 0.0) {
    p = (1.0 - abs(p.yx)) * sign(p + vec2(1e-6));
  }
  return p * 0.5 + 0.5;
}

// One sparse, non-tiled star layer. Keeping stars away from cell borders avoids
// a 3x3 neighbor search while preserving clean halos at practical resolutions.
vec3 sg_starLayer(vec3 direction, float scale, float seed, float cutoff) {
  vec2 atlas = sg_octahedralUv(direction) * scale;
  vec2 cell = floor(atlas);
  vec2 local = fract(atlas) - 0.5;
  vec2 salt = vec2(seed, seed * 1.731);

  float identity = hash21(cell + salt);
  float presence = smoothstep(cutoff, 1.0, identity);
  vec2 offset = vec2(
    hash21(cell + salt + vec2(17.13, 3.71)),
    hash21(cell + salt + vec2(41.77, 29.31))
  );
  offset = (offset - 0.5) * 0.68;

  vec2 delta = local - offset;
  float d2 = dot(delta, delta);
  float spectral = hash21(cell + salt + vec2(73.9, 11.2));
  float phase = hash21(cell + salt + vec2(5.4, 97.1));
  float size = mix(0.018, 0.082, pow(identity, 18.0));
  float core = exp(-d2 / max(size * size, 1e-5));
  float halo = exp(-d2 / max(size * size * 13.0, 1e-5)) * 0.13;
  float twinkle = 0.72 + 0.28 * sin(
    uTime * (0.38 + spectral * 1.7) + phase * SG_TAU
  );

  vec3 cool = accentRamp(0.04 + spectral * 0.22);
  vec3 warm = accentRamp(0.72 + spectral * 0.24);
  vec3 color = mix(cool, warm, smoothstep(0.34, 0.82, spectral));
  vec3 stellarWhite = mix(accentRamp(0.02), vec3(1.0), 0.78);
  color = mix(color, stellarWhite, pow(identity, 28.0));

  return color * (core * 1.35 + halo) * presence * twinkle;
}

// Procedural celestial sphere. The aligned source is sampled in *escaped ray
// direction*, not in screen space; its ring and higher-order images therefore
// emerge from the lens mapping itself.
vec3 sg_background(vec3 direction, vec3 alignedSource) {
  direction = sg_safeNormalize(direction);

  vec3 galacticNormal = sg_safeNormalize(vec3(0.19, 0.86, 0.47));
  float latitude = abs(dot(direction, galacticNormal));
  float galacticBand = exp(-latitude * 8.5);
  float hazeNoise = 0.5 + 0.5 * fbm(
    direction * 2.65 + vec3(uTime * 0.006, -uTime * 0.004, uTime * 0.003)
  );
  float haze = galacticBand * smoothstep(0.24, 0.82, hazeNoise);

  vec3 stars = vec3(0.0);
  stars += sg_starLayer(direction,  58.0,  3.7, 0.955) * 0.90;
  stars += sg_starLayer(direction, 126.0, 19.4, 0.970) * 0.72;
  stars += sg_starLayer(direction, 268.0, 47.8, 0.982) * 0.52;

  // A bright point-source directly behind the hole lenses into a razor-thin
  // Einstein ring — a hard, artificial-looking circle "bubble" around the whole
  // lens. Drop the sharp core and keep only a faint, soft halo so the far side
  // reads as light without the geometric ring.
  float sourceSeparation = max(1.0 - dot(direction, alignedSource), 0.0);
  float sourceHalo = exp(-sourceSeparation * 9000.0);
  float source = sourceHalo * 0.12;
  vec3 sourceColor = mix(accentRamp(0.02), vec3(1.0), 0.72);

  if (uTheme < 0.5) {
    vec3 color = uBg;
    color += accentRamp(0.42 + hazeNoise * 0.22) * haze * 0.19 * uIntensity;
    color += stars * (0.70 + 0.48 * uIntensity);
    color += sourceColor * source * (0.82 + 0.50 * uIntensity);
    return color;
  }

  // Light theme: pale dawn atmosphere; stars print as ink while the aligned
  // source remains a restrained amber-gold lens feature.
  float dawn = pow(sg_saturate(0.58 - direction.y * 0.42), 1.7);
  vec3 color = mix(uBg, accentRamp(0.94), dawn * 0.10 * uIntensity);
  color = mix(color, accentRamp(0.56 + hazeNoise * 0.18), haze * 0.12 * uIntensity);
  float starMask = sg_saturate(dot(stars, vec3(0.3333)) * 1.55);
  color = mix(color, uInk, starMask * 0.72 * uIntensity);
  color = mix(color, accentRamp(0.92), sg_saturate(source) * 0.82 * uIntensity);
  return color;
}

// Relativistic thin-disk emission at one curved-ray / disk-plane intersection.
// rgb = emitted radiance; a = optical coverage for front-to-back compositing.
vec4 sg_diskSample(vec3 position, vec3 rayDirection) {
  float radius = length(position.xz);
  float radial = sg_saturate(
    (radius - SG_DISK_INNER) / (SG_DISK_OUTER - SG_DISK_INNER)
  );

  float innerGate = smoothstep(SG_DISK_INNER, SG_DISK_INNER + 0.045, radius);
  float outerGate = 1.0 - smoothstep(SG_DISK_OUTER - 0.58, SG_DISK_OUTER, radius);
  float diskMask = innerGate * outerGate;

  float azimuth = atan(position.z, position.x);
  float orbitalRate = 0.62 / pow(max(radius, SG_DISK_INNER), 1.5);
  float advectedAngle = azimuth - uTime * orbitalRate;

  // Two noise calls only when a ray actually touches the disk. The domains are
  // co-rotating, so detail flows with the plasma instead of boiling in place.
  vec2 orbitalOffset = vec2(cos(advectedAngle), sin(advectedAngle));
  float broadNoise = 0.5 + 0.5 * snoise(vec3(
    position.xz * 2.15 + orbitalOffset * 0.35,
    uTime * 0.10 + radius * 0.83
  ));
  float fineNoise = 0.5 + 0.5 * snoise(vec3(
    position.xz * 6.20 - orbitalOffset * uTime * 0.055,
    radius * 1.91 - uTime * 0.16
  ));
  float spiral = 0.5 + 0.5 * sin(
    advectedAngle * 9.0 - log(max(radius, 0.1)) * 16.0 + broadNoise * 2.4
  );
  float hotSpot = pow(max(0.0, sin(advectedAngle * 3.0 + fineNoise * 4.2)), 10.0);
  float density = clamp(
    0.30 + broadNoise * 0.34 + fineNoise * 0.21 + spiral * 0.22 + hotSpot * 0.62,
    0.0,
    1.45
  );

  // Temperature rises toward the ISCO; a narrow compressed rim makes the inner
  // edge incandescent without turning the entire disk into a flat neon band.
  float temperature = pow(1.0 - radial, 0.56);
  float rimOffset = (radius - (SG_DISK_INNER + 0.10)) / 0.145;
  float innerRim = exp(-rimOffset * rimOffset);

  // Circular orbital motion. The local photon direction is reversed because
  // rays are traced camera -> scene while emitted light travels scene -> camera.
  vec3 velocityDirection = sg_safeNormalize(vec3(-position.z, 0.0, position.x));
  float beta = clamp(sqrt((0.5 * SG_RS) / max(radius, SG_DISK_INNER)) * 1.38, 0.0, 0.72);
  float towardObserver = dot(velocityDirection, -rayDirection);
  float doppler = sqrt(max(1.0 - beta * beta, 0.02))
                / max(1.0 - beta * towardObserver, 0.22);
  float gravitationalShift = sqrt(max(1.0 - SG_RS / radius, 0.05));
  float frequencyShift = doppler * gravitationalShift;
  float shiftStops = clamp(log2(max(frequencyShift, 0.20)), -1.0, 1.0);

  // Dark: blue-white inner disk -> crimson rim. Light: amber -> hot gold.
  // Doppler modulation remains inside the active theme's accent ramp.
  float darkRamp = mix(0.72, 0.035, temperature) - shiftStops * 0.17;
  float lightRamp = mix(0.70, 0.98, temperature) + shiftStops * 0.11;
  float rampPosition = clamp(mix(darkRamp, lightRamp, uTheme), 0.0, 1.0);
  vec3 color = accentRamp(rampPosition);

  float hotCore = sg_saturate(temperature * 0.72 + innerRim * 0.65 + hotSpot * 0.28);
  if (uTheme < 0.5) {
    vec3 blueWhite = mix(accentRamp(0.015), vec3(1.0), 0.76);
    color = mix(color, blueWhite, hotCore * (0.42 + 0.20 * max(shiftStops, 0.0)));
  } else {
    vec3 warmWhite = mix(accentRamp(0.97), vec3(1.0), 0.48);
    color = mix(color, warmWhite, hotCore * 0.34);
  }

  float beaming = clamp(pow(doppler, 3.0), 0.24, 4.6);
  float heat = 0.20 + temperature * 1.40 + innerRim * 2.65 + hotSpot * 1.35;
  float radiance = heat * density * beaming * gravitationalShift * gravitationalShift;
  radiance *= mix(1.05, 0.78, uTheme) * (0.52 + 0.78 * uIntensity);

  // Thin-disk optical depth increases at grazing angles, making edge-on views
  // substantial while preserving translucent turbulent gaps and secondary arcs.
  float grazing = max(abs(rayDirection.y), 0.105);
  float opticalDepth = diskMask * density * (0.38 + 1.12 * (1.0 - radial));
  float alpha = 1.0 - exp(-opticalDepth / grazing);
  alpha = min(alpha, 0.955) * diskMask;

  return vec4(color * radiance, alpha);
}

// Weak-field asymptote used outside the expensive integration region. The
// deflection tends to 2 r_s / b, matching the detailed path at the handoff.
vec3 sg_weakFieldDirection(vec3 rayOrigin, vec3 rayDirection) {
  float closestT = max(-dot(rayOrigin, rayDirection), 0.0);
  vec3 impactVector = rayOrigin + rayDirection * closestT;
  float impact = max(length(impactVector), 1e-4);
  float deflection = (2.0 * SG_RS / impact) * (1.0 + 0.5 * SG_RS / impact);
  return sg_safeNormalize(rayDirection - impactVector / impact * deflection);
}

SGTrace sg_traceGeodesic(vec3 rayOrigin, vec3 rayDirection) {
  SGTrace result;
  result.direction = rayDirection;
  result.diskEmission = vec3(0.0);
  result.throughput = 1.0;
  result.captured = 0.0;
  result.minRadius = 1e5;
  result.photonDwell = 0.0;

  vec3 position = rayOrigin;
  vec3 direction = rayDirection;
  int diskHits = 0;

  for (int stepIndex = 0; stepIndex < SG_TRACE_STEPS; stepIndex++) {
    float radius = length(position);
    result.minRadius = min(result.minRadius, radius);

    if (radius < SG_HORIZON) {
      result.captured = 1.0;
      break;
    }
    if (stepIndex > 8 && radius > SG_ESCAPE_RADIUS && dot(position, direction) > 0.0) {
      break;
    }

    // Adaptive arc-length: high precision through the photon region, much larger
    // strides in weakly curved empty space. The horizon limiter prevents a coarse
    // step from tunneling through the capture boundary.
    float stepLength = mix(
      0.035,
      0.38,
      smoothstep(SG_RS * 1.15, 3.20, radius)
    );
    stepLength = min(stepLength, max(0.018, (radius - SG_RS) * 0.45));

    // Optical-geodesic acceleration: remove the component parallel to the ray,
    // then bend toward the mass. The leading term gives GR's weak-field result;
    // the correction resolves near-field winding and the enlarged shadow.
    vec3 perpendicularRadius = position - direction * dot(position, direction);
    float inverseR3 = 1.0 / max(radius * radius * radius, 1e-5);
    float relativisticBoost = 1.0 + 1.35 * SG_RS / max(radius, SG_RS);
    direction = sg_safeNormalize(
      direction - perpendicularRadius * (SG_RS * relativisticBoost * inverseR3) * stepLength
    );

    vec3 previousPosition = position;
    vec3 nextPosition = position + direction * stepLength;

    // Count affine distance spent near the unstable photon orbit. This is later
    // used only to strengthen already-present disk light, approximating unresolved
    // higher-order subrings without making the vacuum photon sphere self-luminous.
    float photonBand = exp(-abs(radius - SG_PHOTON_SPHERE) * 13.0);
    result.photonDwell += photonBand * stepLength;

    // A curved ray may cross the disk multiple times. Front-to-back compositing
    // makes the near surface occlude later images while translucent gaps reveal
    // the far side folding above and below the shadow.
    float planeProduct = previousPosition.y * nextPosition.y;
    float planeDelta = previousPosition.y - nextPosition.y;
    if (planeProduct <= 0.0 && abs(planeDelta) > 1e-6 && diskHits < 4) {
      float segmentT = clamp(previousPosition.y / planeDelta, 0.0, 1.0);
      vec3 diskPosition = mix(previousPosition, nextPosition, segmentT);
      float diskRadius = length(diskPosition.xz);
      if (diskRadius >= SG_DISK_INNER && diskRadius <= SG_DISK_OUTER) {
        vec4 sampleValue = sg_diskSample(diskPosition, direction);
        result.diskEmission += result.throughput * sampleValue.rgb * sampleValue.a;
        result.throughput *= 1.0 - sampleValue.a;
        diskHits += 1;
        if (result.throughput < 0.018) {
          position = nextPosition;
          break;
        }
      }
    }

    position = nextPosition;
  }

  float finalRadius = length(position);
  result.minRadius = min(result.minRadius, finalRadius);
  if (finalRadius < SG_HORIZON) {
    result.captured = 1.0;
  }
  result.direction = direction;
  return result;
}

// ── GLYPH ABSORPTION ─────────────────────────────────────────────────────────
// The active foreground mark (its SDF published to uGlyphField) is cast into the
// accretion flow rather than dropped into the hole: its matter is wrapped onto a
// ring around the shadow and spun with rapid DIFFERENTIAL rotation (inner orbits
// lap the outer, so the mark shears into spiral arcs), the ring winds inward and
// dips through the photon ring as the page scrolls, and the whole thing feathers
// away wistfully before the horizon. Fully gated by uGlyphActive * uAbsorb, so a
// mark-less or toggled-off frame costs one branch and is byte-identical.

vec4 sg_glyphInfall(vec2 screen, float scroll) {
  float gate = uGlyphActive * clamp(uAbsorb, 0.0, 1.0);
  if (gate < 0.004) return vec4(0.0);

  // Scroll accelerates the infall and, at the very end, thins the whole swarm to
  // nothing. Kept raw (un-eased) so the sparks keep streaming until they're gone.
  float a = clamp(scroll, 0.0, 1.0);
  float presence = max(clamp(uGlyphPhase, 0.0, 1.0), 0.5);
  float systemFade = 1.0 - smoothstep(0.74, 1.0, a);

  // The mark comes apart into a swarm of embers, each on its own decaying spiral
  // orbit: born out at the disk edge, whipping several rapid laps around the rim,
  // easing inward to the photon ring, then winking out — wistfully — before the
  // horizon. A spark only ignites where the glyph has ink at its birth angle, so it
  // is the WORD that dissolves into orbiting light, not a generic ring.
  vec3 acc = vec3(0.0);
  float aAcc = 0.0;
  const int SPARKS = 26;
  for (int k = 0; k < SPARKS; k++) {
    float fk = float(k);
    float seed = hash21(vec2(fk, 3.7));
    float seed2 = hash21(vec2(fk, 9.1));

    // Continuous life 0..1, each spark at its own phase so the stream is steady.
    float speed = 0.09 + 0.13 * seed;
    float life = fract(uTime * speed + seed + a * 0.6);

    // Spiral in: radius eases disk-edge -> photon ring; angle winds rapid turns.
    float rad = mix(0.40 - 0.05 * seed2, 0.145, life * life);
    float turns = 2.5 + 2.5 * seed;
    float ang = seed * SG_TAU + life * turns * SG_TAU + uTime * 0.4;
    vec2 pos = rad * vec2(cos(ang), sin(ang));

    // Ignite from the mark's ink at this spark's slowly-drifting birth angle.
    float birthU = fract(seed + uTime * 0.02);
    float ink = textureLod(uGlyphField, vec2(birthU, 0.5 + (seed2 - 0.5) * 0.5), 0.0).g;
    float ignite = 0.35 + 0.9 * ink;

    // Born bright, fades wistfully at the end of its fall.
    float born = smoothstep(0.0, 0.10, life);
    float die = 1.0 - smoothstep(0.66, 1.0, life);
    float bright = born * die * ignite * (0.45 + 0.55 * seed2) * presence * gate * systemFade;
    if (bright < 0.008) continue;

    // Glowing head with a tangential motion-blur trail (longer as it accelerates in).
    vec2 d = screen - pos;
    vec2 tang = vec2(-sin(ang), cos(ang));
    vec2 radl = vec2(cos(ang), sin(ang));
    float alongT = dot(d, tang);
    float perp = dot(d, radl);
    float head = 0.007 + 0.005 * seed;
    float trail = 0.03 + 0.11 * life;
    float g = exp(-(perp * perp) / (head * head) - (alongT * alongT) / (trail * trail));

    // White-hot head cooling to an accent ember as it winds in.
    vec3 c = mix(vec3(1.35), accentRamp(mix(0.08, 0.34, life)), 0.55);
    acc += c * g * bright;
    aAcc += g * bright;
  }
  if (aAcc < 0.002) return vec4(0.0);
  return vec4(acc * 1.55, min(aAcc, 1.0));
}

vec3 sg_composeGlyph(vec3 base, vec4 infall) {
  // Premultiplied additive glow — accreting matter over the lensed scene.
  return base + infall.rgb * (0.9 + 0.6 * uIntensity);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 screen = (fragCoord - 0.5 * uResolution) / max(uResolution.y, 1.0);

  // Scroll maps the full page to a deliberate edge-on -> top-down camera arc.
  // When the page cannot scroll (including reduced-motion static rendering), use
  // the compositionally balanced 47-degree hero view.
  float scrollProgress = uScroll.y > 1.0
    ? clamp(uScroll.x / uScroll.y, 0.0, 1.0)
    : 0.58;
  float pointerYaw = (uPointer.x - 0.5) * 1.62 * uPointerActive;
  float pointerPitch = (uPointer.y - 0.5) * 0.52 * uPointerActive;
  float inertialTilt = clamp(uScrollVel * 0.00082, -0.075, 0.075);

  float inclination = mix(0.085, 1.31, scrollProgress)
                    + pointerPitch
                    + 0.022 * sin(uTime * 0.071);
  inclination = clamp(inclination, 0.065, 1.39);
  float yaw = 0.28 + pointerYaw + 0.065 * sin(uTime * 0.029);

  // A restrained scroll-velocity roll makes interaction feel inertial without
  // compromising the physically meaningful inclination control.
  float rollCos = cos(inertialTilt);
  float rollSin = sin(inertialTilt);
  screen = mat2(rollCos, -rollSin, rollSin, rollCos) * screen;

  // The active mark, drawn as matter the hole devours as the page scrolls.
  // Cheap no-op when there is no mark or the effect is toggled off (uAbsorb=0).
  vec4 sgInfall = sg_glyphInfall(screen, scrollProgress);

  const float CAMERA_RADIUS = 5.80;
  vec3 rayOrigin = CAMERA_RADIUS * vec3(
    cos(inclination) * sin(yaw),
    sin(inclination),
    cos(inclination) * cos(yaw)
  );
  vec3 forward = sg_safeNormalize(-rayOrigin);
  vec3 right = sg_safeNormalize(cross(forward, vec3(0.0, 1.0, 0.0)));
  vec3 up = sg_safeNormalize(cross(right, forward));
  vec3 rayDirection = sg_safeNormalize(
    forward + right * screen.x * 1.12 + up * screen.y * 1.12
  );

  // Coherent fast path for rays whose straight-line impact parameter is safely
  // beyond both the disk and the strong-lensing region.
  float closestT = max(-dot(rayOrigin, rayDirection), 0.0);
  float straightImpact = length(rayOrigin + rayDirection * closestT);
  if (straightImpact > SG_INFLUENCE_RADIUS) {
    vec3 weakDirection = sg_weakFieldDirection(rayOrigin, rayDirection);
    vec3 farColor = sg_background(weakDirection, forward);
    // Match the slow path's vignette + blend EXACTLY so the handoff leaves no seam.
    float vignette = 1.0 - smoothstep(0.60, 1.18, length(screen * vec2(0.86, 1.0)));
    return sg_composeGlyph(mix(uBg, farColor, 0.82 + 0.18 * vignette), sgInfall);
  }

  SGTrace trace = sg_traceGeodesic(rayOrigin, rayDirection);

  // Longer near-photon paths resolve into brighter disk substructure only when
  // disk emission exists; vacuum remains dark, preserving physical causality.
  float diskLuminance = dot(trace.diskEmission, vec3(0.2126, 0.7152, 0.0722));
  float subringBoost = 1.0 + min(trace.photonDwell * 0.16, 0.62)
                    * smoothstep(0.001, 0.08, diskLuminance);
  vec3 diskEmission = trace.diskEmission * subringBoost;

  vec3 horizonColor = uTheme < 0.5
    ? uBg * 0.015
    : mix(uInk, vec3(0.0), 0.18);
  vec3 background = trace.captured > 0.5
    ? horizonColor
    : sg_background(trace.direction, forward);

  vec3 color;
  if (uTheme < 0.5) {
    vec3 hdr = background * trace.throughput + diskEmission;
    color = vec3(1.0) - exp(-hdr * 1.12);
  } else {
    vec3 base = background * trace.throughput;
    vec3 glow = vec3(1.0) - exp(-diskEmission * 0.74);
    color = base + glow * (vec3(1.0) - base);
  }

  // Quiet edge falloff keeps interface copy legible without shrinking the lens.
  float vignette = 1.0 - smoothstep(0.60, 1.18, length(screen * vec2(0.86, 1.0)));
  color = mix(uBg, color, 0.82 + 0.18 * vignette);
  color = sg_composeGlyph(color, sgInfall);
  return color;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}