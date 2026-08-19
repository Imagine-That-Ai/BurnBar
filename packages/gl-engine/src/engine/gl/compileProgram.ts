/**
 * compileProgram — leaf GL helper + the shared GLSL prelude constants.
 *
 * This module is intentionally a **leaf** (no backdrop imports) so the
 * multi-pass infra (`uniformCache`, `createSimPass`) can import the constants
 * `PREAMBLE` / `UNIFORM_NAMES` and the compile/link helper *without* forming an
 * import cycle with `createShaderKernel` (which re-exports them for back-compat).
 *
 * `compileProgram` compiles a vertex + fragment pair, links a program, deletes
 * the shaders, and returns `null` on any failure (with a console error). The
 * fullscreen-triangle vertex shader is attribute-less (`gl_VertexID`-derived).
 */

const VERT = /* glsl */ `#version 300 es
void main(){
  // Fullscreen triangle from gl_VertexID — no attribute buffers needed.
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

/**
 * The standard fragment-shader preamble: version, precision, the output, and the
 * "standard uniform set" every kernel receives (resolution/time/pointer/palette).
 * Multi-pass sim/seed preambles are built by concatenating this with the control
 * block (`uniformCache.CONTROL_BLOCK`) and the sim-only samplers.
 */
export const PREAMBLE = /* glsl */ `#version 300 es
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
`;

/**
 * The display-pass MAIN: turns `renderKernel(uv, fragCoord)` into the fragment
 * output, with the shared ordered dither + clamp. Sim/seed passes use their own
 * MAINs (they don't call `renderKernel`), so this stays display-only.
 */
export const MAIN = /* glsl */ `
void main(){
  vec2 fragCoord = gl_FragCoord.xy;
  vec2 uv = fragCoord / uResolution;
  vec3 col = renderKernel(uv, fragCoord);
  col += dither(fragCoord);
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}`;

/** The attribute-less fullscreen-triangle vertex shader. */
export const FULLSCREEN_VERT = VERT;

/** The standard uniform set every kernel pass receives (resolution/time/...). */
export const UNIFORM_NAMES = [
  "uResolution",
  "uTime",
  "uPointer",
  "uPointerActive",
  "uBg",
  "uAccent0",
  "uAccent1",
  "uAccent2",
  "uAccent3",
  "uInk",
  "uIntensity",
  "uTheme",
] as const;

/** A standard-uniform location map (subset keyed by `UNIFORM_NAMES`). */
export type UniformMap = Record<string, WebGLUniformLocation | null>;

/**
 * Compile + link a vertex/fragment pair into a program. Deletes the shaders
 * after linking (success or failure). Returns `null` on any compile/link
 * failure (logs an error with `label` so a missing uniform doesn't look silent).
 */
export function compileProgram(
  gl: WebGL2RenderingContext,
  fragSrc: string,
  label: string
): WebGLProgram | null {
  const vs = compile(gl, gl.VERTEX_SHADER, VERT, `${label}:vert`);
  const fs = compile(gl, gl.FRAGMENT_SHADER, fragSrc, `${label}:frag`);
  if (!vs || !fs) {
    if (vs) gl.deleteShader(vs);
    if (fs) gl.deleteShader(fs);
    return null;
  }
  const prog = gl.createProgram();
  if (!prog) {
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    return null;
  }
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.linkProgram(prog);
  gl.deleteShader(vs);
  gl.deleteShader(fs);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    console.error(`[backdrop] ${label} link failed:\n${gl.getProgramInfoLog(prog)}`);
    gl.deleteProgram(prog);
    return null;
  }
  return prog;
}

function compile(
  gl: WebGL2RenderingContext,
  type: number,
  src: string,
  label: string
): WebGLShader | null {
  // A lost context no-ops every GL call and reports COMPILE_STATUS=false with a
  // null info log — that is an engine lifecycle condition (handled by the
  // contextlost path), not a shader bug, so it must not log as one.
  if (gl.isContextLost()) return null;
  const sh = gl.createShader(type);
  if (!sh) return null;
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    if (gl.isContextLost()) {
      gl.deleteShader(sh);
      return null;
    }
    const log = gl.getShaderInfoLog(sh) ?? "unknown";
    console.error(`[backdrop] ${label} shader compile failed:\n${log}`);
    gl.deleteShader(sh);
    return null;
  }
  return sh;
}
