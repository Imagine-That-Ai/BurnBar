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


vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  // Aspect-correct pixel coordinates (original: x/iResolution.y - .8).
  vec2 x = (fragCoord - 0.5 * uResolution) / uResolution.y;

  // ── Palette-derived colour set (both themes built from the uniforms) ──────
  // grad: 0 at the top of the frame, 1 at the bottom (the original sky -= x.y
  // gradient: darker zenith, lighter horizon).
  float grad = clamp(0.5 - x.y, 0.0, 1.0);
  vec3 comp = clamp(vec3(1.0) - uBg, 0.0, 1.0); // bg-complement

  vec3 skyTop, skyBot, cloudLit, cloudDeep, lining;
  if (uTheme >= 0.5) {
    // Warmed day: pearl bg lifted through the accent ramp.
    skyTop = mix(uBg, accentRamp(0.7), 0.22 + 0.14 * uIntensity);
    skyBot = mix(uBg, accentRamp(0.3), 0.10 + 0.06 * uIntensity);
    cloudLit = mix(vec3(1.0), uBg, 0.25);
    cloudLit = mix(cloudLit, accentRamp(0.35), 0.10 * uIntensity);
    cloudDeep = mix(uBg, mix(comp, uAccent0, 0.5), 0.45);
    lining = mix(vec3(1.0), uAccent3, 0.30);
  } else {
    // Moonlit night: deepened bg sky, ink-derived silver cloud bodies.
    skyTop = uBg * 0.72;
    skyBot = mix(uBg, accentRamp(0.65), 0.16 + 0.10 * uIntensity);
    cloudLit = mix(uInk, uAccent2, 0.35) * 0.55;
    cloudDeep = mix(uBg, uAccent0, 0.25) * 0.85;
    lining = mix(uInk, uAccent3, 0.45) * 0.9;
  }
  vec3 sky = mix(skyTop, skyBot, grad);

  // ── Pointer = wind (aspect-corrected exp falloff, liquidMetal idiom) ──────
  // pp lives in the same centered x-space as the ray screen coords.
  float aspect = uResolution.x / max(uResolution.y, 1.0);
  vec2 pp = (uPointer - 0.5) * vec2(aspect, 1.0);
  vec2 toPtr = x - pp;
  float wind = uPointerActive * exp(-10.0 * dot(toPtr, toPtr));
  vec2 windDir = toPtr / (length(toPtr) + 1e-3);

  // Ray direction: 0.8 forward, x.x right, x.y up (the original vec4 d).
  vec3 rd = vec3(0.8, x.x, x.y);

  // ── Front-to-back march (exact over-operator twin of the original
  //    back-to-front alpha blend, which lets us break on saturation) ─────────
  // Density is 0.25 + 0.25*fbm  ->  bounded by DENS_CAP, so a cloud sample
  // (f = height + 1 - dens < 0) needs height < DENS_CAP - 1. Only rays with
  // x.y < 0 ever get there, and the first possible hit is at
  // t = (1 - DENS_CAP) / (0.05 * -x.y): sky pixels march zero steps.
  const float DENS_CAP = 0.5;
  const float T_FAR = 200.0;
  const int STEPS = 64;

  vec3 acc = vec3(0.0);
  float trans = 1.0;
  float liningAcc = 0.0;

  if (x.y < -0.01) {
    float tNear = (1.0 - DENS_CAP) / (0.05 * -x.y);
    if (tNear < T_FAR - 1.0) {
      float dt = (T_FAR - tNear) / float(STEPS);
      float jit = hash21(fragCoord); // per-pixel jitter hides the 64-step banding
      for (int i = 0; i < STEPS; i++) {
        float t = tNear + (float(i) + jit) * dt;
        vec3 p = 0.05 * t * rd; // (forward, right, up)
        float h = p.z;          // height before any drift

        // Camera drift: fly forward + slow sideways slide (retuned for the
        // shared fbm frequency; the single-pass clock was always live).
        p.x += uTime * 0.5;
        p.y += uTime * 0.12;

        // Shared 3-octave fbm replaces the 4-octave inline hash stack. The
        // wind combs the noise domain sideways/up away from the cursor.
        vec3 q = p * 0.35;
        q.yz += windDir * (wind * 0.45);
        float dens = 0.25 + 0.25 * fbm(q);

        // Signed cloud surface (original f = p.w + 1 - noise); the wind also
        // carves the deck open locally, visibly parting the clouds.
        float f = h + 1.0 - dens + wind * 0.35;
        if (f < 0.0) {
          float fc = max(f, -1.0);
          vec3 cloudCol = mix(cloudLit, cloudDeep, -fc);
          // Per-step alpha rescaled by dt so optical depth matches the
          // original -f*0.4-per-unit extinction at any step count.
          float a = clamp(-f * 0.4 * dt, 0.0, 1.0);

          // CRAFT CUE — silver lining: thin-shell samples (-f near 0) hit
          // while the ray is still transparent are the lit cloud tops.
          float thin = smoothstep(0.28, 0.02, -f);
          liningAcc += trans * a * thin;

          acc += trans * a * cloudCol;
          trans *= 1.0 - a;
          if (trans < 0.02) break; // opacity saturated — stop marching
        }
      }
    }
  }

  vec3 col = acc + trans * sky;
  col += liningAcc * lining * (0.5 + 0.5 * uIntensity);

  // Gentle vignette; the uBg floor keeps the frame never-black in both themes.
  float vig = smoothstep(1.4, 0.25, length(x));
  col = mix(uBg, col, 0.3 + 0.7 * vig);
  return col;
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}