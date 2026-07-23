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


// ── Petroleum Sheen — computed thin-film interference on a flowing oil film ──
const float TAU = 6.28318530718;

// Three-wavelength thin-film interference (Belcour-Barla spectral core):
// reflectance per channel from the optical path difference opd (nm).
vec3 thinFilm(float opd) {
  vec3 lambda = vec3(680.0, 550.0, 440.0);   // R, G, B representative wavelengths
  vec3 phase = (TAU * opd) / lambda;
  vec3 r = 0.5 + 0.5 * cos(phase);            // first-order Airy term
  // a faint second harmonic crisps the filaments without muddying the hue.
  r += 0.12 * (0.5 + 0.5 * cos(2.0 * phase));
  return pow(clamp(r / 1.12, 0.0, 1.0), vec3(1.35));
}

vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float asp = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(asp, 1.0);
  vec2 ptr = (uPointer - 0.5) * vec2(asp, 1.0);
  float t = uTime * 0.04;

  // ── Oil film thickness field: two stacked domain warps → a marbled flow ──
  vec2 q = vec2(
    fbm(vec3(p * 1.6 + vec2(0.0, t), 0.0)),
    fbm(vec3(p * 1.6 + vec2(4.3, -t), 1.7))
  );
  vec2 r = vec2(
    fbm(vec3(p * 2.2 + 1.7 * q + vec2(t * 0.7, 0.0), 2.0)),
    fbm(vec3(p * 2.2 + 1.7 * q + vec2(0.0, -t * 0.6), 4.0))
  );
  float base = fbm(vec3(p * 1.9 + 2.0 * r, t * 0.3));
  base = 0.5 + 0.5 * base;

  // Pointer press — a thickness swell + an outgoing ring ripple (touching oil).
  float pd = length(p - ptr);
  base += uPointerActive * 0.45 * exp(-pd * pd * 10.0) * sin(pd * 20.0 - uTime * 3.0);

  // LEGIBILITY — uIntensity gates fringe density. The smoothstep saturates at
  // 0.72, so both house defaults (dark 1.0, light 0.78) render the full nested
  // rainbow unchanged; lowering intensity collapses the thickness span until
  // only 2-3 broad, slow fringes remain and foreground text sits on the film.
  float fringe = smoothstep(0.0, 0.72, uIntensity);

  // Map to a physical film thickness spanning several interference orders (nm).
  // Clamped to a positive floor so the OPD never implies a negative film. At
  // fringe = 0 the span (~430+90 nm) covers only ~2-3 green-wavelength orders.
  float span = mix(430.0, 1730.0, fringe);
  float swirl = mix(90.0, 360.0, fringe);
  float thickness = clamp(120.0 + span * clamp(base, 0.0, 1.0) + swirl * r.x, 80.0, 2200.0);

  // Incidence varies across the puddle (grazing toward the rim) → angle shift.
  float cosTheta = clamp(1.0 - 0.34 * length(p), 0.42, 1.0);

  // ── Thin-film interference colour from the optical path difference ──
  float filmIOR = 1.32;                        // oil over water
  float opd = 2.0 * filmIOR * thickness * cosTheta;
  vec3 sheen = thinFilm(opd);

  // Rotate the spectral rainbow through the house accents (on-brand, still oil).
  float hueIdx = fract(opd / 1500.0 + 0.04 * t);
  vec3 tint = accentRamp(hueIdx);
  sheen = mix(sheen, sheen * (0.55 + 0.9 * tint), 0.5);

  // Fresnel grazing term brightens the rim; specular glint on the thinnest film.
  float fres = pow(1.0 - cosTheta, 3.0);
  float thinSpot = smoothstep(0.0, 0.18, 1.0 - clamp(thickness / 360.0, 0.0, 1.0));
  float glint = thinSpot * smoothstep(0.6, 1.0, base);

  vec3 col;
  if (uTheme < 0.5) {
    // DARK — sheen floats additively over deep oily water.
    vec3 deep = uBg + uBg * 0.35 * r.y;        // faint depth mottling
    col = deep + sheen * (0.42 + 0.6 * fres + 0.5 * base) * uIntensity;
    col += uAccent2 * glint * 0.5 * uIntensity; // wet specular glint
  } else {
    // LIGHT — a pale pearlescent puddle; capped so the canvas never blows out.
    // Sheen presence rides the fringe gate: at low intensity the broad calm
    // fringes also fade toward plain pearl (unchanged at the 0.78 default).
    vec3 pearl = mix(uBg, sheen, (0.42 + 0.30 * base) * mix(0.4, 1.0, fringe));
    pearl = mix(pearl, uInk, 0.05 * (1.0 - base)); // settle deep film toward ink
    col = pearl;
    col += uAccent2 * glint * 0.16 * mix(0.5, 1.0, fringe);
  }

  // Vignette — keeps foreground text legible.
  float vig = smoothstep(1.18, 0.28, length(p));
  col *= mix(0.6, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}