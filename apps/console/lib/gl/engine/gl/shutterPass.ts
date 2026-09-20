/**
 * EMA shutter: mix the just-drawn kernel frame with the previous present so
 * paced 30 fps holds a cinematic shutter instead of looking like dropped 60.
 *
 * 2D kernels mix via an offscreen canvas. WebGL2 kernels mix in-place with a
 * fullscreen triangle. Failure is silent — the live frame still displays.
 */

import { compileProgram } from "./compileProgram";

const SHUTTER_FRAG = /* glsl */ `#version 300 es
precision highp float;
out vec4 fragColor;
uniform sampler2D uHistory;
uniform sampler2D uCurrent;
uniform float uAlpha;
void main() {
  vec2 uv = gl_FragCoord.xy / vec2(textureSize(uHistory, 0));
  vec4 history = texture(uHistory, uv);
  vec4 current = texture(uCurrent, uv);
  fragColor = mix(history, current, uAlpha);
}`;

export class ShutterPass {
  private history2d: HTMLCanvasElement | null = null;
  private history2dCtx: CanvasRenderingContext2D | null = null;
  private primed2d = false;

  private gl: WebGL2RenderingContext | null = null;
  private program: WebGLProgram | null = null;
  private vao: WebGLVertexArrayObject | null = null;
  private historyTex: WebGLTexture | null = null;
  private currentTex: WebGLTexture | null = null;
  private locHistory: WebGLUniformLocation | null = null;
  private locCurrent: WebGLUniformLocation | null = null;
  private locAlpha: WebGLUniformLocation | null = null;
  private texW = 0;
  private texH = 0;
  private primedGl = false;

  apply2d(canvas: HTMLCanvasElement, ctx: CanvasRenderingContext2D, alpha: number): void {
    if (alpha >= 1) {
      this.capture2d(canvas);
      return;
    }
    const w = canvas.width;
    const h = canvas.height;
    if (w < 1 || h < 1) return;
    const history = this.ensure2d(w, h);
    const hctx = this.history2dCtx;
    if (!history || !hctx) return;
    if (!this.primed2d) {
      this.capture2d(canvas);
      return;
    }
    hctx.globalAlpha = alpha;
    hctx.drawImage(canvas, 0, 0);
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1;
    ctx.drawImage(history, 0, 0);
    ctx.restore();
  }

  applyWebgl(gl: WebGL2RenderingContext, alpha: number): void {
    const w = gl.drawingBufferWidth;
    const h = gl.drawingBufferHeight;
    if (w < 1 || h < 1) return;
    if (
      !this.ensureGl(gl, w, h) ||
      !this.program ||
      !this.vao ||
      !this.historyTex ||
      !this.currentTex
    ) {
      return;
    }
    // Shader kernels unbind their VAO and may leave a sim FBO bound. Capture
    // and mix against the default framebuffer with our own empty VAO.
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    if (alpha >= 1) {
      this.captureWebgl(gl);
      return;
    }
    gl.bindTexture(gl.TEXTURE_2D, this.currentTex);
    gl.copyTexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 0, 0, w, h, 0);
    if (!this.primedGl) {
      gl.bindTexture(gl.TEXTURE_2D, this.historyTex);
      gl.copyTexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 0, 0, w, h, 0);
      this.primedGl = true;
      return;
    }
    gl.useProgram(this.program);
    gl.uniform1i(this.locHistory, 0);
    gl.uniform1i(this.locCurrent, 1);
    gl.uniform1f(this.locAlpha, alpha);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.historyTex);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, this.currentTex);
    gl.viewport(0, 0, w, h);
    gl.disable(gl.BLEND);
    gl.disable(gl.DEPTH_TEST);
    gl.bindVertexArray(this.vao);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.bindVertexArray(null);
    gl.bindTexture(gl.TEXTURE_2D, this.historyTex);
    gl.copyTexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 0, 0, w, h, 0);
    gl.activeTexture(gl.TEXTURE0);
  }

  dispose(): void {
    this.history2d = null;
    this.history2dCtx = null;
    this.primed2d = false;
    if (this.gl) {
      if (this.program) this.gl.deleteProgram(this.program);
      if (this.vao) this.gl.deleteVertexArray(this.vao);
      if (this.historyTex) this.gl.deleteTexture(this.historyTex);
      if (this.currentTex) this.gl.deleteTexture(this.currentTex);
    }
    this.gl = null;
    this.program = null;
    this.vao = null;
    this.historyTex = null;
    this.currentTex = null;
    this.primedGl = false;
  }

  private capture2d(canvas: HTMLCanvasElement): void {
    const w = canvas.width;
    const h = canvas.height;
    const history = this.ensure2d(w, h);
    const hctx = this.history2dCtx;
    if (!history || !hctx || w < 1 || h < 1) return;
    hctx.globalAlpha = 1;
    hctx.drawImage(canvas, 0, 0);
    this.primed2d = true;
  }

  private captureWebgl(gl: WebGL2RenderingContext): void {
    const w = gl.drawingBufferWidth;
    const h = gl.drawingBufferHeight;
    if (!this.ensureGl(gl, w, h) || !this.historyTex) return;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.bindTexture(gl.TEXTURE_2D, this.historyTex);
    gl.copyTexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 0, 0, w, h, 0);
    this.primedGl = true;
  }

  private ensure2d(w: number, h: number): HTMLCanvasElement | null {
    if (!this.history2d) {
      this.history2d = document.createElement("canvas");
      this.history2dCtx = this.history2d.getContext("2d", { alpha: false });
    }
    const canvas = this.history2d;
    const ctx = this.history2dCtx;
    if (!canvas || !ctx) return null;
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
      this.primed2d = false;
    }
    return canvas;
  }

  private ensureGl(gl: WebGL2RenderingContext, w: number, h: number): boolean {
    if (this.gl !== gl) {
      this.disposeGlResources();
      this.gl = gl;
      this.program = compileProgram(gl, SHUTTER_FRAG, "shutter");
      if (!this.program) return false;
      this.locHistory = gl.getUniformLocation(this.program, "uHistory");
      this.locCurrent = gl.getUniformLocation(this.program, "uCurrent");
      this.locAlpha = gl.getUniformLocation(this.program, "uAlpha");
      this.vao = gl.createVertexArray();
      this.historyTex = this.makeTex(gl);
      this.currentTex = this.makeTex(gl);
      this.texW = 0;
      this.texH = 0;
      this.primedGl = false;
    }
    if (!this.vao || !this.historyTex || !this.currentTex) return false;
    if (this.texW !== w || this.texH !== h) {
      this.allocTex(gl, this.historyTex, w, h);
      this.allocTex(gl, this.currentTex, w, h);
      this.texW = w;
      this.texH = h;
      this.primedGl = false;
    }
    return true;
  }

  private makeTex(gl: WebGL2RenderingContext): WebGLTexture | null {
    const tex = gl.createTexture();
    if (!tex) return null;
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return tex;
  }

  private allocTex(
    gl: WebGL2RenderingContext,
    tex: WebGLTexture,
    w: number,
    h: number,
  ): void {
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  }

  private disposeGlResources(): void {
    if (!this.gl) return;
    if (this.program) this.gl.deleteProgram(this.program);
    if (this.vao) this.gl.deleteVertexArray(this.vao);
    if (this.historyTex) this.gl.deleteTexture(this.historyTex);
    if (this.currentTex) this.gl.deleteTexture(this.currentTex);
    this.program = null;
    this.vao = null;
    this.historyTex = null;
    this.currentTex = null;
  }
}
