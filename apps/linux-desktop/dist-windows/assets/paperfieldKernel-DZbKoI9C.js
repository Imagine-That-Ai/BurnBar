import{c as e}from"./createShaderKernel-DNT32VLs.js";import"./index-PmASUbTN.js";const t=`
const float FIBER_FREQ = 1.7;
const float LAID_FREQ  = 0.22;
const float LAID_AMP   = 0.12;
const float DECKLE_W   = 1.55;

float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}

// 3-octave fbm (injected snoise + accumulation) — the fiber body.
float paperFbm(vec3 q){
  float s = snoise(q) * 0.5;
  s += snoise(q * 2.05) * 0.25;
  s += snoise(q * 4.12) * 0.125;
  return s;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5*uResolution)/uResolution.y;

  float sN = uScroll.y > 0.0 ? uScroll.x/uScroll.y : 0.0;
  float breath = 0.5 + 0.5*sin(uTime*0.18);
  float drift = sN*1.4;
  vec3 flow = vec3(uTime*0.022 + drift, uTime*0.013, 0.0);

  // Domain warping: a low-frequency warp field gives the fibers their organic,
  // hand-pulled non-uniformity. Two taps of fbm feed the sample position.
  vec3 q = vec3(p*FIBER_FREQ, 0.0) + flow;
  vec2 warpOff = vec2(
    paperFbm(q + vec3(13.1, 0.0, 0.0)),
    paperFbm(q + vec3(0.0, 17.7, 0.0))
  ) * 0.4;
  float fiber = paperFbm(vec3(q.xy + warpOff, q.z));  // ~[-0.875, 0.875]

  // Laid lines: the wire-screen imprint. A slow horizontal sinusoid, phase-
  // warped by the fiber field so the lines breathe with the sheet.
  float laidPhase = uTime*0.06
    + (uPointerActive > 0.5 ? (uPointer.x - 0.5) * 3.0 : 0.0);
  float laid = sin((p.y*2.0 + warpOff.y*0.6) * LAID_FREQ * 60.0 + laidPhase);
  laid = smoothstep(0.7, 1.0, laid*LAID_AMP + (1.0 - LAID_AMP));

  // Deckle edge: a soft vignette whose boundary is itself warped by the fiber
  // field (a hand-made deckle is irregular, not a clean ellipse).
  float deckleR = length(p * vec2(0.75, 1.0))
    + 0.08 * paperFbm(vec3(p*3.0, uTime*0.03));
  float deckle = smoothstep(DECKLE_W, DECKLE_W*0.55, deckleR);

  // Warm window-light bloom: an off-canvas top-left light catching the sheet.
  vec2 lp = p - vec2(-0.9, 0.85);
  float lit = exp(-dot(lp, lp) * 1.6) * (0.6 + 0.4*breath);

  // Fiber → base tint. Kozo is warm cream; fibers read as subtle tan variation.
  float fib01 = clamp(fiber*0.5 + 0.5, 0.0, 1.0);

  vec3 col;
  if (uTheme < 0.5){
    // DARK: deep warm ink-wash washi under moonlight.
    vec3 kozo = mix(vec3(0.10, 0.09, 0.08), vec3(0.22, 0.19, 0.15), fib01);
    vec3 tint = accentRamp(0.4 + 0.08*fib01);
    col = mix(uBg, kozo, 0.55*uIntensity);
    col += tint*laid*0.06*uIntensity;          // faint laid sheen
    col += accentRamp(0.6)*lit*0.20*uIntensity; // window bloom
    col += vec3(0.8,0.78,0.74)*(ign(fragCoord)-0.5)*0.012; // paper grain
    col *= deckle*0.6 + 0.4;                     // deckle edges fall to bg
    col = col/(col + vec3(0.55));
    col *= 1.10;
  } else {
    // LIGHT: bright cream kozo in window light.
    vec3 kozo = mix(vec3(0.92, 0.89, 0.82), vec3(1.0, 0.98, 0.92), fib01);
    vec3 tint = accentRamp(0.3 + 0.06*fib01);
    col = mix(uBg, kozo, 0.7*uIntensity);
    col = mix(col, tint, 0.04*laid*uIntensity); // faint laid tint
    col = mix(col, tint*1.1, 0.18*lit*uIntensity); // window warmth
    col += vec3(0.5,0.46,0.4)*(ign(fragCoord)-0.5)*0.008; // paper grain
    col *= deckle*0.8 + 0.2;
    col = mix(col, uInk, smoothstep(0.4, 1.4, deckleR)*0.03*uIntensity); // deckle ink-edge
  }

  // Pointer halo: a soft warm disc where the cursor rests on the sheet.
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer*uResolution - 0.5*uResolution)/uResolution.y;
    float dd = length(p - pp);
    col += accentRamp(0.45)*exp(-dd*dd*5.0)*0.10*breath;
  }

  // Final vignette to protect glass-type legibility.
  float vig = smoothstep(1.7, 0.3, length(p));
  col = mix(uBg, col, 0.45 + 0.55*vig);
  return col;
}
`;function l(){return e({id:"origami",label:"Origami",body:t,controls:["scroll"]})}export{l as createPaperfieldKernel};
