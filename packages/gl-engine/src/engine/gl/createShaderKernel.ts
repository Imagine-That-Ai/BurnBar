/**
 * createShaderKernel — turns a fragment-shader body into a full {@link Kernel}.
 *
 * Every WebGL backdrop is "a fragment shader over a fullscreen triangle". This
 * factory owns all the boilerplate (program compile, VAO, the standard uniform
 * set, theme→uniform mapping, pointer, resize, context-loss, teardown) so a
 * kernel module is just GLSL + a label.
 *
 * The supplied `body` must define:
 *   `vec3 renderKernel(vec2 uv, vec2 fragCoord)`
 * and may use any of the injected uniforms / chunks. `uv` is 0–1 (y up).
 *
 * ── Multi-pass extension (stream-01 infra, `_RESOLVED_INFRA_CONTRACT` D1–D7) ──
 * Optional `sim` / `textures` / `controls` / `requiresFloatTex` / `fallbackId`
 * fields activate the stateful ping-pong path. **When absent, the code path is
 * byte-for-functionally identical to the original single-pass factory** — aurora
 * and mesh compile and run exactly as before (the `reactive` branch never runs).
 *
 *  - `sim`        → a double-buffered float target advanced by a `simStep`
 *                   shader each frame (caustics Gray–Scott, wave PDE). Strict
 *                   ping-pong; seed binds no `uPrev` (D4); reseeded on restore.
 *  - `textures`   → baked input images (LIC blue-noise) bound as samplers.
 *  - `controls`   → opts into the shared D2 control block (scroll / impulses /
 *                   obstacles); the factory owns the ring buffer + sim-UV
 *                   conversion + per-frame upload (no per-kernel wiring).
 *  - `requiresFloatTex` + `fallbackId` → the host gates on PROVEN renderability
 *                   (D1) and resolves to `fallbackId` BEFORE instantiation.
 *
 * Never black: if a slot FBO still returns INCOMPLETE post-probe (a driver
 * lied), the factory drives the display pass with `uHasSim=0` and the kernel's
 * `renderKernel` MUST branch to an `accentRamp` palette field (D1 belt).
 */

import { toUnit } from "../palette";
import type {
  ControlGroup,
  Kernel,
  KernelFrameContext,
  KernelId,
  KernelPalette,
  KernelRenderingContext,
  SimSpec,
  TextureSpec,
  ThemeName,
} from "../types";
import type { GlyphField } from "../../glyph/field/glyphField";
import { compileProgram, MAIN, PREAMBLE } from "./compileProgram";
import { type SimPass, createSimPass } from "./createSimPass";
import { type GlCapabilities, NO_FLOAT_CAPS } from "./glCapabilities";
import { DITHER, FBM, RAMP, SNOISE } from "./shaderChunks";
import {
  CONTROL_DECL,
  createFullUniformMap,
  type FullUniformMap,
} from "./uniformCache";

// Re-export the prelude constants for any external consumer that imported them
// from this module before the leaf extraction (keeps the public surface stable).
export { PREAMBLE, UNIFORM_NAMES } from "./compileProgram";

export interface ShaderKernelSpec {
  id: KernelId;
  label: string;
  /** GLSL defining `vec3 renderKernel(vec2 uv, vec2 fragCoord)`. */
  body: string;
  /** Multi-pass ping-pong simulation. Omit ⇒ single-pass path (unchanged). */
  sim?: SimSpec;
  /** Baked input textures, bound as `sampler2D <name>` in the display pass. */
  textures?: TextureSpec[];
  /** Capability gate: if true + float RT not probed renderable, host → fallbackId. */
  requiresFloatTex?: boolean;
  /** Default fallback when float renderability is missing. */
  fallbackId?: KernelId;
  /** Control uniforms this kernel reads (D2); single-pass kernels stay byte-identical. */
  controls?: ControlGroup[];
}

// ── Control-channel tuning (D2; factory-owned, preallocated) ────────────────
const MAX_IMPULSES = 8;
const MAX_OBSTACLES = 24;
/** Frames a discrete click stays live in the impulse queue (D2). */
const IMPULSE_TTL = 3;

// Legacy standard-uniform location map (single-pass path only). Concrete
// interface (not a Record) so property access under noUncheckedIndexedAccess
// is `WebGLUniformLocation | null`, never `undefined` (GL setters reject it).
interface StdUniformMap {
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
}

export function createShaderKernel(spec: ShaderKernelSpec): Kernel {
  let gl: WebGL2RenderingContext | null = null;
  let program: WebGLProgram | null = null;
  let vao: WebGLVertexArrayObject | null = null;
  let uniforms: StdUniformMap | null = null;
  let palette: KernelPalette | null = null;
  // Pointer is smoothed: incoming values land in `pointerTarget`, and `frame()`
  // lerps `pointer` 8%/frame toward it before upload, so cursor-reactive kernels
  // (mesh, aurora) glide with inertia instead of snapping. Harmless to kernels
  // that ignore the pointer.
  const pointer: [number, number] = [0.5, 0.5];
  let pointerTarget: [number, number] = [0.5, 0.5];
  let pointerActive = 0;
  let contextLost = false;
  let canvasEl: HTMLCanvasElement | null = null;

  // ── Multi-pass state (only allocated when `reactive`) ────────────────────
  const reactive = !!(spec.sim || spec.textures || spec.controls);
  let simPass: SimPass | null = null;
  let fullUniforms: FullUniformMap | null = null; // cached display map (D3)
  const bakedTex: {
    name: string;
    tex: WebGLTexture | null;
    loc: WebGLUniformLocation | null;
  }[] = [];
  let caps: GlCapabilities = NO_FLOAT_CAPS;
  let lastTimeSec = 0;

  // Per-program cached map memo for the sim-step/seed programs (distinct GL
  // programs from the display program). Built EAGERLY at buildSim time (m7/D3)
  // and cleared on dispose + context-restore (m8).
  const programMaps = new Map<WebGLProgram, FullUniformMap>();

  // ── Control-channel host state (factory-owned; §4.7 of stream-01) ─────────
  const wantsScroll = spec.controls?.includes("scroll") ?? false;
  const wantsImpulses = spec.controls?.includes("impulses") ?? false;
  const wantsObstacles = spec.controls?.includes("obstacles") ?? false;
  const wantsGlyph = spec.controls?.includes("glyph") ?? false;
  const scrollState = { y: 0, yMax: 0, vy: 0 };
  // Preallocated upload buffers — zero per-frame allocation (perf budget).
  const impulseBuf = new Float32Array(MAX_IMPULSES * 4); // xy=UV, z=strength, w=age
  let impulseCount = 0;
  const obstacleBuf = new Float32Array(MAX_OBSTACLES * 4); // minU,minV,maxU,maxV
  let obstacleCount = 0;

  // ── Glyph Field state (D-glyph; only when `controls` includes "glyph") ────
  // The active mark as an SDF texture. `glyphField` is the CPU-side source kept
  // for re-upload across context loss; `glyphTex` is its GPU residency. `glyphRect`
  // (y-up: xy center, zw half-extent) and `glyphPhase` (0..1 assemble ramp) are
  // uploaded each frame. uGlyphActive gates every coupling so a bound-but-empty
  // world is byte-identical to a glyph-less one.
  let glyphField: GlyphField | null = null;
  let glyphTex: WebGLTexture | null = null;
  let glyphDirty = false; // re-upload texels on the next frame
  const glyphRect: [number, number, number, number] = [0.5, 0.5, 0.5, 0.5];
  let glyphPhase = 1;

  const onContextLost = (e: Event) => {
    e.preventDefault();
    contextLost = true;
  };
  const onContextRestored = () => {
    contextLost = false;
    if (gl) {
      // Clear the cached maps for the dead pre-restore programs (m8); the new
      // programs get fresh maps on the eager build below.
      programMaps.clear();
      buildProgram(gl);
      setViewport();
      pushPalette();
      if (reactive) {
        buildSim(gl); // re-creates FBOs AND reseeds + re-warms (dead-sim fix)
        buildTextures(gl);
      }
      if (wantsGlyph) {
        glyphTex = null; // GL object died with the context
        glyphDirty = !!glyphField; // re-upload texels on the next frame
      }
    }
  };

  /** Lazily create + (re)upload the glyph SDF texture. No-op without a field or
   *  when the kernel didn't opt into "glyph". Called from the display pass when
   *  `glyphDirty`, so a mark change/restore costs one texImage2D, never a query. */
  function syncGlyphTexture(g: WebGL2RenderingContext): void {
    if (!wantsGlyph || !glyphField) return;
    if (!glyphTex) glyphTex = g.createTexture();
    if (!glyphTex) return;
    g.bindTexture(g.TEXTURE_2D, glyphTex);
    g.texImage2D(
      g.TEXTURE_2D,
      0,
      g.RGBA,
      glyphField.size,
      glyphField.size,
      0,
      g.RGBA,
      g.UNSIGNED_BYTE,
      glyphField.data,
    );
    g.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_S, g.CLAMP_TO_EDGE);
    g.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_T, g.CLAMP_TO_EDGE);
    g.texParameteri(g.TEXTURE_2D, g.TEXTURE_MIN_FILTER, g.LINEAR);
    g.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.LINEAR);
    glyphDirty = false;
  }

  function buildProgram(g: WebGL2RenderingContext): void {
    let head = PREAMBLE;
    if (spec.sim) head += CONTROL_DECL.hasSim; // uHasSim present with any sim
    if (wantsScroll) head += CONTROL_DECL.scroll;
    if (wantsImpulses) head += CONTROL_DECL.impulses;
    if (wantsObstacles) head += CONTROL_DECL.obstacles;
    if (wantsGlyph) head += CONTROL_DECL.glyph;
    const simDecls = spec.sim
      ? "uniform sampler2D uSim;\nuniform vec2 uSimResolution;\n"
      : "";
    const texDecls = (spec.textures ?? [])
      .map((t) => `uniform sampler2D ${t.name};`)
      .join("\n");
    // Single-pass (non-reactive) kernels emit the IDENTICAL fragSrc they emit
    // today — aurora/mesh byte-for-functionally unchanged (m1).
    const fragSrc = reactive
      ? `${head}${simDecls}${texDecls}\n${SNOISE}\n${FBM}\n${DITHER}\n${RAMP}\n${spec.body}\n${MAIN}`
      : `${PREAMBLE}\n${SNOISE}\n${FBM}\n${DITHER}\n${RAMP}\n${spec.body}\n${MAIN}`;
    program = compileProgram(g, fragSrc, spec.id);
    if (!program) return;
    if (reactive) {
      fullUniforms = createFullUniformMap(g, program); // superset, cached once (D3)
    } else {
      uniforms = {
        uResolution: g.getUniformLocation(program, "uResolution"),
        uTime: g.getUniformLocation(program, "uTime"),
        uPointer: g.getUniformLocation(program, "uPointer"),
        uPointerActive: g.getUniformLocation(program, "uPointerActive"),
        uBg: g.getUniformLocation(program, "uBg"),
        uAccent0: g.getUniformLocation(program, "uAccent0"),
        uAccent1: g.getUniformLocation(program, "uAccent1"),
        uAccent2: g.getUniformLocation(program, "uAccent2"),
        uAccent3: g.getUniformLocation(program, "uAccent3"),
        uInk: g.getUniformLocation(program, "uInk"),
        uIntensity: g.getUniformLocation(program, "uIntensity"),
        uTheme: g.getUniformLocation(program, "uTheme"),
      };
    }
    vao = g.createVertexArray();
  }

  /** Standard uniform upload via CACHED locations (D3/M4). Null locs are skipped
   *  by GL. Called for display + sim-step + seed programs. */
  function pushStandard(map: FullUniformMap): void {
    if (!gl || !palette) return;
    gl.uniform2f(map.uResolution, gl.drawingBufferWidth, gl.drawingBufferHeight);
    gl.uniform1f(map.uTime, lastTimeSec);
    gl.uniform2f(map.uPointer, pointer[0], pointer[1]);
    gl.uniform1f(map.uPointerActive, pointerActive);
    gl.uniform3fv(map.uBg, toUnit(palette.bg));
    gl.uniform3fv(map.uAccent0, toUnit(palette.accents[0] ?? palette.ink));
    gl.uniform3fv(map.uAccent1, toUnit(palette.accents[1] ?? palette.ink));
    gl.uniform3fv(map.uAccent2, toUnit(palette.accents[2] ?? palette.ink));
    gl.uniform3fv(map.uAccent3, toUnit(palette.accents[3] ?? palette.ink));
    gl.uniform3fv(map.uInk, toUnit(palette.ink));
    gl.uniform1f(map.uIntensity, palette.intensity);
    gl.uniform1f(map.uTheme, palette.theme === "light" ? 1 : 0);
  }

  /** Control-block upload via cached locations. Only non-null handles fire, so a
   *  kernel that didn't declare a block pays nothing. `hasSim` passed explicitly. */
  function pushControl(map: FullUniformMap, hasSim: number): void {
    if (!gl) return;
    gl.uniform1f(map.uHasSim, hasSim); // null-safe; always for sims
    if (wantsScroll) {
      gl.uniform2f(map.uScroll, scrollState.y, scrollState.yMax);
      gl.uniform1f(map.uScrollVel, scrollState.vy);
    }
    if (wantsImpulses) {
      gl.uniform4fv(map.uImpulses, impulseBuf);
      gl.uniform1i(map.uImpulseCount, impulseCount);
    }
    if (wantsObstacles) {
      gl.uniform4fv(map.uObstacleRects, obstacleBuf);
      gl.uniform1i(map.uObstacleCount, obstacleCount);
    }
    if (wantsGlyph) {
      // Scalars/vectors only; the sampler (uGlyphField) is bound in the display
      // pass where the texture unit is assigned. On the sim-step program these
      // locations are null (glyph not declared there) and skipped by GL.
      gl.uniform1f(map.uGlyphActive, glyphField ? 1 : 0);
      gl.uniform4f(
        map.uGlyphRect,
        glyphRect[0],
        glyphRect[1],
        glyphRect[2],
        glyphRect[3],
      );
      gl.uniform1f(map.uGlyphPhase, glyphPhase);
    }
  }

  /** Memoized full cached map for a sim program (D3); built eagerly at buildSim. */
  function simStepMapFor(prog: WebGLProgram): FullUniformMap {
    let m = programMaps.get(prog);
    if (!m && gl) {
      m = createFullUniformMap(gl, prog);
      programMaps.set(prog, m);
    }
    return m ?? ({} as FullUniformMap);
  }

  function buildSim(g: WebGL2RenderingContext): void {
    if (!spec.sim || !vao) return;
    const simCfg = resolveSimConfig(spec.sim);
    simPass = createSimPass(
      g,
      simCfg,
      caps,
      g.drawingBufferWidth,
      g.drawingBufferHeight,
      spec.id
    );
    // EAGERLY build the step/seed per-program maps now (m7) so no
    // getUniformLocation ever runs inside frame()/step()/reseed(), even for a
    // settleSteps=0 sim.
    if (simPass.stepProgram) simStepMapFor(simPass.stepProgram);
    if (simPass.seedProgram) simStepMapFor(simPass.seedProgram);
    // Seed pushes standard only (the seed preamble has no control block — D4).
    const seedPush = (prog: WebGLProgram) => pushStandard(simStepMapFor(prog));
    // Warmup pushes standard + control, IDENTICAL to frame()/renderStatic() (m9).
    const warmPush = (prog: WebGLProgram) => {
      const m = simStepMapFor(prog);
      pushStandard(m);
      pushControl(m, 1);
    };
    simPass.reseed(vao, seedPush); // D4 seed, no uPrev
    const warm = spec.sim.settleSteps ?? 0;
    if (warm > 0) simPass.settle(warm, vao, warmPush); // init warmup via settle() (D5/m9)
  }

  function buildTextures(g: WebGL2RenderingContext): void {
    if (!spec.textures || !program || !fullUniforms) return;
    bakedTex.length = 0;
    for (const t of spec.textures) {
      const tex = g.createTexture();
      g.bindTexture(g.TEXTURE_2D, tex);
      // 1×1 opaque placeholder so sampling is defined before the image decodes.
      g.texImage2D(
        g.TEXTURE_2D,
        0,
        g.RGBA,
        1,
        1,
        0,
        g.RGBA,
        g.UNSIGNED_BYTE,
        new Uint8Array([0, 0, 0, 255])
      );
      const wrap = t.wrap === "clamp" ? g.CLAMP_TO_EDGE : g.REPEAT;
      const filt = t.filter === "nearest" ? g.NEAREST : g.LINEAR;
      g.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_S, wrap);
      g.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_T, wrap);
      g.texParameteri(g.TEXTURE_2D, g.TEXTURE_MIN_FILTER, filt);
      g.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, filt);
      const img = new Image();
      img.onload = () => {
        if (!gl || !tex) return;
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
      };
      img.src = t.dataUri;
      // Baked sampler names are dynamic (per-kernel), so they are NOT in
      // ALL_UNIFORM_NAMES — query the location ONCE here at build/restore and
      // cache it on the bakedTex entry (b.loc); frame() reuses it (D3).
      bakedTex.push({
        name: t.name,
        tex,
        loc: g.getUniformLocation(program, t.name),
      });
    }
  }

  function pushPalette(): void {
    if (!gl || !program) return;
    if (reactive && fullUniforms) {
      gl.useProgram(program);
      pushStandard(fullUniforms);
    } else {
      // Legacy single-pass path — unchanged.
      if (!palette) return;
      gl.useProgram(program);
      gl.uniform3fv(uniforms!.uBg, toUnit(palette.bg));
      gl.uniform3fv(uniforms!.uAccent0, toUnit(palette.accents[0] ?? palette.ink));
      gl.uniform3fv(uniforms!.uAccent1, toUnit(palette.accents[1] ?? palette.ink));
      gl.uniform3fv(uniforms!.uAccent2, toUnit(palette.accents[2] ?? palette.ink));
      gl.uniform3fv(uniforms!.uAccent3, toUnit(palette.accents[3] ?? palette.ink));
      gl.uniform3fv(uniforms!.uInk, toUnit(palette.ink));
      gl.uniform1f(uniforms!.uIntensity, palette.intensity);
      gl.uniform1f(uniforms!.uTheme, palette.theme === "light" ? 1 : 0);
    }
  }

  function setViewport(): void {
    if (!gl) return;
    gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight);
  }

  /** CSS-px → normalized [0,1] y-up. Because the sim target is a uniform `scale`
   *  of the display buffer, the display→sim scale CANCELS under normalization,
   *  so normalized display-UV IS sim-UV (D2). */
  function toUV(x: number, y: number): [number, number] {
    const h = gl!.drawingBufferHeight;
    const dpr = h / (canvasEl?.clientHeight || h);
    return [(x * dpr) / gl!.drawingBufferWidth, 1 - (y * dpr) / h];
  }

  function ageImpulses(): void {
    let w = 0;
    for (let r = 0; r < impulseCount; r++) {
      const age = impulseBuf[r * 4 + 3]! + 1;
      if (age < IMPULSE_TTL) {
        // keep; compact toward front
        const ro = r * 4;
        const wo = w * 4;
        impulseBuf[wo] = impulseBuf[ro]!;
        impulseBuf[wo + 1] = impulseBuf[ro + 1]!;
        impulseBuf[wo + 2] = impulseBuf[ro + 2]!;
        impulseBuf[wo + 3] = age;
        w++;
      }
    }
    impulseCount = w;
  }

  return {
    id: spec.id,
    label: spec.label,
    substrate: "webgl2",

    init(ctx: KernelRenderingContext, frame: KernelFrameContext) {
      gl = ctx as WebGL2RenderingContext;
      palette = frame.palette;
      caps = frame.caps ?? NO_FLOAT_CAPS;
      canvasEl = gl.canvas as HTMLCanvasElement;
      canvasEl.addEventListener("webglcontextlost", onContextLost, false);
      canvasEl.addEventListener(
        "webglcontextrestored",
        onContextRestored,
        false
      );
      buildProgram(gl);
      setViewport();
      pushPalette();
      if (reactive) {
        buildSim(gl);
        buildTextures(gl);
      }
    },

    frame(tMs: number) {
      if (!gl || !program || contextLost) return;
      lastTimeSec = tMs / 1000;
      // Inertial pointer: ease 8%/frame toward the latest target before upload.
      pointer[0] += (pointerTarget[0] - pointer[0]) * 0.08;
      pointer[1] += (pointerTarget[1] - pointer[1]) * 0.08;

      // ── Legacy single-pass path (aurora/mesh): byte-for-functionally unchanged.
      if (!reactive || !fullUniforms) {
        gl.useProgram(program);
        gl.bindVertexArray(vao);
        gl.uniform2f(
          uniforms!.uResolution,
          gl.drawingBufferWidth,
          gl.drawingBufferHeight
        );
        gl.uniform1f(uniforms!.uTime, lastTimeSec);
        gl.uniform2f(uniforms!.uPointer, pointer[0], pointer[1]);
        gl.uniform1f(uniforms!.uPointerActive, pointerActive);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
        gl.bindVertexArray(null);
        return;
      }

      // ── Reactive (sim/textures/controls) path ─────────────────────────────
      // 1) advance sim (cached locations inside; pushes standard + control).
      if (simPass?.ok) {
        simPass.step(vao!, (prog) => {
          const m = simStepMapFor(prog);
          pushStandard(m);
          pushControl(m, 1);
        });
      }
      ageImpulses(); // age++ / drop ≥ IMPULSE_TTL AFTER the sim consumed them (D2)

      // 2) display pass — RESTORE the full-res viewport (M5). simPass.step()
      //    left the GL viewport at simW×simH (half-res); §4.5 mandates resetting
      //    it here, before the display drawArrays, or the display renders into
      //    the scale-sized bottom-left corner every frame.
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight);
      gl.useProgram(program);
      gl.bindVertexArray(vao);
      pushStandard(fullUniforms);
      const hasSim = simPass?.ok ? 1 : 0;
      pushControl(fullUniforms, hasSim);
      let unit = 0;
      if (hasSim && simPass) {
        // never bind a null uSim (C1(b))
        const cur = simPass.current();
        if (cur) {
          gl.activeTexture(gl.TEXTURE0 + unit);
          gl.bindTexture(gl.TEXTURE_2D, cur);
          gl.uniform1i(fullUniforms.uSim, unit);
          gl.uniform2f(
            fullUniforms.uSimResolution,
            simPass.simW,
            simPass.simH
          );
          unit++;
        }
      }
      for (const b of bakedTex) {
        if (!b.tex) continue;
        gl.activeTexture(gl.TEXTURE0 + unit);
        gl.bindTexture(gl.TEXTURE_2D, b.tex);
        if (b.loc) gl.uniform1i(b.loc, unit);
        unit++;
      }
      if (wantsGlyph) {
        if (glyphDirty) syncGlyphTexture(gl);
        if (glyphTex) {
          gl.activeTexture(gl.TEXTURE0 + unit);
          gl.bindTexture(gl.TEXTURE_2D, glyphTex);
          gl.uniform1i(fullUniforms.uGlyphField, unit);
          unit++;
        }
      }
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      gl.bindVertexArray(null);
    },

    resize() {
      setViewport();
      if (reactive && simPass) {
        simPass.resize(gl!.drawingBufferWidth, gl!.drawingBufferHeight);
        if (vao) {
          const push = (prog: WebGLProgram) =>
            pushStandard(simStepMapFor(prog));
          simPass.reseed(vao, push);
          const warm = spec.sim?.settleSteps ?? 0;
          if (warm > 0) simPass.settle(warm, vao, push); // D6
        }
      }
    },

    setTheme(_theme: ThemeName, next: KernelPalette) {
      palette = next;
      pushPalette();
    },

    pointer(x: number, y: number, active: boolean) {
      if (!gl) return;
      pointerTarget = toUV(x, y); // normalized y-up
      pointerActive = active ? 1 : 0;
    },

    // ── Control intake (factory-owned; §4.7) ───────────────────────────────
    click(x: number, y: number) {
      if (!gl || !wantsImpulses) return;
      const [u, v] = toUV(x, y);
      // True ring with OLDEST-eviction (m6): append at tail until full, then
      // copyWithin(0,4) drops slot 0 and the newest writes at the tail.
      let slot: number;
      if (impulseCount < MAX_IMPULSES) {
        slot = impulseCount++;
      } else {
        impulseBuf.copyWithin(0, 4); // evict oldest (slot 0); shift down
        slot = MAX_IMPULSES - 1; // newest at tail
      }
      const o = slot * 4;
      impulseBuf[o] = u;
      impulseBuf[o + 1] = v;
      impulseBuf[o + 2] = 1;
      impulseBuf[o + 3] = 0;
    },

    obstacles(rects: { x: number; y: number; w: number; h: number }[]) {
      if (!gl || !wantsObstacles) return;
      obstacleCount = Math.min(rects.length, MAX_OBSTACLES);
      for (let i = 0; i < obstacleCount; i++) {
        const r = rects[i]!;
        const [minU, maxV] = toUV(r.x, r.y); // top-left → (minU, maxV) y-up
        const [maxU, minV] = toUV(r.x + r.w, r.y + r.h); // bottom-right
        const o = i * 4;
        obstacleBuf[o] = minU;
        obstacleBuf[o + 1] = minV;
        obstacleBuf[o + 2] = maxU;
        obstacleBuf[o + 3] = maxV;
      }
    },

    scroll(y: number, vy: number, yMax: number) {
      if (!wantsScroll) return;
      scrollState.y = y;
      scrollState.vy = vy;
      scrollState.yMax = yMax;
    },

    setGlyphField(field: GlyphField | null) {
      if (!wantsGlyph) return;
      glyphField = field;
      if (field) {
        // content is y-down 0..1 (canvas raster). Convert to a y-up center +
        // half-extent rect so a shader can place/scale the field on screen.
        const cx = field.content.x + field.content.w * 0.5;
        const cy = field.content.y + field.content.h * 0.5;
        glyphRect[0] = cx;
        glyphRect[1] = 1 - cy; // y-up
        glyphRect[2] = field.content.w * 0.5;
        glyphRect[3] = field.content.h * 0.5;
        glyphPhase = 1; // fully assembled until a transition drives it
        glyphDirty = true; // upload texels on the next display pass
      } else {
        glyphDirty = false;
        if (gl && glyphTex) {
          gl.deleteTexture(glyphTex);
          glyphTex = null;
        }
      }
    },

    renderStatic() {
      if (!reactive) {
        this.frame(0, 0); // single-pass kernels
        return;
      }
      // Sim kernels: reseed → settle(settleSteps) → one display pass, then stop.
      if (simPass?.ok && vao) {
        const push = (p: WebGLProgram) => {
          const m = simStepMapFor(p);
          pushStandard(m);
          pushControl(m, 1);
        };
        simPass.reseed(vao, (p) => pushStandard(simStepMapFor(p)));
        simPass.settle(spec.sim?.settleSteps ?? 0, vao, push);
      }
      // reseed()/settle() leave the GL viewport at simW×simH; the final display
      // pass runs through frame(), which resets viewport to full buffer before
      // its display drawArrays (M5) — so the still renders full-res.
      this.frame(0, 0);
    },

    dispose() {
      if (canvasEl) {
        canvasEl.removeEventListener("webglcontextlost", onContextLost);
        canvasEl.removeEventListener("webglcontextrestored", onContextRestored);
      }
      if (gl) {
        if (reactive) {
          simPass?.dispose();
          simPass = null;
          for (const b of bakedTex) {
            if (b.tex) gl.deleteTexture(b.tex);
          }
          bakedTex.length = 0;
          programMaps.clear(); // drop cached step/seed/display maps (m8)
        }
        if (glyphTex) {
          gl.deleteTexture(glyphTex);
          glyphTex = null;
        }
        if (program) gl.deleteProgram(program);
        if (vao) gl.deleteVertexArray(vao);
        gl.getExtension("WEBGL_lose_context")?.loseContext();
      }
      gl = null;
      program = null;
      vao = null;
      uniforms = null;
      fullUniforms = null;
      palette = null;
      canvasEl = null;
      glyphField = null;
    },
  };
}

/** Resolve a `SimSpec`'s optional fields to concrete values for `createSimPass`. */
function resolveSimConfig(sim: SimSpec): {
  step: string;
  seed: string;
  format: "RGBA16F" | "RG16F";
  scale: number;
  stepsPerFrame: number;
} {
  return {
    step: sim.step,
    seed: sim.seed,
    format: (sim.format ?? "RGBA16F") as "RGBA16F" | "RG16F",
    scale: sim.scale ?? 0.5,
    stepsPerFrame: sim.stepsPerFrame ?? 1,
  };
}


// Reference the infra exports so tree-shaking keeps them when a sim kernel is
// bundled (they're otherwise only reached via the dynamic spec).
export { MAX_STEPS_PER_FRAME } from "./createSimPass";
export type { SimFormat, SimSpec } from "../types";
