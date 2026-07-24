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


// Cheap 2-octave fbm for the hot cloud loop (full 3-octave is overkill here).
float sa_fbm2(vec3 q){
  return snoise(q) * 0.55 + snoise(q * 2.05) * 0.28;
}

// Facet hash → stable unit direction for prismatic motes.
vec3 sa_facetN(float id){
  float a = fract(sin(id * 127.1) * 43758.5453);
  float b = fract(sin(id * 269.5) * 43758.5453);
  float th = a * 6.2831853;
  float ph = b * 3.14159265;
  return normalize(vec3(sin(ph) * cos(th), cos(ph), sin(ph) * sin(th)));
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float aspect = uResolution.x / max(uResolution.y, 1.0);

  // ── Clocks ──────────────────────────────────────────────────────────────
  float t     = uTime * 0.055;   // cloud drift
  float tSun  = uTime * 0.028;   // sun orbit (very slow)
  float tHue  = uTime * 0.017;   // hue breath
  float breath = 0.5 + 0.5 * sin(uTime * 0.21);

  // ── Pointer thermal (aspect-corrected) ──────────────────────────────────
  vec2 pp = (uPointer - 0.5) * vec2(aspect, 1.0);
  vec2 toPtr = p - pp;
  float thermal = uPointerActive * exp(-7.5 * dot(toPtr, toPtr));

  // ── Brand sunrise ramp (plum → magenta → coral → gold) ─────────────────
  // Vertical grad: 0 at zenith, 1 at nadir/horizon.
  float elev = clamp(0.55 - p.y * 0.95, 0.0, 1.0);
  vec3 zenith, mid, horizon, sunCore, cloudLit, cloudDeep, shaftCol, moteHi;

  if (uTheme >= 0.5) {
    // Light theme: pale dawn wash, still brand-true.
    zenith  = mix(uBg, accentRamp(0.78), 0.28 + 0.12 * uIntensity);
    mid     = mix(uBg, accentRamp(0.45), 0.34 + 0.14 * uIntensity);
    horizon = mix(uBg, accentRamp(0.18), 0.42 + 0.18 * uIntensity);
    sunCore = mix(vec3(1.0), accentRamp(0.12), 0.35);
    cloudLit  = mix(vec3(1.0), uBg, 0.18);
    cloudDeep = mix(uBg, accentRamp(0.55), 0.35);
    shaftCol  = mix(accentRamp(0.2), vec3(1.0), 0.35);
    moteHi    = mix(accentRamp(0.15), vec3(1.0), 0.4);
  } else {
    // Dark theme: the full balloon palette night-to-dawn.
    zenith  = mix(uBg * 0.55, accentRamp(0.82), 0.55 + 0.2 * uIntensity); // plum
    mid     = mix(uBg, accentRamp(0.55), 0.62 + 0.18 * uIntensity);        // magenta
    horizon = mix(uBg, accentRamp(0.18), 0.72 + 0.2 * uIntensity);         // coral/gold
    sunCore = mix(accentRamp(0.08), vec3(1.0, 0.92, 0.78), 0.55);
    cloudLit  = mix(uInk, accentRamp(0.25), 0.45) * 0.85;
    cloudDeep = mix(uBg, accentRamp(0.7), 0.4) * 0.9;
    shaftCol  = mix(accentRamp(0.15), sunCore, 0.55);
    moteHi    = mix(accentRamp(0.12), sunCore, 0.65);
  }

  // Soft banded sky with a slow hue roll so the dawn never freezes.
  float band = elev + 0.04 * sin(p.x * 2.4 + tHue * 2.0) + 0.03 * breath;
  vec3 sky = mix(zenith, mid, smoothstep(0.08, 0.48, band));
  sky = mix(sky, horizon, smoothstep(0.42, 0.92, band));

  // ── Rising sun disc + bloom ─────────────────────────────────────────────
  vec2 sunPos = vec2(0.18 * sin(tSun), -0.28 + 0.04 * cos(tSun * 0.7));
  sunPos += 0.06 * thermal * normalize(toPtr + 1e-3); // thermal nudges the glow
  float sunDist = length(p - sunPos);
  float sunDisk = smoothstep(0.085, 0.02, sunDist);
  float sunHalo = exp(-sunDist * 6.5) * (0.55 + 0.25 * uIntensity);
  float sunBloom = exp(-sunDist * 2.2) * 0.35;
  sky += sunCore * (sunDisk * 1.15 + sunHalo + sunBloom);

  // ── Volumetric cloud decks (front-to-back, short march) ─────────────────
  // Ray: look slightly up into layered decks. Cheap 28-step march.
  vec3 rd = normalize(vec3(p.x * 0.85, 0.55 + p.y * 0.35, 1.15));
  vec3 ro = vec3(0.0, 0.15, t * 1.8);

  vec3 acc = vec3(0.0);
  float trans = 1.0;
  float lining = 0.0;
  float shaftAcc = 0.0;

  const int STEPS = 28;
  const float T_NEAR = 0.8;
  const float T_FAR = 9.5;
  float dt = (T_FAR - T_NEAR) / float(STEPS);
  float jit = hash21(fragCoord);

  for (int i = 0; i < STEPS; i++) {
    float tt = T_NEAR + (float(i) + jit) * dt;
    vec3 pos = ro + rd * tt;

    // Two stacked decks with different scales / drift.
    vec3 q1 = pos * vec3(0.42, 1.1, 0.42);
    q1.x += t * 0.35;
    q1.z += t * 0.12;
    // Thermal lifts density locally under the cursor (mapped into world xz).
    q1.y -= thermal * 0.35;

    float n1 = sa_fbm2(q1);
    float deck1 = smoothstep(0.12, 0.55, n1 + 0.18 - abs(pos.y - 0.35) * 1.6);

    vec3 q2 = pos * vec3(0.28, 0.9, 0.28) + 3.7;
    q2.x -= t * 0.22;
    float n2 = sa_fbm2(q2);
    float deck2 = smoothstep(0.18, 0.6, n2 + 0.1 - abs(pos.y + 0.15) * 1.3);

    float dens = max(deck1 * 0.85, deck2 * 0.65);
    dens *= 0.55 + 0.45 * uIntensity;

    if (dens > 0.01) {
      // Lit from the sun direction — brighter on the side facing the sun.
      vec3 L = normalize(vec3(sunPos.x, 0.35, 0.8) - pos * 0.15);
      float nl = clamp(dot(normalize(vec3(n1, 0.6, n2)), L) * 0.5 + 0.5, 0.0, 1.0);
      vec3 ccol = mix(cloudDeep, cloudLit, nl);
      // Warm underside from the horizon colour.
      ccol = mix(ccol, horizon, 0.18 * (1.0 - nl));

      float a = clamp(dens * 0.55 * dt * 1.6, 0.0, 1.0);
      // Silver lining: thin density shells still transparent.
      float thin = smoothstep(0.35, 0.05, dens) * nl;
      lining += trans * a * thin;

      acc += trans * a * ccol;
      trans *= 1.0 - a;

      // Cheap god-ray: accumulate transmittance near the sun axis.
      float axis = exp(-12.0 * length(cross(normalize(pos - ro), normalize(vec3(sunPos, 1.0)))));
      shaftAcc += trans * dens * axis * dt;

      if (trans < 0.03) break;
    }
  }

  vec3 col = acc + trans * sky;
  col += lining * sunCore * (0.45 + 0.35 * uIntensity);
  col += shaftCol * shaftAcc * (0.55 + 0.4 * thermal);

  // ── Prismatic motes (geometric facets echoing the balloon panels) ───────
  // Sparse, soft, additive — never muddy the sky.
  float mote = 0.0;
  vec3 moteCol = vec3(0.0);
  for (int k = 0; k < 5; k++) {
    float id = float(k) + 1.7;
    float ph = fract(sin(id * 91.7) * 43758.5453);
    vec2 mp = vec2(
      fract(sin(id * 12.9898) * 43758.5453) * 2.0 - 1.0,
      fract(sin(id * 78.233) * 43758.5453) * 1.6 - 0.55
    );
    mp.x *= aspect * 0.55;
    // Slow drift + thermal pull
    mp += 0.04 * vec2(sin(t * 1.3 + id), cos(t * 0.9 + id * 1.7));
    mp += 0.03 * thermal * (pp - mp);

    float d = length(p - mp);
    float body = smoothstep(0.065, 0.012, d);
    // Faceted diamond silhouette via max of rotated box edges
    vec2 q = (p - mp) * 14.0;
    float ang = ph * 6.2831853 + t * 0.4;
    float ca = cos(ang);
    float sn = sin(ang);
    q = mat2(ca, -sn, sn, ca) * q;
    float dia = max(abs(q.x) + abs(q.y) * 0.75, abs(q.y) + abs(q.x) * 0.35);
    float facet = smoothstep(1.15, 0.55, dia);

    vec3 N = sa_facetN(id + floor(t * 0.2));
    float spark = pow(max(dot(N, normalize(vec3(0.3, 0.7, 0.5))), 0.0), 6.0);
    float m = max(body * 0.35, facet * 0.85) * (0.35 + 0.65 * spark);
    m *= 0.35 + 0.25 * uIntensity;
    vec3 mc = mix(moteHi, accentRamp(fract(ph + tHue)), 0.45);
    moteCol += mc * m;
    mote += m;
  }
  col += moteCol * 0.85;

  // Soft vignette toward uBg so the frame never punches to pure black/white.
  float vig = smoothstep(1.45, 0.28, length(p * vec2(0.85, 1.0)));
  col = mix(uBg, col, 0.22 + 0.78 * vig);

  // Gentle film grain (brand-sky polish).
  col += (hash21(fragCoord + floor(uTime * 12.0)) - 0.5) * 0.018;

  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}