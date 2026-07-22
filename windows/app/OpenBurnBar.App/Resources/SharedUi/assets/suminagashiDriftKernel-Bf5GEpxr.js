import{c as e}from"./createShaderKernel-DZdzJunW.js";import"./index-CeVJulmk.js";const t=`
// ── Suminagashi Drift — closed-form ink-on-water marbling ─────────────────
vec3 renderKernel(vec2 uv, vec2 fragCoord) {
  float asp = uResolution.x / max(uResolution.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(asp, 1.0);
  vec2 ptr = (uPointer - 0.5) * vec2(asp, 1.0);
  float t = uTime * 0.18;

  // Closed-form rake strengths (Lu/Jaffer/Witkin): z = stroke amplitude,
  // u = tine falloff base in (0,1) so pow(u, dist) decays away from the line.
  float z = 0.34;
  float u = 0.62;
  vec2 q = p;

  // ── Crossed comb strokes (horizontal + vertical tine lines), drifting ──
  { float xL = 0.42 * sin(t * 1.3); float d = abs(q.x - xL); q.y -= z * pow(u, d); }
  { float yL = 0.40 * sin(t * 0.9 + 1.7); float d = abs(q.y - yL); q.x -= (z * 0.85) * pow(u, d); }

  // ── Slow vortex (rotational rake about a drifting center) ──
  {
    vec2 C = vec2(0.18 * sin(t * 0.7), 0.16 * cos(t * 0.6));
    vec2 rp = q - C;
    float h = length(rp);
    float r0 = 0.10;
    float l = (z * 1.4) * pow(u, abs(h - r0));
    float a = -(l / max(h, 1e-3));
    float ca = cos(a), sa = sin(a);
    q = C + vec2(ca * rp.x - sa * rp.y, sa * rp.x + ca * rp.y);
  }

  // ── Pointer rake — a live comb stroke under the cursor ──
  { float d = abs(q.x - ptr.x); q.y -= (z * uPointerActive) * pow(u, d); }

  // ── Concentric ink drops, applied back-to-front (inverse drop map) ──
  const int NDROP = 5;
  float tone = -1.0;
  float vein = 0.0;
  for (int i = NDROP - 1; i >= 0; i--) {
    float fi = float(i);
    vec2 C = 0.46 * vec2(sin(fi * 2.39 + t * 0.5), cos(fi * 1.71 - t * 0.4));
    float r = 0.16 + 0.05 * sin(fi * 1.7 + t);
    vec2 d2 = q - C;
    float dd = length(d2);
    if (tone < 0.0 && dd < r) {
      tone = fract(fi * 0.27 + 0.12);   // band index for this drop
      vein = dd / r;                    // normalized radius within the drop
    } else {
      float s = sqrt(max(1.0 - (r * r) / max(dd * dd, 1e-6), 0.0));
      q = C + d2 * s;                   // pull back through the drop
    }
  }
  if (tone < 0.0) {                      // outside every drop → background band
    float rr = length(q);
    tone = fract(rr * 1.6 - t * 0.05);
    vein = rr;
  }

  // ── Marble veins + paper grain ──
  float rings = 0.5 + 0.5 * sin(40.0 * vein + tone * 6.2831 - t);
  float grain = fbm(vec3(q * 3.0 + tone, 0.0)) * 0.12;
  vec3 marble = accentRamp(fract(tone + 0.15 * rings + grain));

  // ── Theme composite ──
  // DARK: luminous ink marble floated over deep water; vein crests pick out uInk.
  vec3 darkInk = mix(uBg, marble, 0.82);
  darkInk = mix(darkInk, uInk, smoothstep(0.85, 0.98, rings) * 0.35);
  darkInk *= uIntensity;
  // LIGHT: ink deposited on warm paper; stains toward uInk so it never blows out.
  vec3 paperInk = mix(uBg, mix(marble, uInk, 0.5), 0.5 + 0.5 * uIntensity);
  paperInk = mix(paperInk, uInk, smoothstep(0.82, 0.99, rings) * 0.22);

  vec3 col = (uTheme < 0.5) ? darkInk : paperInk;

  // ── Vignette (keeps foreground text legible) ──
  float vig = smoothstep(1.15, 0.25, length(p));
  col *= mix(0.6, 1.0, vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;function a(){return e({id:"suminagashi-drift",label:"Suminagashi Drift",body:t})}export{a as createSuminagashiDriftKernel};
