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


// ── Kinetic Stipple — curl-advected density as streaming variable-size dots ──

// Scalar potential for the curl field: a single simplex slice over slow time.
float ksPot(vec2 p, float tz){ return snoise(vec3(p, tz)); }

// Divergence-free wind = curl of the scalar potential (Bridson 2007). Central
// differences with a fixed epsilon ⇒ a perpendicular gradient (rot 90°).
vec2 ksCurl(vec2 p, float tz){
  float e = 1.5e-3;
  float dy = ksPot(p + vec2(0.0, e), tz) - ksPot(p - vec2(0.0, e), tz);
  float dx = ksPot(p + vec2(e, 0.0), tz) - ksPot(p - vec2(e, 0.0), tz);
  return vec2(dy, -dx) / (2.0 * e);
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  float tz = uTime * 0.06;
  const float FIELD_SCALE = 0.0016;   // wind spatial frequency
  const float STREAM_PX   = 120.0;    // how far density is pulled upstream
  const float DENS_SCALE  = 0.0042;   // density-field spatial frequency

  // ── Wind direction at this fragment (+ pointer bow-wave swirl) ──
  vec2 wind = ksCurl(fragCoord * FIELD_SCALE, tz);
  float speed = clamp(length(wind), 0.0, 2.0);
  vec2 dir = speed > 1e-5 ? wind / speed : vec2(1.0, 0.0);
  if(uPointerActive > 0.5){
    vec2 pp = uPointer * uResolution;
    vec2 dpx = fragCoord - pp;
    float R = 0.22 * min(uResolution.x, uResolution.y);
    float f = exp(-dot(dpx, dpx) / (R * R));
    vec2 sw = normalize(vec2(-dpx.y, dpx.x) + 1e-3);
    dir = normalize(dir + sw * f * 1.8);
  }

  // ── 3×3 stipple-cell stitch: one streaming dot per cell, seams bled ──
  float cell = 14.0;
  vec2 g = fragCoord / cell;
  vec2 id = floor(g);
  vec2 fp = fract(g);
  float ink = 0.0;
  float litDens = 0.0;
  float homeDens = 0.5;
  // Over-unity travel: each dot crosses its own cell seam over its life
  // (×1.15 in still air, up to ×1.6 in fast wind). Bounded so the worst-case
  // anchor (0.5 ± 0.8 ± 0.21 jitter) stays within the 3×3 stitch's reach.
  float travel = 1.15 + 0.45 * min(speed, 1.0);
  for(int oy = -1; oy <= 1; oy++){
    for(int ox = -1; ox <= 1; ox++){
      vec2 nid = id + vec2(float(ox), float(oy));
      vec2 cellPx = (nid + 0.5) * cell;
      // Sample the density UPSTREAM so dots inherit the field that flowed in.
      vec2 src = cellPx - dir * (STREAM_PX * (0.6 + 0.4 * speed));
      float dens = clamp(fbm(vec3(src * DENS_SCALE, uTime * 0.12)) * 0.6 + 0.5, 0.0, 1.0);
      if(ox == 0 && oy == 0){ homeDens = dens; }   // reused for the gap haze
      // Per-cell life clock: faster where the wind is faster.
      float life = fract(hash21(nid) + uTime * (0.10 + 0.16 * speed));
      float env = sin(life * 3.14159265);          // birth→peak→death opacity
      vec2 jit = (vec2(hash21(nid + 3.1), hash21(nid + 7.7)) - 0.5) * 0.42;
      vec2 ctr = vec2(0.5) + jit + dir * ((life - 0.5) * travel);  // streams across seams
      float radius = smoothstep(0.16, 0.92, dens) * 0.46;
      float aa = 1.5 / cell;
      vec2 d = (fp - vec2(float(ox), float(oy))) - ctr;
      float cov = (1.0 - smoothstep(radius - aa, radius + aa, length(d))) * env;
      if(cov > ink){ ink = cov; litDens = dens; }
    }
  }

  // ── Palette-driven composite (theme-branched) ──
  vec3 dotTint = accentRamp(0.16 + 0.6 * litDens + 0.2 * speed);
  vec3 col;
  if(uTheme < 0.5){
    // DARK: hot dots lifted toward the perceptually lightest accent (Rec.709
    // luma select) — palette-true, never raw white.
    const vec3 KS_LUMA = vec3(0.2126, 0.7152, 0.0722);
    vec3 lite = uAccent0;
    lite = dot(uAccent1, KS_LUMA) > dot(lite, KS_LUMA) ? uAccent1 : lite;
    lite = dot(uAccent2, KS_LUMA) > dot(lite, KS_LUMA) ? uAccent2 : lite;
    lite = dot(uAccent3, KS_LUMA) > dot(lite, KS_LUMA) ? uAccent3 : lite;
    vec3 hot = mix(dotTint, lite, 0.35 * litDens);
    col = mix(uBg, hot, ink * uIntensity);
  } else {
    // LIGHT: ink-deposit dots on warm paper (never blows out).
    vec3 dark = mix(dotTint, uInk, 0.55);
    col = mix(uBg, dark, ink * (0.85 * uIntensity));
  }

  // ── Faint advected haze in the gaps between dots ──
  // Reuses the home cell's density sample (no extra fbm — 9 calls/px total).
  col = mix(col, accentRamp(0.1 + 0.3 * homeDens), 0.04 * uIntensity * (1.0 - ink));

  // ── Vignette (keeps foreground text legible) ──
  vec2 pc = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float vig = smoothstep(1.6, 0.2, length(pc));
  col = mix(uBg, col, 0.45 + 0.55 * vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}