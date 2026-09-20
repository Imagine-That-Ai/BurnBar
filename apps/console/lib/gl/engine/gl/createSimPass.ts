/**
 * createSimPass — the multi-pass ping-pong controller for stateful sim kernels
 * (caustics Gray–Scott, wave PDE).
 *
 * Owns a double-buffered float target and the seed/step programs that evolve it.
 * Strict ping-pong: the texture bound to `uPrev` is NEVER the FBO bound for
 * drawing. **D4 — the seed pass binds NO `uPrev`** (`simSeed` reads `uv` only),
 * so the read==write feedback hazard cannot arise there either.
 *
 * `ok` requires the format renderable (probed), BOTH FBOs complete, AND BOTH
 * programs linked — a failed compile leaves `ok=false` so the host falls back
 * instead of rendering a silently-dead zeroed field (D4/m2).
 *
 * All uniform locations cached per program at build (D3) — zero
 * `getUniformLocation` in `step()`/`reseed()`. The caller owns the shared VAO
 * and the standard+control uniform push.
 */

import { PREAMBLE, compileProgram } from "./compileProgram";
import {
  type GlCapabilities,
  type SimTextureFormat,
  pickSimFormat,
} from "./glCapabilities";
import { DITHER, FBM, RAMP, SNOISE } from "./shaderChunks";
import { CONTROL_BLOCK } from "./uniformCache";

/** Hard cap on substeps per `step()` call; warmup/settle loops `step()` (D5). */
export const MAX_STEPS_PER_FRAME = 8;
const MIN_SIM_DIM = 2;

/** Step preamble: standard set + full control block + uPrev + uSimResolution. */
const STEP_PREAMBLE = /* glsl */ `${PREAMBLE}${CONTROL_BLOCK}
uniform sampler2D uPrev;
uniform vec2  uSimResolution;
`;
/** Seed preamble: standard set + uSimResolution only — NO uPrev (D4). */
const SEED_PREAMBLE = /* glsl */ `${PREAMBLE}
uniform vec2  uSimResolution;
`;

/** MAIN that calls the sim entry point (`simStep` or `simSeed`). */
function simMain(entry: "simStep" | "simSeed"): string {
  return /* glsl */ `
void main(){
  vec2 uv = gl_FragCoord.xy / uSimResolution;
  fragColor = ${entry}(uv);
}`;
}

interface Target {
  tex: WebGLTexture;
  fbo: WebGLFramebuffer;
}

export interface SimPassConfig {
  /** GLSL: `vec4 simStep(vec2 uv)` — reads uPrev + the control block. */
  step: string;
  /** GLSL: `vec4 simSeed(vec2 uv)` — reads uv ONLY; never samples uPrev (D4). */
  seed: string;
  format: "RGBA16F" | "RG16F";
  scale: number;
  stepsPerFrame: number;
}

export interface SimPass {
  /** True iff fmt renderable, both FBOs complete, AND both programs linked. */
  readonly ok: boolean;
  readonly simW: number;
  readonly simH: number;
  /** Exposed so the factory can EAGERLY pre-warm its per-program maps (m7/D3). */
  readonly stepProgram: WebGLProgram | null;
  readonly seedProgram: WebGLProgram | null;
  /** Latest sim texture (bind to uSim in the display pass). Null when !ok. */
  current(): WebGLTexture | null;
  /** Reallocate to a new display size; caller reseeds (state discarded, D6). */
  resize(dispW: number, dispH: number): void;
  /** Seed BOTH buffers; binds no uPrev (D4); binds the shared VAO (m5). */
  reseed(
    vao: WebGLVertexArrayObject,
    pushUniforms: (prog: WebGLProgram) => void
  ): void;
  /** Advance ≤ MAX_STEPS_PER_FRAME substeps. */
  step(
    vao: WebGLVertexArrayObject,
    pushUniforms: (prog: WebGLProgram) => void
  ): void;
  /** Warmup/settle `total` steps via ⌈total/MAX⌉ step() calls (D5). */
  settle(
    total: number,
    vao: WebGLVertexArrayObject,
    pushUniforms: (prog: WebGLProgram) => void
  ): void;
  dispose(): void;
}

/**
 * Build a ping-pong sim pass for `cfg`. `caps` is the host's PROBED
 * capabilities (D1) — the factory never re-probes. `dispW/dispH` are the display
 * (canvas) device px; the sim runs at `cfg.scale` of that (default 0.5).
 */
export function createSimPass(
  gl: WebGL2RenderingContext,
  cfg: SimPassConfig,
  caps: GlCapabilities,
  dispW: number,
  dispH: number,
  kernelId: string
): SimPass {
  // CRITICAL: WebGL extensions are enabled PER CONTEXT. The host probes
  // `EXT_color_buffer_float` on a throwaway context (BackdropEngine.detectWebgl2),
  // so `caps.colorBufferFloat` can be true while THIS kernel's own context has
  // never enabled it — making every RGBA16F/RG16F target framebuffer-INCOMPLETE
  // ("sim target incomplete; display-only" → a flat background). Enable it here,
  // on the kernel's context, before allocating any float target. (Display-only
  // shader kernels like aurora don't hit this; only createSimPass kernels —
  // caustics, wave, crystallis, spiral — were rendering flat.)
  gl.getExtension("EXT_color_buffer_float");
  const fmt: SimTextureFormat = pickSimFormat(gl, cfg.format, caps);
  const filter = fmt.filterable ? gl.LINEAR : gl.NEAREST;

  const stepProgram = compileProgram(
    gl,
    `${STEP_PREAMBLE}\n${SNOISE}\n${FBM}\n${DITHER}\n${RAMP}\n${cfg.step}\n${simMain(
      "simStep"
    )}`,
    `${kernelId}:sim`
  );
  const seedProgram = compileProgram(
    gl,
    `${SEED_PREAMBLE}\n${SNOISE}\n${FBM}\n${DITHER}\n${RAMP}\n${cfg.seed}\n${simMain(
      "simSeed"
    )}`,
    `${kernelId}:seed`
  );

  let simW = 0;
  let simH = 0;
  let a: Target | null = null;
  let b: Target | null = null;
  let read: Target | null = null;
  let write: Target | null = null;
  let ok = false;

  // Cached sim-only locations (D3). uPrev/uSimResolution live on the step prog;
  // uSimResolution also on the seed prog.
  let stepPrevLoc: WebGLUniformLocation | null = null;
  let stepResLoc: WebGLUniformLocation | null = null;
  let seedResLoc: WebGLUniformLocation | null = null;
  if (stepProgram) {
    stepPrevLoc = gl.getUniformLocation(stepProgram, "uPrev");
    stepResLoc = gl.getUniformLocation(stepProgram, "uSimResolution");
  }
  if (seedProgram) {
    seedResLoc = gl.getUniformLocation(seedProgram, "uSimResolution");
  }

  function setSize(w: number, h: number): void {
    simW = Math.max(MIN_SIM_DIM, Math.round(w * cfg.scale));
    simH = Math.max(MIN_SIM_DIM, Math.round(h * cfg.scale));
  }

  function makeTarget(): Target | null {
    const tex = gl.createTexture();
    const fbo = gl.createFramebuffer();
    if (!tex || !fbo) {
      if (tex) gl.deleteTexture(tex);
      if (fbo) gl.deleteFramebuffer(fbo);
      return null;
    }
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(
      gl.TEXTURE_2D,
      0,
      fmt.internalFormat,
      simW,
      simH,
      0,
      fmt.format,
      fmt.type,
      null
    );
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.framebufferTexture2D(
      gl.FRAMEBUFFER,
      gl.COLOR_ATTACHMENT0,
      gl.TEXTURE_2D,
      tex,
      0
    );
    return { tex, fbo };
  }

  function fboComplete(t: Target | null): boolean {
    if (!t) return false;
    gl.bindFramebuffer(gl.FRAMEBUFFER, t.fbo);
    return (
      gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE
    );
  }

  function deleteTargets(): void {
    for (const t of [a, b]) {
      if (t) {
        gl.deleteTexture(t.tex);
        gl.deleteFramebuffer(t.fbo);
      }
    }
    a = b = read = write = null;
  }

  function allocate(): void {
    deleteTargets();
    a = makeTarget();
    b = makeTarget();
    // ok requires renderable format, BOTH FBOs complete, AND both programs
    // linked (D4/m2 — a failed seed/step compile must NOT leave a dead field).
    ok =
      fmt.renderable &&
      !!a &&
      !!b &&
      !!stepProgram &&
      !!seedProgram &&
      fboComplete(a) &&
      fboComplete(b);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    read = a;
    write = b;
    if (!ok) {
      console.error(
        `[backdrop] ${kernelId} sim target/program incomplete; display-only.`
      );
    }
  }

  // Initial allocation.
  setSize(dispW, dispH);
  allocate();

  return {
    get ok() {
      return ok;
    },
    get simW() {
      return simW;
    },
    get simH() {
      return simH;
    },
    get stepProgram() {
      return stepProgram;
    },
    get seedProgram() {
      return seedProgram;
    },
    current() {
      return ok && read ? read.tex : null;
    },

    resize(w, h) {
      if (!ok) return;
      setSize(w, h);
      allocate();
      // Caller reseeds after resize (state discarded — D6).
    },

    reseed(vao, pushUniforms) {
      if (!ok || !seedProgram) return;
      gl.useProgram(seedProgram);
      pushUniforms(seedProgram); // cached standard locations
      gl.bindVertexArray(vao); // symmetric with step() (m5)
      if (seedResLoc) gl.uniform2f(seedResLoc, simW, simH);
      gl.viewport(0, 0, simW, simH);
      for (const t of [a, b]) {
        if (!t) continue;
        gl.bindFramebuffer(gl.FRAMEBUFFER, t.fbo);
        // NO uPrev bind — simSeed reads uv only (D4). No read==write hazard.
        gl.drawArrays(gl.TRIANGLES, 0, 3);
      }
      read = a;
      write = b;
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    },

    step(vao, pushUniforms) {
      if (!ok || !stepProgram) return;
      const n = Math.min(
        Math.max(cfg.stepsPerFrame | 0, 1),
        MAX_STEPS_PER_FRAME
      );
      gl.useProgram(stepProgram);
      pushUniforms(stepProgram); // cached standard + control locations
      gl.bindVertexArray(vao);
      if (stepResLoc) gl.uniform2f(stepResLoc, simW, simH);
      gl.viewport(0, 0, simW, simH);
      for (let i = 0; i < n; i++) {
        if (!read || !write) break; // narrowing guard
        gl.bindFramebuffer(gl.FRAMEBUFFER, write.fbo);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, read.tex); // read.tex ≠ write.fbo (strict)
        if (stepPrevLoc) gl.uniform1i(stepPrevLoc, 0);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
        const tmp = read;
        read = write;
        write = tmp; // swap
      }
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    },

    settle(total, vao, pushUniforms) {
      if (!ok || total <= 0) return;
      const calls = Math.ceil(total / MAX_STEPS_PER_FRAME);
      for (let c = 0; c < calls; c++) {
        this.step(vao, pushUniforms); // each clamped to ≤8 internally (D5)
      }
    },

    dispose() {
      deleteTargets();
      if (stepProgram) gl.deleteProgram(stepProgram);
      if (seedProgram) gl.deleteProgram(seedProgram);
    },
  };
}
