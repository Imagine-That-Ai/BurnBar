/**
 * Minimal WebGL2 host for the dashboard backdrop kernels.
 *
 * Owns the whole GL lifecycle: context creation, lazy program compilation +
 * caching, uniform-location caching, the fullscreen-triangle draw, DPR-aware
 * sizing, pointer state, context-loss recovery, and teardown. It renders a
 * single kernel at a time in dark/vivid mode (the backdrop sits *behind*
 * translucent glass cards, so a rich dark field is what we want regardless of
 * the console's light page theme).
 *
 * Returns `null` when WebGL2 is unavailable — callers fall back to the 2D
 * DotCrestField.
 */

import { MAIN, PRELUDE, UNIFORM_NAMES, VERT } from "./chunks";
import { hexToRgbUnit } from "./palette";
import { DEFAULT_KERNEL_ID, getKernelSpec, type KernelId } from "./kernels";

export interface KernelRenderer {
  /** Switch the active kernel (compiles + caches on first use). */
  setKernel(id: KernelId): void;
  /** Pointer in normalized 0..1 viewport coords (y-down), or null to clear. */
  setPointer(x: number, y: number): void;
  clearPointer(): void;
  /** Resize the backing store from CSS pixel dimensions. */
  resize(cssWidth: number, cssHeight: number): void;
  /** Draw one frame. `timeSeconds` drives all animation. */
  render(timeSeconds: number): void;
  /** Release all GL resources + listeners. */
  dispose(): void;
}

type UniformName = (typeof UNIFORM_NAMES)[number];
type UniformLocations = Partial<Record<UniformName, WebGLUniformLocation | null>>;

interface CompiledKernel {
  program: WebGLProgram;
  uniforms: UniformLocations;
}

// Match the prototype: clamp DPR and render at a slight downscale. The backdrop
// is a soft, full-bleed field where a small resolution drop is invisible but
// meaningfully cheaper on large/high-DPR displays.
const MAX_DPR = 1.5;
const RENDER_SCALE = 0.85;

// Dark/vivid render constants (uTheme = 0 path in every kernel body).
const THEME_DARK = 0;
const INTENSITY = 1.32;

function compileShader(
  gl: WebGL2RenderingContext,
  type: number,
  source: string,
): WebGLShader | null {
  const shader = gl.createShader(type);
  if (!shader) return null;
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    if (process.env.NODE_ENV !== "production") {
      console.warn("[kernel] shader compile failed:", gl.getShaderInfoLog(shader));
    }
    gl.deleteShader(shader);
    return null;
  }
  return shader;
}

function linkProgram(
  gl: WebGL2RenderingContext,
  vertexSource: string,
  fragmentSource: string,
): WebGLProgram | null {
  const vert = compileShader(gl, gl.VERTEX_SHADER, vertexSource);
  const frag = compileShader(gl, gl.FRAGMENT_SHADER, fragmentSource);
  if (!vert || !frag) {
    if (vert) gl.deleteShader(vert);
    if (frag) gl.deleteShader(frag);
    return null;
  }
  const program = gl.createProgram();
  if (!program) {
    gl.deleteShader(vert);
    gl.deleteShader(frag);
    return null;
  }
  gl.attachShader(program, vert);
  gl.attachShader(program, frag);
  gl.linkProgram(program);
  // Shaders can be flagged for deletion immediately after a successful link.
  gl.deleteShader(vert);
  gl.deleteShader(frag);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    if (process.env.NODE_ENV !== "production") {
      console.warn("[kernel] program link failed:", gl.getProgramInfoLog(program));
    }
    gl.deleteProgram(program);
    return null;
  }
  return program;
}

export function createKernelRenderer(
  canvas: HTMLCanvasElement,
  initialKernel: KernelId = DEFAULT_KERNEL_ID,
): KernelRenderer | null {
  let gl: WebGL2RenderingContext | null;
  try {
    gl = canvas.getContext("webgl2", {
      antialias: true,
      alpha: false,
      depth: false,
      stencil: false,
      preserveDrawingBuffer: false,
      powerPreference: "high-performance",
    });
  } catch {
    gl = null;
  }
  if (!gl) return null;
  const context = gl;

  const programs = new Map<KernelId, CompiledKernel | null>();
  let vao: WebGLVertexArrayObject | null = context.createVertexArray();
  let activeKernel: KernelId = initialKernel;
  let pointerActive = false;
  let pointerX = 0.5;
  let pointerY = 0.5;
  let disposed = false;
  let contextLost = false;
  // Backing-store size in device pixels.
  let bufferW = 1;
  let bufferH = 1;

  function getProgram(id: KernelId): CompiledKernel | null {
    const cached = programs.get(id);
    if (cached !== undefined) return cached;
    const spec = getKernelSpec(id);
    const program = linkProgram(context, VERT, PRELUDE + spec.body + MAIN);
    if (!program) {
      programs.set(id, null);
      return null;
    }
    const uniforms: UniformLocations = {};
    for (const name of UNIFORM_NAMES) {
      uniforms[name] = context.getUniformLocation(program, name);
    }
    const compiled: CompiledKernel = { program, uniforms };
    programs.set(id, compiled);
    return compiled;
  }

  function onContextLost(event: Event) {
    event.preventDefault();
    contextLost = true;
  }

  function onContextRestored() {
    contextLost = false;
    // Programs/VAO are invalid after a restore — drop the cache and rebuild lazily.
    programs.clear();
    vao = context.createVertexArray();
  }

  canvas.addEventListener("webglcontextlost", onContextLost, false);
  canvas.addEventListener("webglcontextrestored", onContextRestored, false);

  // Warm the initial kernel so the first frame is immediate.
  getProgram(activeKernel);

  return {
    setKernel(id: KernelId) {
      activeKernel = id;
      if (!contextLost) getProgram(id);
    },
    setPointer(x: number, y: number) {
      pointerActive = true;
      pointerX = x;
      pointerY = y;
    },
    clearPointer() {
      pointerActive = false;
    },
    resize(cssWidth: number, cssHeight: number) {
      const dpr = Math.min(
        typeof window !== "undefined" ? window.devicePixelRatio || 1 : 1,
        MAX_DPR,
      );
      bufferW = Math.max(2, Math.round(cssWidth * dpr * RENDER_SCALE));
      bufferH = Math.max(2, Math.round(cssHeight * dpr * RENDER_SCALE));
      if (canvas.width !== bufferW) canvas.width = bufferW;
      if (canvas.height !== bufferH) canvas.height = bufferH;
    },
    render(timeSeconds: number) {
      if (disposed || contextLost) return;
      const compiled = getProgram(activeKernel);
      if (!compiled) return;
      const spec = getKernelSpec(activeKernel);
      const { palette } = spec;
      const u = compiled.uniforms;

      context.viewport(0, 0, bufferW, bufferH);
      context.useProgram(compiled.program);
      context.bindVertexArray(vao);

      if (u.uResolution) context.uniform2f(u.uResolution, bufferW, bufferH);
      if (u.uTime) context.uniform1f(u.uTime, timeSeconds);
      // Pointer y is flipped to GL's y-up convention, matching the prototype.
      if (u.uPointer)
        context.uniform2f(
          u.uPointer,
          pointerActive ? pointerX : 0.5,
          pointerActive ? 1 - pointerY : 0.5,
        );
      if (u.uPointerActive) context.uniform1f(u.uPointerActive, pointerActive ? 1 : 0);

      const bg = hexToRgbUnit(palette.base);
      const a0 = hexToRgbUnit(palette.accents[0]);
      const a1 = hexToRgbUnit(palette.accents[1]);
      const a2 = hexToRgbUnit(palette.accents[2]);
      const a3 = hexToRgbUnit(palette.accents[3]);
      const ink = hexToRgbUnit(palette.ink);
      if (u.uBg) context.uniform3f(u.uBg, bg[0], bg[1], bg[2]);
      if (u.uAccent0) context.uniform3f(u.uAccent0, a0[0], a0[1], a0[2]);
      if (u.uAccent1) context.uniform3f(u.uAccent1, a1[0], a1[1], a1[2]);
      if (u.uAccent2) context.uniform3f(u.uAccent2, a2[0], a2[1], a2[2]);
      if (u.uAccent3) context.uniform3f(u.uAccent3, a3[0], a3[1], a3[2]);
      if (u.uInk) context.uniform3f(u.uInk, ink[0], ink[1], ink[2]);
      if (u.uIntensity) context.uniform1f(u.uIntensity, INTENSITY);
      if (u.uTheme) context.uniform1f(u.uTheme, THEME_DARK);

      context.drawArrays(context.TRIANGLES, 0, 3);
      context.bindVertexArray(null);
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      canvas.removeEventListener("webglcontextlost", onContextLost, false);
      canvas.removeEventListener("webglcontextrestored", onContextRestored, false);
      for (const compiled of programs.values()) {
        if (compiled) context.deleteProgram(compiled.program);
      }
      programs.clear();
      if (vao) context.deleteVertexArray(vao);
      vao = null;
    },
  };
}
