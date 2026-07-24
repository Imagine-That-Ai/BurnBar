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


// ── Inversion Lattice — 2D Apollonian / circle-inversion fractal ──────────
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 R = uResolution;
  vec2 p = (fragCoord - 0.5 * R) / R.y;

  // ── Living transform: slow rotation + breathing zoom ──
  float tt = uTime * 0.08;
  float zoom = 1.18 + 0.16 * sin(uTime * 0.13);
  p *= zoom;
  float ca = cos(tt), sa = sin(tt);
  p = mat2(ca, -sa, sa, ca) * p;

  // ── Pointer = an inversion center (the one gesture native to this world) ──
  // The cursor is carried through the same zoom+rotation so the reflow stays
  // anchored under the finger; radius scales with zoom to stay screen-fixed.
  // Weight eases in via uPointerActive (host-smoothed), so release relaxes
  // the lattice back instead of snapping.
  float aspect = R.x / max(R.y, 1.0);
  vec2 pc = mat2(ca, -sa, sa, ca) * ((uPointer - 0.5) * vec2(aspect, 1.0) * zoom);
  vec2 dpc = p - pc;
  float pr = 0.25 * zoom;                       // inversion radius (screen units)
  float pw = uPointerActive * uPointerActive * (3.0 - 2.0 * uPointerActive);
  p = mix(p, pc + dpc * (pr * pr / (dot(dpc, dpc) + 1e-4)), pw);

  // ── Circle-inversion fold loop (Apollonian nesting), fixed 8 steps ──
  // Deep-nest anti-alias: pxf is one screen pixel's footprint in domain units;
  // once a step's folded cell shrinks below the pixel (pxf·scale approaches
  // the cell size) its contribution fades out, so high zoom stays clean
  // instead of dissolving into subpixel shimmer.
  float ir = 1.06 + 0.12 * sin(uTime * 0.2);   // inversion radius, breathing
  float pxf = length(fwidth(p));               // pixel footprint after all transforms
  vec2 z = p;
  vec2 zRes = p;                                // z frozen at the last resolvable depth
  float scale = 1.0;
  float scRes = 1.0;                            // scale frozen alongside zRes
  float kAcc = 0.0;
  float trap = 1e9;
  const int STEPS = 8;
  for (int i = 0; i < STEPS; i++) {
    float cover = 1.0 - smoothstep(0.25, 1.0, pxf * scale);  // this depth's coverage
    z = -1.0 + 2.0 * fract(0.5 * z + 0.5);     // fold into the unit cell
    float r2 = dot(z, z);
    float k = ir / (r2 + 1e-6);                 // circle inversion
    z *= k;
    scale = min(scale * k, 1e30);               // clamp: 8 huge k's would hit +inf
    kAcc += k * cover;
    // Orbit trap (ring halo); subpixel depths get pushed out of the min so
    // exp(-6·trap) fades them instead of speckling.
    trap = min(trap, abs(r2 - 0.5) + (1.0 - cover) * 0.75);
    zRes = mix(zRes, z, cover);
    scRes = mix(scRes, scale, cover);
  }

  // ── Distance-estimator ring edge (fwidth-AA) + orbit-trap glow ──
  float sc = max(scRes, 1e-6);                  // guard log()/division below
  float de = abs(zRes.y) / sc;
  float w = fwidth(de) + 1e-4;
  float line = 1.0 - smoothstep(0.0, 2.6 * w, de);
  float glow = exp(-6.0 * trap);
  float shape = clamp(line + 0.55 * glow, 0.0, 1.0);

  // ── Palette hue from inversion scale + fold accumulation ──
  float fold = fract(0.06 * log(sc) + 0.16 * kAcc - 0.08 * uTime);
  vec3 ramp = accentRamp(fold);
  vec3 base = uBg;

  // ── Theme composite ──
  // DARK: luminous rings added over deep ink (the canonical look).
  vec3 lumRings = base + mix(uInk, ramp, 0.85) * shape * (0.6 + 0.8 * uIntensity);
  lumRings += ramp * 0.04 * (0.5 + 0.5 * sin(log(sc) * 1.5));   // faint scale shimmer
  // LIGHT: ink-deposit rings on the warm paper bg (never blows out).
  vec3 inkRings = mix(base, mix(ramp, uInk, 0.55), shape * (0.5 + 0.6 * uIntensity));

  vec3 col = (uTheme < 0.5) ? lumRings : inkRings;

  // ── Vignette (keeps foreground text legible) ──
  float vig = smoothstep(1.2, 0.35, length(uv - 0.5) * 1.4);
  col *= mix(0.82, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}


void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}