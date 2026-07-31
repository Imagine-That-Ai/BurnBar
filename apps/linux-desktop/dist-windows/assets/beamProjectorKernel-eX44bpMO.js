import{c as e}from"./createShaderKernel-DNT32VLs.js";import"./index-PmASUbTN.js";const t=`
// Projector pinned dead-still off-canvas bottom-center. Beam aim eases toward
// the pointer (never snaps). Cone half-angle, shaft reach, fog density.
const float BEAM_HALF_ANGLE = 0.11;
const float SHAFT_LEN       = 2.8;
const float FOG_FREQ        = 1.5;
const float FOG_COVERAGE    = 0.44;
const float FOG_GAIN        = 1.4;
const float N_RAYS          = 5.0;     // a small steady set of god-rays

// Jimenez interleaved gradient noise — static spatial jitter (no time term).
float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}
// cheap 2D value noise
float vnoise(vec2 p){
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f*f*(3.0-2.0*f);
  float a = ign(i);
  float b = ign(i + vec2(1.0,0.0));
  float c = ign(i + vec2(0.0,1.0));
  float d = ign(i + vec2(1.0,1.0));
  return mix(mix(a,b,f.x), mix(c,d,f.x), f.y);
}
// 2-octave fbm for the fog field
float fbm2(vec2 q){
  float s = vnoise(q)*0.5;
  s += vnoise(q*2.07 + 11.0)*0.25;
  return s;
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5*uResolution)/uResolution.y;

  float sN = uScroll.y > 0.0 ? uScroll.x/uScroll.y : 0.0;
  // one calm slow breath (very small amplitude) — alive, never busy.
  float breath = 0.93 + 0.07*sin(uTime*0.21);

  // Projector origin: DEAD STILL, off-canvas bottom-center.
  vec2 proj = vec2(0.0, -1.15);

  // Beam AIM. Pointer ACTIVE → beam EASES toward the cursor (heavy ease so it
  // drifts, never snaps; pointer sits in the lower-mid sky so the beam rises at
  // a calm diagonal). Pointer ABSENT → a single near-static beam with the
  // faintest sway, not a sweep.
  vec2 aimN;
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer*uResolution - 0.5*uResolution)/uResolution.y;
    // compress + bias the target so the beam stays a graceful near-vertical
    // diagonal (never horizontal, never whipping to the edges).
    vec2 target = vec2(pp.x*0.5, max(pp.y, -0.1)*0.6 + 0.55);
    aimN = normalize(target - proj);
  } else {
    // the faintest sway — almost still, just breathing.
    float sway = sin(uTime*0.08)*0.08;
    aimN = normalize(vec2(sway, 1.0));
  }

  // ── cone geometry: perp/along distance to the beam axis ──────────────────
  vec2 toP = p - proj;
  float along = dot(toP, aimN);
  float perp  = abs(toP.x*aimN.y - toP.y*aimN.x);
  // cone envelope: bright on axis, feathered at the half-angle, dead past it.
  float cone = smoothstep(BEAM_HALF_ANGLE, 0.0, perp/max(along, 0.001));
  // reach: beam fades with distance + only the forward half-cone.
  float reach = smoothstep(SHAFT_LEN, 0.0, along) * step(0.0, along);
  float beam = cone*reach;
  beam *= 0.8 + 0.2*breath;

  // ── fog field: fbm density that BRIGHTENS where the beam passes ───────────
  vec2 fuv = p*FOG_FREQ + vec2(uTime*0.018 + sN*1.2, uTime*0.010);
  float fog = max(0.0, fbm2(fuv) + 0.5 - FOG_COVERAGE) * FOG_GAIN * breath;
  // in-scatter: fog lit by the beam — the visible volumetric body of the cone.
  float scatter = fog * beam;

  // ── steady crepuscular god-rays: a small set, gently breathing in unison ─
  float rays = 0.0;
  for (float i = 0.0; i < N_RAYS; i += 1.0){
    float u = (i + 0.5)/N_RAYS - 0.5;            // -0.5..0.5 across the cone
    float angOff = u*BEAM_HALF_ANGLE*1.6;
    vec2 rayDir = vec2(aimN.x*cos(angOff) - aimN.y*sin(angOff),
                       aimN.x*sin(angOff) + aimN.y*cos(angOff));
    float rAlong = dot(toP, rayDir);
    float rPerp  = abs(toP.x*rayDir.y - toP.y*rayDir.x);
    float rCone  = smoothstep(0.016, 0.0, rPerp) * step(0.0, rAlong)
                   * smoothstep(SHAFT_LEN, 0.0, rAlong);
    rays += rCone;
  }
  rays *= breath * (0.85 + 0.15*sin(uTime*0.35));   // one shared slow pulse

  // ── lens flare at the projector origin ────────────────────────────────────
  float bloom = exp(-dot(toP,toP)*9.0) * breath;

  // tint: a steady cold sky-beam blue (held still — color must not wobble).
  vec3 tint = accentRamp(0.62);
  vec3 hot  = accentRamp(0.74);

  vec3 col;
  if (uTheme < 0.5){
    // DARK: additive in-scatter over deep ink, filmic knee blooms cores to white.
    col  = uBg;
    col += tint*beam*0.5*uIntensity;             // cone body
    col += tint*scatter*1.4*uIntensity;          // lit fog (the visible volume)
    col += hot*rays*0.16*uIntensity;             // steady god-rays
    col += vec3(0.8,0.86,1.0)*bloom*0.6*uIntensity; // source flare
    col += vec3(0.85,0.9,1.0)*(ign(fragCoord)-0.5)*0.012*(1.0-beam); // grain floor
    col = col/(col+vec3(0.6));
    col *= 1.14;
  } else {
    // LIGHT: pale luminous column deposited softly (never toward white).
    float v = pow(clamp(beam*0.7 + scatter*0.5, 0.0, 1.0), 0.85);
    vec3 pearl = mix(uBg, tint, 0.7);
    col = mix(uBg, pearl, v*0.38*uIntensity);
    col = mix(col, hot, clamp(rays*0.5, 0.0, 1.0)*0.10*uIntensity);
    col = mix(col, uInk, smoothstep(0.1, 0.6, v)*0.03*uIntensity);
    col = mix(col, tint, bloom*0.14*uIntensity); // soft flare disc
  }

  // Vignette to protect glass-type legibility.
  float vig = smoothstep(1.7, 0.3, length(p));
  col = mix(uBg, col, 0.4 + 0.6*vig);
  return col;
}
`;function i(){return e({id:"bat-signal",label:"Beacon",body:t,controls:["scroll"]})}export{i as createBeamProjectorKernel};
