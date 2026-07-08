/**
 * GL capability probe + float-format selection for multi-pass sim kernels
 * (caustics, wave).
 *
 * **D1 — gating is by PROVEN RENDERABILITY, not extension-string presence.**
 * `detectGlCapabilities` creates a real 1×1 `RGBA16F` framebuffer and requires
 * `FRAMEBUFFER_COMPLETE`. The `EXT_color_buffer_float` string is necessary but
 * NOT sufficient (some drivers expose it yet fail completeness — PavelDoGreat's
 * WebGL-Fluid-Simulation probes for exactly this reason). The probe runs on the
 * live engine context type, so the host can resolve a `requiresFloatTex` kernel
 * to its `fallbackId` *before* instantiation — never black.
 *
 * `pickSimFormat` is pure (reads GL enum constants off the passed context) so it
 * is unit-testable against a mock.
 */

/** Probed GPU capabilities a sim kernel may need. */
export interface GlCapabilities {
  /** RGBA16F is color-renderable AND framebuffer-complete (PROBED). */
  colorBufferFloat: boolean;
  /** EXT_float_blend — only needed if a future sim additively blends. */
  floatBlend: boolean;
}

/** The "no float" capability set — used when WebGL2 is absent or probing fails. */
export const NO_FLOAT_CAPS: GlCapabilities = {
  colorBufferFloat: false,
  floatBlend: false,
};

/** Concrete GL enums + capability flags for a chosen sim texture format. */
export interface SimTextureFormat {
  /** gl.RGBA16F | gl.RG16F */
  internalFormat: number;
  /** gl.RGBA | gl.RG */
  format: number;
  /** gl.HALF_FLOAT */
  type: number;
  /** LINEAR is allowed (16F is core-filterable in WebGL2). */
  filterable: boolean;
  /** True iff `caps.colorBufferFloat` (the probed gate). */
  renderable: boolean;
}

/**
 * Probe RGBA16F renderability on the given context (D1). Creates a 1×1 float
 * FBO via `texStorage2D`, requires `FRAMEBUFFER_COMPLETE`, and deletes the
 * scratch resources regardless of outcome. Also probes `EXT_float_blend`
 * (only relevant for future additive-into-float sims).
 */
export function detectGlCapabilities(gl: WebGL2RenderingContext): GlCapabilities {
  const hasExt = !!gl.getExtension("EXT_color_buffer_float");
  let renderable = false;
  if (hasExt) {
    const tex = gl.createTexture();
    const fbo = gl.createFramebuffer();
    if (tex && fbo) {
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, 1, 1);
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
      gl.framebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0,
        gl.TEXTURE_2D,
        tex,
        0
      );
      renderable =
        gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE;
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    }
    if (tex) gl.deleteTexture(tex);
    if (fbo) gl.deleteFramebuffer(fbo);
  }
  return {
    colorBufferFloat: renderable,
    floatBlend: !!gl.getExtension("EXT_float_blend"),
  };
}

/**
 * Map a requested sim format + probed capabilities to concrete GL enums +
 * capability flags. Pure with respect to GL state (no allocations/binds).
 *
 * RGBA16F / RG16F are both **core-filterable in WebGL2** (no
 * `OES_texture_float_linear` needed), so `filterable` is always `true`;
 * `renderable` tracks the probed `colorBufferFloat` gate. There is intentionally
 * no `RGBA8` case (D7): on no-float hardware the host resolves to a 2D fallback
 * kernel rather than running a degraded packed-float PDE.
 */
export function pickSimFormat(
  gl: WebGL2RenderingContext,
  requested: "RGBA16F" | "RG16F",
  caps: GlCapabilities
): SimTextureFormat {
  if (requested === "RG16F") {
    return {
      internalFormat: gl.RG16F,
      format: gl.RG,
      type: gl.HALF_FLOAT,
      filterable: true,
      renderable: caps.colorBufferFloat,
    };
  }
  return {
    internalFormat: gl.RGBA16F,
    format: gl.RGBA,
    type: gl.HALF_FLOAT,
    filterable: true,
    renderable: caps.colorBufferFloat,
  };
}
