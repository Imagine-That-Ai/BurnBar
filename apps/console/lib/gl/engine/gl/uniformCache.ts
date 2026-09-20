/**
 * uniformCache — the per-program cached uniform-location maps + the D2 control
 * block declarations.
 *
 * **D2** declares ONE control-uniform block (scroll / impulses / obstacles /
 * uHasSim) consumed by sim + display passes; no consuming kernel re-invents it.
 * The block is concatenated into a program's preamble only for the groups a
 * kernel opts into (via `ShaderKernelSpec.controls`), so single-pass kernels
 * (aurora/mesh) emit byte-identical shader source.
 *
 * **D3** caches every uniform location ONCE per program (build/restore); the
 * hot path (`frame`/`step`/`reseed`) calls only `gl.uniform*` with cached
 * handles — zero `getUniformLocation` in steady state. Absent uniforms resolve
 * to `null` and are skipped on upload (cheap, branch-predictable).
 */

import { UNIFORM_NAMES } from "./compileProgram";

/** Per-control-group GLSL declarations, so the factory concatenates only what a
 *  kernel opts into. `uHasSim` ships with any sim (it's the never-black signal). */
export const CONTROL_DECL = {
  hasSim: "uniform float uHasSim;\n",
  scroll: "uniform vec2  uScroll;\nuniform float uScrollVel;\n",
  impulses: "uniform vec4  uImpulses[8];\nuniform int   uImpulseCount;\n",
  obstacles: "uniform vec4  uObstacleRects[24];\nuniform int   uObstacleCount;\n",
  // The Glyph Field contract (§2.2): the active mark as a signed distance
  // field. A world opts in via `controls: ["glyph"]` and samples it to be
  // *shaped by* the mark. uGlyphField texel = .r signed dist remapped 0..1
  // (decode `*2-1`), .g coverage 0..1. The texture rows run y-DOWN (canvas
  // raster), so sample at `vec2(uv.x, 1.0 - uv.y)` for y-up uv. uGlyphRect is
  // y-up: xy center, zw half-extent.
  glyph:
    "uniform sampler2D uGlyphField;\nuniform float uGlyphActive;\nuniform vec4  uGlyphRect;\nuniform float uGlyphPhase;\n",
} as const;

/** The full control block — the SIM-STEP preamble always sees the whole set
 *  (a step shader may read any of it; unused ⇒ null loc, skipped on upload). */
export const CONTROL_BLOCK =
  CONTROL_DECL.hasSim +
  CONTROL_DECL.scroll +
  CONTROL_DECL.impulses +
  CONTROL_DECL.obstacles;

/** A control group a kernel opts into via `ShaderKernelSpec.controls`. */
export type ControlGroup = "scroll" | "impulses" | "obstacles" | "glyph";

/** Superset of every uniform any pass may use, queried once per program. */
export const ALL_UNIFORM_NAMES = [
  ...UNIFORM_NAMES,
  "uHasSim",
  "uScroll",
  "uScrollVel",
  "uImpulses",
  "uImpulseCount",
  "uObstacleRects",
  "uObstacleCount",
  "uPrev",
  "uSim",
  "uSimResolution",
  "uGlyphField",
  "uGlyphActive",
  "uGlyphRect",
  "uGlyphPhase",
] as const;

export type AllUniformName = (typeof ALL_UNIFORM_NAMES)[number];

/** Cached location map keyed by `ALL_UNIFORM_NAMES`. Absent ⇒ `null`.
 *  Declared as a concrete interface (not a Record) so property access under
 *  `noUncheckedIndexedAccess` yields `WebGLUniformLocation | null`, never
 *  `undefined` — the GL uniform setters reject `undefined`. */
export interface FullUniformMap {
  uResolution: WebGLUniformLocation | null;
  uTime: WebGLUniformLocation | null;
  uPointer: WebGLUniformLocation | null;
  uPointerActive: WebGLUniformLocation | null;
  uBg: WebGLUniformLocation | null;
  uAccent0: WebGLUniformLocation | null;
  uAccent1: WebGLUniformLocation | null;
  uAccent2: WebGLUniformLocation | null;
  uAccent3: WebGLUniformLocation | null;
  uInk: WebGLUniformLocation | null;
  uIntensity: WebGLUniformLocation | null;
  uTheme: WebGLUniformLocation | null;
  uHasSim: WebGLUniformLocation | null;
  uScroll: WebGLUniformLocation | null;
  uScrollVel: WebGLUniformLocation | null;
  uImpulses: WebGLUniformLocation | null;
  uImpulseCount: WebGLUniformLocation | null;
  uObstacleRects: WebGLUniformLocation | null;
  uObstacleCount: WebGLUniformLocation | null;
  uPrev: WebGLUniformLocation | null;
  uSim: WebGLUniformLocation | null;
  uSimResolution: WebGLUniformLocation | null;
  uGlyphField: WebGLUniformLocation | null;
  uGlyphActive: WebGLUniformLocation | null;
  uGlyphRect: WebGLUniformLocation | null;
  uGlyphPhase: WebGLUniformLocation | null;
}

/**
 * Query the full superset of uniform locations for `prog` ONCE (build/restore).
 * Absent uniforms resolve to `null` and are skipped on upload. `D3` — the hot
 * path never re-queries.
 */
export function createFullUniformMap(
  gl: WebGL2RenderingContext,
  prog: WebGLProgram
): FullUniformMap {
  // Query every name once; absent ⇒ null. A typed object literal (not a
  // loop) so every key is statically present and reads are non-undefined.
  return {
    uResolution: gl.getUniformLocation(prog, "uResolution"),
    uTime: gl.getUniformLocation(prog, "uTime"),
    uPointer: gl.getUniformLocation(prog, "uPointer"),
    uPointerActive: gl.getUniformLocation(prog, "uPointerActive"),
    uBg: gl.getUniformLocation(prog, "uBg"),
    uAccent0: gl.getUniformLocation(prog, "uAccent0"),
    uAccent1: gl.getUniformLocation(prog, "uAccent1"),
    uAccent2: gl.getUniformLocation(prog, "uAccent2"),
    uAccent3: gl.getUniformLocation(prog, "uAccent3"),
    uInk: gl.getUniformLocation(prog, "uInk"),
    uIntensity: gl.getUniformLocation(prog, "uIntensity"),
    uTheme: gl.getUniformLocation(prog, "uTheme"),
    uHasSim: gl.getUniformLocation(prog, "uHasSim"),
    uScroll: gl.getUniformLocation(prog, "uScroll"),
    uScrollVel: gl.getUniformLocation(prog, "uScrollVel"),
    uImpulses: gl.getUniformLocation(prog, "uImpulses"),
    uImpulseCount: gl.getUniformLocation(prog, "uImpulseCount"),
    uObstacleRects: gl.getUniformLocation(prog, "uObstacleRects"),
    uObstacleCount: gl.getUniformLocation(prog, "uObstacleCount"),
    uPrev: gl.getUniformLocation(prog, "uPrev"),
    uSim: gl.getUniformLocation(prog, "uSim"),
    uSimResolution: gl.getUniformLocation(prog, "uSimResolution"),
    uGlyphField: gl.getUniformLocation(prog, "uGlyphField"),
    uGlyphActive: gl.getUniformLocation(prog, "uGlyphActive"),
    uGlyphRect: gl.getUniformLocation(prog, "uGlyphRect"),
    uGlyphPhase: gl.getUniformLocation(prog, "uGlyphPhase"),
  };
}
