/**
 * Storm Cell kernel — "Tempest": a charged slate sky behind a billowing
 * mesocyclone. A domain-warped fbm field models the rolling cloud mass; a
 * second high-frequency field drives intermittent sheet-lightning flashes
 * that illuminate the whole cell from within. Fork lightning is added in
 * JS-space by the Tempest glyph styles (via fractalBolt) — this backdrop
 * supplies the storm atmosphere behind them.
 *
 * Dark: deep slate cell with additive electric-blue in-scatter and a filmic
 * knee. Light: the same cell deposited as a soft cool wash, never muddy.
 *
 * Pure fragment shader via {@link createShaderKernel}; no per-frame JS.
 */

import { createShaderKernel } from "../gl/createShaderKernel";
import type { Kernel } from "../types";

const BODY = /* glsl */ `
const float CELL_FREQ = 0.85;
const float CELL_COVERAGE = 0.46;
const float DENSITY_GAIN = 1.6;
const float FLASH_RATE = 0.9;     // Hz of sheet-lightning attempts
const float FLASH_DECAY = 3.2;    // exponential decay of a flash

float ign(vec2 c){
  return fract(52.9829189 * fract(dot(c, vec2(0.06711056, 0.00583715))));
}

// 3-octave fbm (injected snoise + accumulation).
float stormFbm(vec3 q){
  float s = snoise(q)*0.5;
  s += snoise(q*2.03)*0.25;
  s += snoise(q*4.07)*0.125;
  return s; // ~[-0.875, 0.875]
}

vec3 renderKernel(vec2 uv, vec2 fragCoord){
  vec2 p = (fragCoord - 0.5*uResolution)/uResolution.y;

  float sN = uScroll.y > 0.0 ? uScroll.x/uScroll.y : 0.0;
  float breath = mix(0.88, 1.12,
    0.5 + 0.5*(0.62*sin(uTime*0.2144) + 0.38*sin(uTime*0.0913 + 1.3)));
  float drift = sN*2.0;
  vec3 flow = vec3(uTime*0.028 + drift, uTime*0.017, uTime*0.019);

  // Rolling cell: fbm gated above a coverage threshold.
  vec3 q = vec3(p*1.4, 0.0) + flow;
  float raw = stormFbm(q);
  float cell = max(0.0, raw + 0.5 - CELL_COVERAGE) * DENSITY_GAIN * breath;

  // Sheet lightning: a strobe that lights the whole cell from within.
  // Drive it off uTime so every pixel agrees; gate by a per-strobe seed.
  float strobePhase = uTime*FLASH_RATE;
  float strobeIdx = floor(strobePhase);
  float strobeFrac = strobePhase - strobeIdx;
  float strobeSeed = fract(sin(strobeIdx*12.9898)*43758.5453);
  float strobeAlive = step(0.62, strobeSeed);   // ~38% of attempts fire
  float flash = strobeAlive * exp(-strobeFrac*FLASH_DECAY) * cell;

  vec3 tint = accentRamp(0.5 + 0.05*sin(uTime*0.1));
  vec3 hot  = accentRamp(0.72);

  vec3 col;
  if (uTheme < 0.5){
    // DARK: charged slate + electric-blue in-scatter, filmic knee.
    col  = uBg;
    col += tint*cell*0.55*uIntensity;
    col += hot*flash*1.6*uIntensity;
    col += vec3(0.8,0.85,1.0)*(ign(fragCoord)-0.5)*0.012*(1.0-cell);
    col = col/(col+vec3(0.6));
    col *= 1.16;
  } else {
    // LIGHT: cool wash, flash reads as a pale brightening.
    float v = pow(clamp(cell*0.7, 0.0, 1.0), 0.85);
    vec3 pearl = mix(uBg, tint, 0.6);
    col = mix(uBg, pearl, v*0.4*uIntensity);
    col = mix(col, hot, clamp(flash*0.6, 0.0, 1.0)*0.25*uIntensity);
    col = mix(col, uInk, smoothstep(0.1, 0.6, v)*0.03*uIntensity);
  }

  // Pointer halo: a charged glow where the cursor stirs the cell.
  if (uPointerActive > 0.5){
    vec2 pp = (uPointer*uResolution - 0.5*uResolution)/uResolution.y;
    float dd = length(p - pp);
    col += hot*exp(-dd*dd*4.0)*0.16*breath*(uTheme < 0.5 ? 1.0 : 0.5);
  }

  float vig = smoothstep(1.6, 0.2, length(p));
  col = mix(uBg, col, 0.4 + 0.6*vig);
  return col;
}
`;

export function createStormCellKernel(): Kernel {
  return createShaderKernel({
    id: "storm-signal",
    label: "Tempest",
    body: BODY,
    controls: ["scroll"],
  });
}
