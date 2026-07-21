import{c as e}from"./createShaderKernel-DZdzJunW.js";import"./index-CeVJulmk.js";const t=`
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
  for(int oy = -1; oy <= 1; oy++){
    for(int ox = -1; ox <= 1; ox++){
      vec2 nid = id + vec2(float(ox), float(oy));
      vec2 cellPx = (nid + 0.5) * cell;
      // Sample the density UPSTREAM so dots inherit the field that flowed in.
      vec2 src = cellPx - dir * (STREAM_PX * (0.6 + 0.4 * speed));
      float dens = clamp(fbm(vec3(src * DENS_SCALE, uTime * 0.12)) * 0.6 + 0.5, 0.0, 1.0);
      // Per-cell life clock: faster where the wind is faster.
      float life = fract(hash21(nid) + uTime * (0.10 + 0.16 * speed));
      float env = sin(life * 3.14159265);          // birth→peak→death opacity
      vec2 jit = (vec2(hash21(nid + 3.1), hash21(nid + 7.7)) - 0.5) * 0.42;
      vec2 ctr = vec2(0.5) + jit + dir * (life - 0.5);  // streams across the cell
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
    // DARK: hot dots lifted toward light over deep ink.
    vec3 hot = mix(dotTint, vec3(1.0), 0.25 * litDens);
    col = mix(uBg, hot, ink * uIntensity);
  } else {
    // LIGHT: ink-deposit dots on warm paper (never blows out).
    vec3 dark = mix(dotTint, uInk, 0.55);
    col = mix(uBg, dark, ink * (0.85 * uIntensity));
  }

  // ── Faint advected haze in the gaps between dots ──
  float haze = fbm(vec3(fragCoord * DENS_SCALE * 0.5 - dir * 2.0, uTime * 0.05));
  col = mix(col, accentRamp(0.1 + 0.3 * haze), 0.04 * uIntensity * (1.0 - ink));

  // ── Vignette (keeps foreground text legible) ──
  vec2 pc = (fragCoord - 0.5 * uResolution) / uResolution.y;
  float vig = smoothstep(1.6, 0.2, length(pc));
  col = mix(uBg, col, 0.45 + 0.55 * vig);

  return col;   // MAIN() appends dither() + clamps to [0,1]
}
`;function l(){return e({id:"kinetic-stipple",label:"Kinetic Stipple",body:t})}export{l as createKineticStippleKernel};
