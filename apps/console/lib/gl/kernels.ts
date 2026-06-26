/**
 * The curated WebGL2 backdrop kernels.
 *
 * Each body defines `vec3 renderKernel(vec2 uv, vec2 fragCoord)` and is ported
 * verbatim from the Liquid Glass Studio prototype's gl-kernels.js (which itself
 * extracted them from imaginethat-llc/src/kernels). The palettes are chosen so
 * the default reads as the BurnBar coral brand; the rest offer distinct moods.
 */

export type KernelId =
  | "liquidGlass"
  | "aurora"
  | "plasmaOrbs"
  | "oilfield"
  | "suminagashi";

export interface KernelPalette {
  /** Background base color the kernel sits on (rendered in dark/vivid mode). */
  base: string;
  /** uAccent0..3 — the four-stop accent ramp the kernel samples. */
  accents: [string, string, string, string];
  /** uInk — the deep contrast color. */
  ink: string;
}

export interface KernelSpec {
  id: KernelId;
  label: string;
  /** GLSL body defining renderKernel(). */
  body: string;
  palette: KernelPalette;
}

const KERNEL_BODIES: Record<KernelId, string> = {
  aurora: `
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float tBase  = uTime * 0.045;
  float tDrift = uTime * 0.018;
  float breath = smoothstep(0.15, 0.85, 0.5 + 0.5 * sin(uTime * 0.224));
  float tCalm  = 0.5 + 0.5 * sin(uTime * 0.11);
  vec2 q = vec2(fbm(vec3(p * 1.4, tBase)), fbm(vec3(p * 1.4 + 5.2, tBase)));
  vec2 r = vec2(
    fbm(vec3(p * 1.4 + 1.2 * q + vec2(1.7, 9.2), tBase * 1.15)),
    fbm(vec3(p * 1.4 + 1.2 * q + vec2(8.3, 2.8), tBase * 1.15)));
  float fWarp = fbm(vec3(p * 1.4 + 1.6 * r, tBase * 0.9));
  vec2 flow = 1.6 * r + 0.7 * q;
  vec3 acc = vec3(0.0); float totalLum = 0.0;
  for (int i = 0; i < 3; i++) {
    float di = float(i);
    float depth = 1.0 - 0.33 * di;
    float lt = tBase * (1.0 + 0.25 * di) + di * 2.39989;
    vec2 lp = p * (1.0 - 0.16 * di);
    lp.x += tDrift * (1.0 + 0.25 * di) * 1.6;
    float x = lp.x * 3.2 + flow.x * (1.2 * depth) + lt;
    float hgt = lp.y * 1.4 + fWarp * 0.9 + flow.y * 0.5;
    float fil = 0.0, amp = 1.0, fq = 1.0;
    for (int k = 0; k < 3; k++) { fil += amp * abs(sin(x * fq + hgt * 1.3)); fq *= 2.3; amp *= 0.5; }
    fil *= 0.571;
    float edge = smoothstep(0.0, 1.0, fil);
    float core = 1.0 - edge;
    core = core * core * (3.0 - 2.0 * core);
    float glow = core * core;
    float env = smoothstep(-1.1, -0.2, lp.y) * smoothstep(1.3, 0.1, lp.y);
    float irid = 0.12 * sin(hgt * 6.2831 + length(r) * 4.0 + tBase * 0.5);
    float hue = clamp(0.5 + hgt * 0.5 + 0.12 * fWarp + irid + di * 0.05, 0.0, 1.0);
    vec3 accent = accentRamp(hue);
    float layerGate = smoothstep(0.0, 1.0, tCalm * 1.4 - di * 0.35);
    float lum = glow * env * layerGate;
    acc += accent * lum * (0.62 / (1.0 + 0.5 * di));
    acc += vec3(0.7, 0.85, 1.0) * pow(glow, 4.0) * env * 0.18 * (1.0 - 0.3 * di);
    totalLum += lum;
  }
  float pCell = floor(p.x * 0.6 + tDrift * 1.3);
  float pPhase = fract(p.x * 0.6 + tDrift * 1.3);
  float pillar = exp(-pow((pPhase - 0.5) * 7.0, 2.0));
  float pillarGate = smoothstep(0.55, 0.95, snoise(vec3(pCell * 3.1, 0.0, tDrift * 0.5)) * 0.5 + 0.5);
  float rise = 0.5 + 0.5 * sin(uv.y * 3.14159 - uTime * 1.1);
  vec3 pillarHue = accentRamp(clamp(0.35 + uv.y * 0.5, 0.0, 1.0));
  acc += pillarHue * pillar * pillarGate * rise * 0.7 * breath;
  acc *= mix(0.86, 1.18, breath);
  vec3 col;
  if (uTheme < 0.5) {
    col = uBg;
    col += acc * (0.95 * uIntensity);
    col = col / (col + vec3(0.55));
    col *= 1.18;
    col += vec3(0.8, 0.85, 1.0) * (hash21(fragCoord) - 0.5) * 0.015 * (1.0 - clamp(totalLum * 2.0, 0.0, 1.0));
  } else {
    col = uBg;
    float v = pow(clamp(dot(acc, vec3(0.45)) * 1.65, 0.0, 1.0), 0.72);
    vec3 ribbon = accentRamp(clamp(0.40 + 0.36 * v + 0.08 * fWarp, 0.0, 1.0));
    vec3 pearl = mix(uBg, ribbon, 0.88);
    col = mix(col, pearl, v * 0.62 * uIntensity);
    col = mix(col, uInk, smoothstep(0.10, 0.58, v) * 0.045 * uIntensity);
    col = mix(col, ribbon, pow(v, 2.4) * 0.18 * uIntensity);
  }
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp);
    float halo = exp(-dd * dd * 3.5);
    col += accentRamp(fract(0.55 + uTime * 0.1)) * halo * 0.25 * breath * (uTheme < 0.5 ? 1.0 : 0.5);
  }
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.35 + 0.65 * vig);
  return col;
}
`,

  liquidGlass: `
const float WARP_AMP      = 0.52;
const float HEIGHT_FREQ   = 2.80;
const float HEIGHT_AMP    = 0.58;
const float DISP_BASE     = 0.034;
const float DISP_BREATH   = 0.022;
const float FRESNEL_POW   = 1.85;
const float RIM_INTENSITY = 1.15;
const float CAUSTIC_GAIN  = 0.92;
const float CAUSTIC_BREATH= 0.34;
const float POINTER_RADIUS= 0.22;
const float POINTER_DEPTH = 0.32;
const float BREATH_14S    = 14.0;
const float BREATH_31S    = 31.0;
const float PHASE_ROLL    = 0.04;
float gbreath(float t){
  float ms = t * 1000.0;
  return 0.5 + 0.5 * (0.62 * sin(6.2831853 * ms / BREATH_14S) + 0.38 * sin(6.2831853 * ms / BREATH_31S + 1.3));
}
vec3 gbackground(vec2 p, float t){
  vec2 q = vec2(fbm(vec3(p * 1.2, t)), fbm(vec3(p * 1.2 + 5.2, t)));
  vec2 w = WARP_AMP * q;
  float hue = clamp(0.5 + 0.32 * fbm(vec3((p + w) * 1.4, t * 0.9)) + 0.10 * sin(t * PHASE_ROLL), 0.0, 1.0);
  return accentRamp(hue);
}
float glassHeight(vec2 p, float t, vec2 pp, float pActive, float br){
  float h = fbm(vec3(p * HEIGHT_FREQ, t * 0.45)) * HEIGHT_AMP;
  h += 0.18 * snoise(vec3(p * (HEIGHT_FREQ * 1.8), t * 0.30 + 1.3));
  if (pActive > 0.5){
    float d  = distance(p, pp);
    float f  = exp(-(d * d) / (POINTER_RADIUS * POINTER_RADIUS));
    h -= f * POINTER_DEPTH * (0.7 + 0.3 * br);
  }
  return h;
}
float causticField(vec2 p, float t, float br){
  float l = 1.0 - smoothstep(-0.05, -0.95, p.y);
  if (l <= 0.0) return 0.0;
  vec2 q = vec2(p.x * 1.6, p.y * 0.9);
  float a = fbm(vec3(q * 1.0, t * 0.15));
  float b = fbm(vec3(q * 2.3 + vec2(3.1, 1.7), t * 0.21 + 2.0));
  float c = 1.0 - abs(2.0 * (a * b) - 1.0);
  c = pow(c, 2.6);
  return c * l;
}
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float br     = gbreath(uTime);
  float tField = uTime * 0.06;
  float disp   = DISP_BASE + DISP_BREATH * br;
  float cGain  = CAUSTIC_GAIN + CAUSTIC_BREATH * br;
  vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
  float h = glassHeight(p, tField, pp, uPointerActive, br);
  vec2  n = vec2(dFdx(h), dFdy(h));
  float slope = length(n);
  vec3  normal = normalize(vec3(-n * 2.9, 1.0));
  vec2  refr = normal.xy * disp * (0.9 + 2.4 * slope);
  vec3  bg;
  bg.r = gbackground(p + refr * 1.15, tField).r;
  bg.g = gbackground(p + refr * 1.00, tField).g;
  bg.b = gbackground(p + refr * 0.85, tField).b;
  float fres = pow(clamp(1.0 - normal.z, 0.0, 1.0), FRESNEL_POW);
  vec3 rimCol = vec3(accentRamp(fract(0.05 + 0.10 * br)).r, accentRamp(fract(0.55 + 0.10 * br)).g, accentRamp(fract(0.95 + 0.10 * br)).b);
  float caust = causticField(p, tField, br);
  vec3  causticCol = accentRamp(fract(0.45 + 0.18 * br));
  vec3 col;
  if (uTheme < 0.5){
    col  = uBg;
    col  = mix(col, bg, 0.76 + 0.18 * br);
    col += bg * fres * 0.5;
    col += causticCol * caust * cGain * uIntensity;
    col += rimCol * fres * RIM_INTENSITY * (0.7 + 0.3 * br);
    col  = col / (col + vec3(0.55));
    col *= 1.14;
    col += vec3(0.8, 0.85, 1.0) * (hash21(fragCoord + disp * 100.0) - 0.5) * 0.014 * (1.0 - clamp(slope * 4.0, 0.0, 1.0));
  } else {
    vec3 paper = uBg;
    paper = mix(paper, accentRamp(0.42), 0.10 * uIntensity);
    float lum  = clamp(dot(bg, vec3(0.45)) * 1.4, 0.0, 1.0);
    vec3  tint = mix(paper, bg, 0.55);
    col = mix(paper, tint, lum * 0.55 * uIntensity);
    col = mix(col, causticCol, caust * cGain * 0.34 * uIntensity);
    col += rimCol * fres * (RIM_INTENSITY * 0.38) * (0.7 + 0.3 * br);
    col = mix(col, uInk, smoothstep(0.20, 0.55, slope) * 0.045 * uIntensity);
  }
  if (uPointerActive > 0.5){
    float d  = distance(p, pp);
    float halo = exp(-d * d * 4.0);
    col += accentRamp(fract(0.55 + uTime * 0.08)) * halo * 0.22 * (uTheme < 0.5 ? 1.0 : 0.55);
  }
  float vig = smoothstep(1.55, 0.20, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);
  return col;
}
`,

  plasmaOrbs: `
#define ORB_COUNT 6
float orbHash(float n){ return fract(sin(n) * 43758.5453123); }
float orbField(vec2 p, vec2 c, float r, float s){
  vec2 d = p - c; float dd = dot(d, d);
  float k = max(r * r - dd, 0.0) / max(s * s, 1e-4);
  return k * k;
}
vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float t = uTime * 0.18; float tHue = uTime * 0.07; float tLow = uTime * 0.045;
  vec2 cursor = vec2(0.0);
  if (uPointerActive > 0.5) cursor = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
  vec2 warp = vec2(fbm(vec3(p * 0.9, tLow)), fbm(vec3(p * 0.9 + 5.2, tLow)));
  vec2 pw = p + 0.18 * warp;
  vec2 centre = 0.10 * vec2(sin(tLow * 1.7), cos(tLow * 1.3));
  float density = 0.0; vec3 weightedHue = vec3(0.0); float weightSum = 0.0; float rimAccum = 0.0;
  for (int i = 0; i < ORB_COUNT; i++) {
    float fi = float(i);
    float ph = orbHash(fi * 1.3) * 6.2831853;
    float sp = 0.32 + 0.18 * orbHash(fi * 2.1 + 0.7);
    float rad = 0.13 + 0.10 * orbHash(fi * 3.7 + 1.9);
    float soft = 0.18 + 0.10 * orbHash(fi * 5.3 + 4.1);
    float orbitR = 0.30 + 0.22 * orbHash(fi * 7.1 + 2.3);
    vec2  c = centre + orbitR * vec2(cos(t * sp + ph), sin(t * sp * 0.83 + ph));
    if (uPointerActive > 0.5) c += 0.04 * (cursor - c) * (1.0 - orbHash(fi * 11.0 + 3.0));
    float breathe = 1.0 + 0.10 * sin(uTime * (0.6 + 0.2 * fi) + ph);
    float r = rad * breathe; float s = soft * breathe;
    float w = orbField(pw, c, r, s); density += w;
    float hueT = fract(tHue + 0.18 * fi + 0.07 * orbHash(fi * 9.7 + 6.1));
    weightedHue += accentRamp(hueT) * w; weightSum += w;
    float eps = 0.004;
    float wL = orbField(pw, c, r - eps, s); float wR = orbField(pw, c, r + eps, s);
    rimAccum += abs(wL - wR) * (1.0 / (eps * 2.0));
  }
  vec3 orbHue = weightSum > 1e-4 ? weightedHue / weightSum : accentRamp(0.5);
  float core = smoothstep(0.05, 0.55, density);
  float halo = smoothstep(0.0, 0.08, density) * (1.0 - core);
  float phase = density * 1.4 + tHue * 1.3 + length(warp) * 0.5;
  vec3 slick = vec3(accentRamp(fract(phase + 0.10)).r, accentRamp(fract(phase + 0.34)).g, accentRamp(fract(phase + 0.62)).b);
  float ca = 0.018 + 0.012 * halo;
  vec3 caRgb = vec3(smoothstep(0.05,0.55,density+ca*1.6), smoothstep(0.05,0.55,density), smoothstep(0.05,0.55,density-ca*1.6));
  vec3 col;
  if (uTheme < 0.5) {
    col = uBg;
    col += orbHue * core * 0.55 * uIntensity;
    col += slick * halo * 0.40 * uIntensity;
    col += caRgb * (rimAccum * 0.05) * uIntensity;
    col = col / (col + vec3(0.50)); col *= 1.18;
    col += vec3(0.05, 0.06, 0.10) * (1.0 - core) * 0.4;
  } else {
    col = uBg;
    vec3 paper = mix(col, orbHue, 0.55 * core * uIntensity);
    paper = mix(paper, slick, halo * 0.45 * uIntensity);
    col = mix(col, paper, 1.0);
    col = mix(col, uInk, halo * 0.06 * uIntensity);
  }
  if (uPointerActive > 0.5) {
    vec2 pp = (uPointer * uResolution - 0.5 * uResolution) / uResolution.y;
    float dd = length(p - pp); float halo2 = exp(-dd * dd * 4.5);
    col += accentRamp(fract(0.65 + uTime * 0.08)) * halo2 * 0.18 * (uTheme < 0.5 ? 1.0 : 0.55);
  }
  float vig = smoothstep(1.5, 0.15, length(p));
  col = mix(uBg, col, 0.40 + 0.60 * vig);
  return col;
}
`,

  oilfield: `
vec3 baseField(vec2 p) {
  float t = uTime * 0.05;
  vec2 q = vec2(fbm(vec3(p * 2.3 + vec2(0.0, t), 0.0)), fbm(vec3(p * 2.3 + vec2(5.2, -t), 0.0)));
  float n = fbm(vec3(p * 3.1 + 1.8 * q + vec2(t * 0.6, -t * 0.4), 0.0));
  n = 0.5 + 0.5 * snoise(vec3(p * 1.4 + n * 1.6 + t, 0.0));
  vec3 col = accentRamp(clamp(n, 0.0, 1.0));
  col = mix(uBg, col, 0.85);
  return col;
}
float lumv(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  vec2 px = vec2(1.0 / uResolution.y) * 2.4;
  if (uPointerActive > 0.5) { float d = distance(uv, uPointer); px *= 1.0 + 0.9 * exp(-d * d * 22.0); }
  vec3 mean0=vec3(0.0),mean1=vec3(0.0),mean2=vec3(0.0),mean3=vec3(0.0);
  float sq0=0.0,sq1=0.0,sq2=0.0,sq3=0.0; float cnt0=0.0,cnt1=0.0,cnt2=0.0,cnt3=0.0;
  for (int j=-3;j<=3;j++){ for (int i=-3;i<=3;i++){
    vec2 off=vec2(float(i),float(j))*px; vec3 c=baseField(uv+off); float l=lumv(c);
    bool lf=(i<=0),rt=(i>=0),dn=(j<=0),up=(j>=0);
    if(lf&&dn){mean0+=c;sq0+=l*l;cnt0+=1.0;}
    if(rt&&dn){mean1+=c;sq1+=l*l;cnt1+=1.0;}
    if(lf&&up){mean2+=c;sq2+=l*l;cnt2+=1.0;}
    if(rt&&up){mean3+=c;sq3+=l*l;cnt3+=1.0;}
  }}
  vec3 outCol=vec3(0.0); float best=1e9; vec3 m; float v;
  m=mean0/max(cnt0,1.0); v=sq0/max(cnt0,1.0)-lumv(m)*lumv(m); if(v<best){best=v;outCol=m;}
  m=mean1/max(cnt1,1.0); v=sq1/max(cnt1,1.0)-lumv(m)*lumv(m); if(v<best){best=v;outCol=m;}
  m=mean2/max(cnt2,1.0); v=sq2/max(cnt2,1.0)-lumv(m)*lumv(m); if(v<best){best=v;outCol=m;}
  m=mean3/max(cnt3,1.0); v=sq3/max(cnt3,1.0)-lumv(m)*lumv(m); if(v<best){best=v;outCol=m;}
  float sheen=pow(clamp(lumv(outCol)-0.55,0.0,1.0),2.0); outCol += sheen*0.14*uAccent2;
  outCol = mix(outCol, uInk, 0.06*uTheme);
  outCol *= uIntensity;
  float vig=smoothstep(0.98,0.35,length(uv-0.5)); outCol *= mix(0.8,1.0,vig);
  return clamp(outCol,0.0,1.0);
}
`,

  suminagashi: `
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float asp = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(asp, 1.0);
  vec2 ptr = (uPointer - 0.5) * vec2(asp, 1.0);
  float t = uTime * 0.18;
  float z = 0.34; float u = 0.62; vec2 q = p;
  { float xL = 0.42 * sin(t * 1.3); float d = abs(q.x - xL); q.y -= z * pow(u, d); }
  { float yL = 0.40 * sin(t * 0.9 + 1.7); float d = abs(q.y - yL); q.x -= (z * 0.85) * pow(u, d); }
  { vec2 C = vec2(0.18 * sin(t * 0.7), 0.16 * cos(t * 0.6)); vec2 rp = q - C; float h = length(rp); float r0 = 0.10; float l = (z * 1.4) * pow(u, abs(h - r0)); float a = -(l / max(h, 1e-3)); float ca = cos(a), sa = sin(a); q = C + vec2(ca * rp.x - sa * rp.y, sa * rp.x + ca * rp.y); }
  { float d = abs(q.x - ptr.x); q.y -= (z * uPointerActive) * pow(u, d); }
  const int NDROP = 5; float tone = -1.0; float vein = 0.0;
  for (int i = NDROP - 1; i >= 0; i--) {
    float fi = float(i);
    vec2 C = 0.46 * vec2(sin(fi * 2.39 + t * 0.5), cos(fi * 1.71 - t * 0.4));
    float r = 0.16 + 0.05 * sin(fi * 1.7 + t);
    vec2 d2 = q - C; float dd = length(d2);
    if (tone < 0.0 && dd < r) { tone = fract(fi * 0.27 + 0.12); vein = dd / r; }
    else { float s = sqrt(max(1.0 - (r * r) / max(dd * dd, 1e-6), 0.0)); q = C + d2 * s; }
  }
  if (tone < 0.0) { float rr = length(q); tone = fract(rr * 1.6 - t * 0.05); vein = rr; }
  float rings = 0.5 + 0.5 * sin(40.0 * vein + tone * 6.2831 - t);
  float grain = fbm(vec3(q * 3.0 + tone, 0.0)) * 0.12;
  vec3 marble = accentRamp(fract(tone + 0.15 * rings + grain));
  vec3 darkInk = mix(uBg, marble, 0.82);
  darkInk = mix(darkInk, uInk, smoothstep(0.85, 0.98, rings) * 0.35);
  darkInk *= uIntensity;
  vec3 paperInk = mix(uBg, mix(marble, uInk, 0.5), 0.5 + 0.5 * uIntensity);
  paperInk = mix(paperInk, uInk, smoothstep(0.82, 0.99, rings) * 0.22);
  vec3 col = (uTheme < 0.5) ? darkInk : paperInk;
  float vig = smoothstep(1.15, 0.25, length(p));
  col *= mix(0.6, 1.0, vig);
  return col;
}
`,
};

/** Ordered, display-ready kernel specs. The first entry is the default. */
export const KERNEL_SPECS: KernelSpec[] = [
  {
    id: "liquidGlass",
    label: "Liquid Glass",
    body: KERNEL_BODIES.liquidGlass,
    // Coral / ember — the BurnBar brand, matched to --accent #f45b69.
    palette: {
      base: "#0D0506",
      accents: ["#3E1018", "#A8263A", "#FF5A5E", "#FFB07A"],
      ink: "#E9EEF5",
    },
  },
  {
    id: "aurora",
    label: "Aurora",
    palette: {
      base: "#050D0E",
      accents: ["#0D3A40", "#1F9AA0", "#37E0C8", "#7AE0D0"],
      ink: "#E9EEF5",
    },
    body: KERNEL_BODIES.aurora,
  },
  {
    id: "plasmaOrbs",
    label: "Plasma Orbs",
    palette: {
      base: "#0A0612",
      accents: ["#2A1452", "#7A2CC8", "#C04CF0", "#FF6AD0"],
      ink: "#E9EEF5",
    },
    body: KERNEL_BODIES.plasmaOrbs,
  },
  {
    id: "oilfield",
    label: "Oilfield",
    palette: {
      base: "#05060A",
      accents: ["#0E2552", "#2E63C0", "#5B9BF5", "#8A7FF0"],
      ink: "#E9EEF5",
    },
    body: KERNEL_BODIES.oilfield,
  },
  {
    id: "suminagashi",
    label: "Suminagashi",
    palette: {
      base: "#04070F",
      accents: ["#173E63", "#34C6DE", "#6E84F0", "#E06AA8"],
      ink: "#E9EEF5",
    },
    body: KERNEL_BODIES.suminagashi,
  },
];

export const DEFAULT_KERNEL_ID: KernelId = "liquidGlass";

const SPEC_BY_ID: Record<KernelId, KernelSpec> = KERNEL_SPECS.reduce(
  (acc, spec) => {
    acc[spec.id] = spec;
    return acc;
  },
  {} as Record<KernelId, KernelSpec>,
);

export function getKernelSpec(id: KernelId): KernelSpec {
  return SPEC_BY_ID[id] ?? SPEC_BY_ID[DEFAULT_KERNEL_ID];
}

export function isKernelId(value: unknown): value is KernelId {
  return typeof value === "string" && value in SPEC_BY_ID;
}
