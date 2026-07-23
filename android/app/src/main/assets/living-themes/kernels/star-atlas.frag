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


// ── HELPERS ──────────────────────────────────────────────────────────────────

// Point-to-segment distance.
float distToSeg(vec2 a, vec2 b, vec2 frag){
  vec2 ab = b - a;
  float t = clamp(dot(frag - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
  vec2 closest = a + t * ab;
  return length(frag - closest);
}

// Catmull-Rom interpolation through 4 control points — gives smooth, flowing
// calligraphic curves through the zodiac point sets.
vec2 catmullRom(vec2 p0, vec2 p1, vec2 p2, vec2 p3, float t){
  float t2 = t * t;
  float t3 = t2 * t;
  return 0.5 * (
    (2.0 * p1) +
    (-p0 + p2) * t +
    (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
    (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
  );
}

// ── ZODIAC PATTERNS ──────────────────────────────────────────────────────────
// Each sign is a parametric curve: a function of parameter t (0..1) that
// returns a position in centered, aspect-corrected space (radius ~0.45).
// 18-24 sample points per sign are evaluated at fixed t intervals.
// The patterns are hand-tuned to evoke each sign's calligraphic gesture.

// Returns the number of control points for a sign (0..11).
int zodiacControlCount(int sign){
  if (sign == 0) return 6;  // Aries — ram's horns, spiral
  if (sign == 1) return 8;  // Taurus — bull's head, circle + horns
  if (sign == 2) return 7;  // Gemini — twins, two pillars + bar
  if (sign == 3) return 7;  // Cancer — crab, loops
  if (sign == 4) return 7;  // Leo — lion, sickle
  if (sign == 5) return 8;  // Virgo — maiden, M + tail
  if (sign == 6) return 7;  // Libra — scales
  if (sign == 7) return 8;  // Scorpio — scorpion, M + arrow
  if (sign == 8) return 6;  // Sagittarius — arrow
  if (sign == 9) return 6;  // Capricorn — V-loop
  if (sign == 10) return 7; // Aquarius — waves
  return 7;                 // Pisces — two crescents + line
}

// Returns control point idx (0..count-1) for sign, in centered space.
// The patterns use parametric forms (circles, lines, arcs) composed per sign.
vec2 zodiacControl(int sign, int idx, int count){
  float fi = float(idx);
  float fc = float(count - 1);
  float t = fi / max(fc, 1.0);
  float a = t * 6.28318530718;

  if (sign == 0) {
    // Aries — ram's horns: an inward spiral from outer left, curling right.
    float r = 0.38 * (1.0 - t * 0.7);
    float ang = a * 1.3 + 2.0;
    return vec2(cos(ang) * r - 0.05, sin(ang) * r * 0.7 + 0.05);
  }
  if (sign == 1) {
    // Taurus — bull's head: a circle (face) then two horns branching up.
    if (idx < 5) {
      float ca = t * 6.2832 * 0.95;
      return vec2(cos(ca) * 0.22, sin(ca) * 0.22 - 0.02);
    }
    // Horns: two arcs branching from the top of the circle
    float ht = (fi - 4.0) / 3.0;
    float side = idx < 6 ? -1.0 : 1.0;
    return vec2(side * (0.12 + ht * 0.2), 0.15 + ht * 0.25);
  }
  if (sign == 2) {
    // Gemini — twins: two vertical pillars connected by a crossbar.
    float side = idx < 4 ? -0.18 : 0.18;
    float vy = idx < 4 ? (fi / 3.0) * 0.5 - 0.25 : ((fi - 4.0) / 2.0) * 0.5 - 0.25;
    // The middle point of each pillar connects to the crossbar
    return vec2(side, vy);
  }
  if (sign == 3) {
    // Cancer — crab: two sideways loops (69 shape).
    if (idx < 4) {
      float ca = t * 3.1416;
      return vec2(-0.25 + cos(ca) * 0.12, sin(ca) * 0.18);
    }
    float ca = (fi - 3.0) / 3.0 * 3.1416;
    return vec2(0.25 - cos(ca) * 0.12, sin(ca) * 0.18);
  }
  if (sign == 4) {
    // Leo — lion: a sickle (hook) then a body curve.
    if (idx < 4) {
      float ca = t * 4.0;
      return vec2(0.1 + cos(ca) * 0.2 * (1.0 - t * 0.3), -0.1 + sin(ca) * 0.25);
    }
    float bt = (fi - 3.0) / 3.0;
    return vec2(0.1 - bt * 0.3, 0.05 - bt * 0.2);
  }
  if (sign == 5) {
    // Virgo — maiden: an M shape then a crossing tail.
    float mx = (fi / 7.0) * 0.5 - 0.25;
    float my = 0.2 * sin(mx * 6.2832 * 1.5) - 0.05;
    if (idx == 7) return vec2(0.15, -0.3); // tail
    return vec2(mx, my);
  }
  if (sign == 6) {
    // Libra — scales: a dome, a horizontal beam, two hanging pans.
    if (idx < 3) {
      float ca = t * 3.1416;
      return vec2(cos(ca) * 0.25, 0.05 + sin(ca) * 0.15);
    }
    if (idx == 3) return vec2(-0.25, 0.05);  // beam left
    if (idx == 4) return vec2(0.25, 0.05);   // beam right
    if (idx == 5) return vec2(-0.2, -0.15);  // left pan
    return vec2(0.2, -0.15);                  // right pan
  }
  if (sign == 7) {
    // Scorpio — scorpion: an M shape then an arrow-tail.
    float mx = (fi / 7.0) * 0.5 - 0.25;
    float my = 0.2 * sin(mx * 6.2832 * 1.5) - 0.05;
    if (idx == 7) return vec2(0.3, -0.05); // arrow tip
    return vec2(mx, my);
  }
  if (sign == 8) {
    // Sagittarius — archer: an arrow diagonal with a crossing line.
    if (idx < 4) return vec2(-0.2 + t * 0.4, -0.15 + t * 0.3);
    // Cross line
    float ct = (fi - 3.0) / 2.0;
    return vec2(0.0 + ct * 0.15, 0.05 - ct * 0.15);
  }
  if (sign == 9) {
    // Capricorn — goat: a V then a loop back.
    if (idx < 3) return vec2(-0.2 + t * 0.4, 0.15 - t * 0.35);
    float lt = (fi - 2.0) / 3.0;
    return vec2(0.2 - lt * 0.15, -0.2 + lt * 0.25);
  }
  if (sign == 10) {
    // Aquarius — water bearer: zigzag waves then a downward flow.
    if (idx < 5) {
      float wx = (fi / 4.0) * 0.5 - 0.25;
      float wy = 0.08 * sin(fi * 2.0);
      return vec2(wx, wy);
    }
    float ft = (fi - 4.0) / 2.0;
    return vec2(0.15 - ft * 0.1, -0.05 - ft * 0.25);
  }
  // Pisces — two crescents connected by a horizontal line.
  if (idx < 3) {
    float ca = t * 3.1416 * 0.8;
    return vec2(-0.2 + cos(ca) * 0.1, -0.1 + sin(ca) * 0.12);
  }
  if (idx == 3) return vec2(-0.05, -0.1);
  if (idx == 4) return vec2(0.05, -0.1);
  float ca = (fi - 4.0) / 2.0 * 3.1416 * 0.8;
  return vec2(0.2 - cos(ca) * 0.1, -0.1 + sin(ca) * 0.12);
}

// Sample a point on the zodiac curve for a given sign at parameter t (0..1).
// Uses Catmull-Rom through the control points for smooth, flowing curves.
vec2 zodiacPoint(int sign, float t){
  int n = zodiacControlCount(sign);
  float ft = t * float(n - 1);
  int i = int(ft);
  float f = fract(ft);
  vec2 p0 = zodiacControl(sign, max(i - 1, 0), n);
  vec2 p1 = zodiacControl(sign, i, n);
  vec2 p2 = zodiacControl(sign, min(i + 1, n - 1), n);
  vec2 p3 = zodiacControl(sign, min(i + 2, n - 1), n);
  return catmullRom(p0, p1, p2, p3, f);
}

// ── RENDER KERNEL ────────────────────────────────────────────────────────────

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float aspect = uResolution.x / max(uResolution.y, 1.0);

  // ── CLOCKS ──
  float tDrift   = uTime * 0.006;    // galactic drift (slow)
  float tBreathe = uTime * 0.04;     // nebular breathing
  float tTwinkle = uTime * 0.9;      // stellar twinkle

  // ── GALACTIC PLANE ──
  const float PLANE_ANGLE = 0.35;
  float ca = cos(PLANE_ANGLE), sa = sin(PLANE_ANGLE);
  vec2 rp = vec2(p.x * ca - p.y * sa, p.x * sa + p.y * ca);
  float planeDensity = exp(-rp.y * rp.y * 1.4);
  float planeMask = smoothstep(0.0, 1.0, planeDensity);

  // ── NEBULAR MIST (3 fbm = 12 snoise, dual-layer parallax) ──
  vec2 nebFlow = vec2(tDrift * 2.5, tBreathe * 0.12);
  float neb1 = fbm(vec3(rp * 1.3 + nebFlow, tBreathe * 0.22));
  float neb2 = fbm(vec3(rp * 2.8 - nebFlow * 0.6, tBreathe * 0.16 + 5.2));
  float neb3 = fbm(vec3(rp * 5.2 + nebFlow * 0.3, tBreathe * 0.1 + 11.7));
  float neb = neb1 * (0.6 + 0.4 * neb2) * (0.7 + 0.3 * neb3);
  neb *= planeMask * 0.7 + 0.3;
  float nebHue = clamp(0.25 + rp.x * 0.15 + neb * 0.4, 0.0, 1.0);
  vec3 nebColor = accentRamp(nebHue);
  // Deep core glow — the densest part of the nebula glows hotter
  float nebCore = pow(clamp(neb * 1.3, 0.0, 1.0), 3.0);
  vec3 nebCoreColor = mix(nebColor, clamp(vec3(1.0) - uBg, 0.0, 1.0), 0.5);

  // ── STARFIELD (3 parallax depth layers, hashed grid, spectral, spikes) ──
  // 3×3 neighbor sampling: each fragment checks its own cell + 8 neighbors so
  // halos and diffraction spikes bleed across cell boundaries naturally — no
  // square-tile clipping artifacts.
  vec3 starAcc = vec3(0.0);
  for (int layer = 0; layer < 3; layer++) {
    float fl = float(layer);
    float depth = 1.0 - 0.28 * fl;
    float scale = 5.5 + fl * 4.5;
    vec2 sp = p * scale;
    sp.x += tDrift * (2.0 + 0.6 * fl);
    vec2 baseCell = floor(sp);
    vec2 cellF = fract(sp);

    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        vec2 cell = baseCell + vec2(float(dx), float(dy));
        vec2 offset = vec2(float(dx), float(dy)) - cellF;
        float h1 = hash21(cell + vec2(0.0, fl * 17.3));
        float h2 = hash21(cell + vec2(31.0, fl * 17.3));
        float h3 = hash21(cell + vec2(67.0, fl * 17.3 + 11.0));
        float h4 = hash21(cell + vec2(101.0, fl * 17.3 + 23.0));
        float hasStar = step(0.72, h1);
        vec2 starPos = vec2(h2, h3);
        // Distance from the fragment to this cell's star (in cell space, so
        // neighbor stars are at |offset + starPos| — crossing cell boundaries)
        float d = length(offset + starPos);
        float core = exp(-d * d * 200.0);
        float halo = exp(-d * d * 60.0);
        float twinkle = 0.5 + 0.5 * sin(tTwinkle * (0.3 + h4 * 2.0) + h1 * 6.2831);
        float brightness = (0.2 + 0.8 * h4) * hasStar * twinkle;
        brightness *= (0.3 + 0.7 * planeDensity);
        vec3 starColor;
        if (h3 > 0.82) {
          // Hottest stars — white-blue, with diffraction spikes
          starColor = mix(accentRamp(0.05), clamp(vec3(1.0) - uBg, 0.0, 1.0), 0.8);
          float spikeAngle = h1 * 6.2831;
          vec2 sdir = vec2(cos(spikeAngle), sin(spikeAngle));
          vec2 sorth = vec2(-sin(spikeAngle), cos(spikeAngle));
          vec2 svec = offset + starPos;
          float spike = exp(-abs(dot(svec, sdir)) * 120.0) * exp(-abs(dot(svec, sorth)) * 800.0)
                      + exp(-abs(dot(svec, sorth)) * 120.0) * exp(-abs(dot(svec, sdir)) * 800.0);
          starAcc += starColor * spike * brightness * 0.4 * depth;
        } else if (h3 > 0.6) {
          starColor = accentRamp(clamp(h3 * 0.7 + 0.05, 0.0, 1.0));
        } else {
          // Cooler, amber-tinted stars
          starColor = mix(accentRamp(0.85), accentRamp(0.6), h3);
        }
        starAcc += starColor * (core * 1.4 + halo * 0.14) * brightness * depth;
      }
    }
  }

  // ── ZODIAC FORMATION (the signature) ──
  // 12 signs cycle on a ~10s period each. Each sign: 35% drawing, 25% hold,
  // 40% dissolving. Stars migrate toward the pattern, filaments draw
  // stroke-by-stroke with a traveling ink nib, then dissolve like ink in water.
  float signPeriod = 10.0;
  // Coprime permutation: (cycle * 7) % 12 visits every sign once before
  // repeating, in a non-sequential order that feels random but guarantees
  // full coverage. 7 is coprime to 12, so the cycle length is exactly 12.
  int cycleIdx = int(floor(uTime / signPeriod));
  int signIdx = int(mod(float(cycleIdx * 7 + 5), 12.0));
  float signPhase = mod(uTime, signPeriod) / signPeriod;

  // Formation weight: draw (0→1), hold (1), dissolve (1→0)
  float formWeight;
  if (signPhase < 0.35) {
    formWeight = smoothstep(0.0, 1.0, signPhase / 0.35);
  } else if (signPhase < 0.6) {
    formWeight = 1.0;
  } else {
    formWeight = 1.0 - smoothstep(0.0, 1.0, (signPhase - 0.6) / 0.4);
  }

  // Drawing progress (0..1 during the drawing phase)
  float drawProgress = clamp(signPhase / 0.35, 0.0, 1.0);

  // Per-sign hue shift and drift position
  float signHue = float(signIdx) / 12.0;
  vec3 zodiacColor = accentRamp(fract(0.3 + signHue * 0.7));
  // Slow drift: each sign appears at a slightly different position
  vec2 signDrift = vec2(
    cos(float(signIdx) * 2.61 + uTime * 0.02) * 0.12,
    sin(float(signIdx) * 2.61 + uTime * 0.02) * 0.08
  );

  // The zodiac pattern lives in centered space, offset by signDrift
  vec2 zc = p - signDrift;

  // Sample 22 points along the zodiac curve
  const int ZN = 22;
  vec3 zodiacAcc = vec3(0.0);
  if (formWeight > 0.01) {
    // Star attraction: stars near pattern positions brighten
    for (int i = 0; i < ZN; i++) {
      float t = float(i) / float(ZN - 1);
      vec2 zpt = zodiacPoint(signIdx, t);
      float distToZ = length(zc - zpt);
      float attraction = exp(-distToZ * distToZ * 30.0) * formWeight;
      zodiacAcc += zodiacColor * attraction * 0.08;
    }

    // Calligraphic filaments: draw stroke-by-stroke with a traveling nib
    float strokeF = drawProgress * float(ZN - 1);
    int currentStroke = int(strokeF);
    float strokeLocalT = fract(strokeF);

    // Dissolution noise: during the dissolve phase, break up the lines
    float dissolvePhase = clamp((signPhase - 0.6) / 0.4, 0.0, 1.0);
    float inkDisperse = 1.0;
    if (dissolvePhase > 0.0) {
      inkDisperse = 1.0 - dissolvePhase * 0.7 * fbm(vec3(zc * 8.0, uTime * 0.5));
    }

    for (int i = 0; i < ZN - 1; i++) {
      float strokeReveal = clamp(drawProgress * float(ZN - 1) - float(i), 0.0, 1.0);
      if (strokeReveal <= 0.0) continue;

      float t0 = float(i) / float(ZN - 1);
      float t1 = float(i + 1) / float(ZN - 1);
      vec2 a = zodiacPoint(signIdx, t0) + signDrift;
      vec2 b = zodiacPoint(signIdx, t1) + signDrift;
      float segD = distToSeg(a, b, p);

      // Calligraphic line weight: thick at stroke start, taper at end
      float weight = mix(0.0025, 0.0012, strokeReveal);
      // Slight perpendicular tremor for hand-drawn feel
      float tremor = sin(uTime * 3.0 + float(i) * 1.7) * 0.0003;
      weight += tremor;

      float line = exp(-segD * segD / (weight * weight));
      // Ink quality: wet glow around the line
      float inkGlow = exp(-segD * segD / (weight * weight * 6.0)) * 0.3;

      // Brightness: newer strokes brighter (fresh ink), older slightly faded
      float strokeAge = strokeReveal;
      float bright = strokeAge * (1.0 - 0.4 * (1.0 - strokeAge));

      // Nib glow: a bright point traveling along the current stroke
      if (i == currentStroke && drawProgress < 1.0) {
        vec2 nibPos = mix(a, b, strokeLocalT);
        float nibD = length(p - nibPos);
        bright += exp(-nibD * nibD * 800.0) * 0.4;
        // Nib halo
        bright += exp(-nibD * nibD * 200.0) * 0.12;
      }

      zodiacAcc += zodiacColor * (line + inkGlow) * bright * formWeight * 0.22 * inkDisperse;
    }

    // Anchor star glow: each pattern point has a faint star
    for (int i = 0; i < ZN; i++) {
      float t = float(i) / float(ZN - 1);
      vec2 zpt = zodiacPoint(signIdx, t) + signDrift;
      float starD = length(p - zpt);
      float starGlow = exp(-starD * starD * 400.0);
      zodiacAcc += zodiacColor * starGlow * formWeight * 0.15 * inkDisperse;
    }
  }

  // ── GLYPH FIELD COUPLING (the active mark shapes the starfield) ──
  // When a brand mark is active, its SDF concentrates stars and draws
  // filaments along its outline — the glyphs form in the same calligraphic
  // language as the zodiac signs.
  if (uGlyphActive > 0.5) {
    // uGlyphRect: xy center, zw half-extent (y-up, in uv space).
    // Map the fragment into the glyph's local [0..1] texture space, then
    // sample the SDF there — the mark appears at the right position + scale.
    vec2 glyphCenter = uGlyphRect.xy;
    vec2 glyphHalf = uGlyphRect.zw;
    // Local UV: 0.5 at center, 0..1 across the rect's extent
    vec2 glyphLocalUv = (uv - glyphCenter) / max(glyphHalf, vec2(0.001)) * 0.5 + 0.5;
    // Only sample inside the rect's bounding region
    float inRect = step(0.0, glyphLocalUv.x) * step(glyphLocalUv.x, 1.0)
                 * step(0.0, glyphLocalUv.y) * step(glyphLocalUv.y, 1.0);
    if (inRect > 0.5) {
      // SDF texture is y-down (canvas raster) → flip y for y-up uv
      vec2 sampleUv = vec2(glyphLocalUv.x, 1.0 - glyphLocalUv.y);
      vec4 glyphSample = texture(uGlyphField, sampleUv);
      float sdf = glyphSample.r * 2.0 - 1.0; // decode signed distance
      float coverage = glyphSample.g;

      // Stars concentrate along the mark's outline (sdf ≈ 0)
      float outlineBand = exp(-sdf * sdf * 80.0) * coverage;
      starAcc += accentRamp(0.3) * outlineBand * uGlyphPhase * 0.4;

      // Interior glow: the mark's body fills with a soft nebular tint
      float interior = smoothstep(0.0, -0.3, sdf) * coverage;
      vec3 glyphInk = mix(accentRamp(0.2), accentRamp(0.5), uGlyphPhase);
      starAcc += glyphInk * interior * uGlyphPhase * 0.15;

      // Filament tracing: draw a thin bright line along the outline
      float filament = exp(-sdf * sdf * 2000.0) * coverage;
      starAcc += mix(accentRamp(0.1), clamp(vec3(1.0) - uBg, 0.0, 1.0), 0.6)
               * filament * uGlyphPhase * 0.8;
    }
  }

  // ── POINTER: the surveyor's lens ──
  vec2 pp = (uPointer - 0.5) * vec2(aspect, 1.0);
  vec2 toPtr = p - pp;
  float lensDist = dot(toPtr, toPtr);
  float lens = uPointerActive * exp(-lensDist * 5.0);
  starAcc *= (1.0 + lens * 2.0);
  float ring = uPointerActive * exp(-pow(sqrt(lensDist) - 0.11, 2.0) * 90.0) * 0.25;
  vec3 ringColor = accentRamp(0.45);
  vec3 col;
  if (uTheme < 0.5) {
    // DARK: additive over deep ink + filmic tonemap
    col = uBg;
    col += nebColor * neb * 0.5 * uIntensity;
    col += nebCoreColor * nebCore * 0.3 * uIntensity;
    col += starAcc * uIntensity;
    col += ringColor * ring;
    // Zodiac: low-emission saturated ink added BEFORE the tonemap knee so it
    // reads as colored light, not blown-out white. Capped well below the knee.
    col += zodiacAcc * 0.35 * uIntensity;
    col = col / (col + vec3(0.5));
    col *= 1.18;
    // Airglow grain floor — quietness in the void
    vec3 airglow = mix(accentRamp(0.45), clamp(vec3(1.0) - uBg, 0.0, 1.0), 0.5);
    float grainGate = 1.0 - clamp(dot(starAcc, vec3(0.45)) * 2.0, 0.0, 1.0);
    col += airglow * (hash21(fragCoord) - 0.5) * 0.012 * grainGate;
  } else {
    // LIGHT: subtractive chart on pearl
    col = uBg;
    float nebV = pow(clamp(neb * 0.7, 0.0, 1.0), 0.8) * uIntensity;
    vec3 nebPig = accentRamp(clamp(0.3 + 0.3 * nebV, 0.0, 1.0));
    col *= mix(vec3(1.0), nebPig, nebV * 0.55);
    float starV = clamp(dot(starAcc, vec3(0.45)) * 1.8, 0.0, 1.0);
    col = mix(col, uInk, starV * 0.65 * uIntensity);
    col = mix(col, accentRamp(0.2), pow(starV, 3.0) * 0.12 * uIntensity);
    // Zodiac: prints as dark saturated ink mixed toward the sign's accent hue,
    // NOT as bright star light. A mix of ink + accent at 35% keeps it readable
    // without washing out.
    float zodMask = clamp(dot(zodiacAcc, vec3(0.5)) * 2.0, 0.0, 1.0);
    vec3 zodInk = mix(uInk, accentRamp(signHue * 0.7 + 0.15), 0.35);
    col = mix(col, zodInk, zodMask * 0.7 * uIntensity);
    col = mix(col, ringColor, ring * 0.7);
  }

  // ── VIGNETTE ──
  float vig = smoothstep(1.5, 0.2, length(p));
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