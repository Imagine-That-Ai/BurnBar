/**
 * Backdrop kernel contract.
 *
 * A "kernel" is a self-contained, swappable background renderer. The
 * {@link KernelHost} owns all DOM/lifecycle/scheduling concerns (canvas,
 * rAF, DPR, resize, visibility, reduced-motion, pointer, theme, crossfade)
 * and drives kernels purely through this interface. Adding a new backdrop is
 * "write one file that returns a `Kernel`, register it" — nothing else.
 *
 * Two substrates are supported:
 *  - `"2d"`     → host hands the kernel a {@link CanvasRenderingContext2D}
 *  - `"webgl2"` → host hands the kernel a {@link WebGL2RenderingContext}
 *
 * The host creates a fresh canvas of the matching context type per kernel, so
 * a 2D kernel and a WebGL kernel never have to share a context.
 */

import type { GlCapabilities } from "./gl/glCapabilities";
import type { GlyphField } from "../glyph/field/glyphField";

export type ThemeName = "light" | "dark";

export type KernelId =
  | "constellation"
  | "flow"
  | "aurora"
  | "mesh"
  | "moire"
  | "volumetric"
  | "lic"
  // ── Wave-2 (feat-of-engineering kernels). Append-only: never reorder/remove
  //    the ten above. Ported verbatim from the studio app's backdrop system. ──
  | "fluid-aurora"
  | "cloudfield"
  | "plasma-orbs"
  | "blobs-mesh"
  | "retro-plasma"
  | "inversion-lattice"
  | "vogel-bloom"
  | "crystal-drift"
  | "ripple-lattice"
  | "liquid-lumen"
  | "spectral-drift"
  | "mycelium-mesh"
  | "oilfield"
  | "suminagashi-drift"
  | "kinetic-stipple"
  // ── Agent 7: generative AI-to-shader pipeline kernel ──
  | "neural-bloom"
  | "agent1"
  // ── Agent 10: Aether Lattice ──
  | "aether-lattice"
  // ── Signal worlds: two-call sign emblems (Beacon searchlight / Tempest storm cell). ──
  | "bat-signal"
  | "storm-signal"
  // ── Paper-craft world: origami/kirigami/sumi/quilling on a hand-made kozo sheet. ──
  | "origami"
  // ── Diffusion worlds: ink-on-fibre chromatography + thin-film petroleum sheen. ──
  | "ink-diffusion"
  | "petroleum-sheen"
  // ── CUBELOVE voxel world: cubes forged from light in a flat canvas. ──
  // ── CUBELOVE premium: WebGPU sparse-voxel path tracer (Quarry `voxel` is its fallback). ──
  // ── Boids / Swarm Ember: GPU murmurations (WebGL2 single-pass). ──
  | "boids"
  | "swarmEmber";

/** RGB triple, channels in 0–255. */
export type RGB = [number, number, number];

/**
 * Theme-resolved color set handed to every kernel. Each kernel interprets it
 * in its own idiom, but they all draw from the same cohesive ramp so switching
 * kernels (or themes) never breaks visual identity.
 */
export interface KernelPalette {
  theme: ThemeName;
  /** Page canvas base color sitting *behind* the kernel. */
  bg: RGB;
  /** Ordered accent ramp (iris → teal → rose → gold by convention). */
  accents: RGB[];
  /** Foreground "ink" for particles/marks in this theme. */
  ink: RGB;
  /**
   * Global effect-strength multiplier (0–1). Lower in light mode so luminous
   * effects don't blow out a bright canvas. Kernels fold this into opacity.
   */
  intensity: number;
}

export type KernelSubstrate = "2d" | "webgl2" | "webgpu";

/** Any rendering context a kernel may receive (narrowed by `substrate`).
 *  WebGPU kernels receive the {@link GPUCanvasContext}; they acquire their own
 *  {@link GPUDevice} asynchronously in `init` and no-op `frame()` until ready. */
export type KernelRenderingContext =
  | CanvasRenderingContext2D
  | WebGL2RenderingContext
  | GPUCanvasContext;

/** Snapshot of host state passed to a kernel on init/resize. */
export interface KernelFrameContext {
  /** Canvas CSS size (logical px). */
  width: number;
  height: number;
  /** Device pixel ratio the backing store is scaled by. */
  dpr: number;
  theme: ThemeName;
  palette: KernelPalette;
  reducedMotion: boolean;
  /**
   * Probed WebGL2 capabilities. Absent for 2D kernels / when WebGL2 is
   * unavailable. Sim kernels read this to gate float-target renderability.
   */
  caps?: GlCapabilities;
}

/** Internal float format for a sim target. RGBA16F default: color-renderable
 *  under EXT_color_buffer_float AND linearly filterable in core WebGL2. */
export type SimFormat = "RGBA16F" | "RG16F";

/**
 * Multi-pass simulation spec — consumed ONLY by `createShaderKernel` when a
 * kernel declares `sim`. Omitted ⇒ the single-pass path (aurora/mesh) is
 * unchanged.
 */
export interface SimSpec {
  /** GLSL `vec4 simStep(vec2 uv)` — reads `uPrev` + the control block. */
  step: string;
  /** GLSL `vec4 simSeed(vec2 uv)` — reads `uv` ONLY; never samples `uPrev`. */
  seed: string;
  /** Internal format. Default "RGBA16F". */
  format?: SimFormat;
  /** Sim resolution vs display buffer. 0.5 = half-res. Default 0.5. */
  scale?: number;
  /** Substeps per displayed frame; clamped [1, 8]. Default 1. */
  stepsPerFrame?: number;
  /** Warmup steps run once on init AND per renderStatic(). Default 0. */
  settleSteps?: number;
}

/** A baked input texture (e.g. LIC blue-noise), bound as `sampler2D <name>`. */
export interface TextureSpec {
  /** Sampler name in the display shader, e.g. "uBlueNoise". */
  name: string;
  /** Baked image as a data URI (PNG). */
  dataUri: string;
  filter?: "nearest" | "linear"; // default "linear"
  wrap?: "repeat" | "clamp"; // default "repeat"
}

/** A control group a kernel opts into; the factory binds its uniforms.
 *  `"glyph"` opts into the Glyph Field contract (uGlyphField/uGlyphActive/
 *  uGlyphRect/uGlyphPhase) so a world is *shaped by* the active mark. */
export type ControlGroup = "scroll" | "impulses" | "obstacles" | "glyph";

export interface Kernel {
  readonly id: KernelId;
  readonly label: string;
  readonly substrate: KernelSubstrate;

  /**
   * Bind to a freshly created context of `substrate` type. Called once before
   * any `frame()`. May kick off async work (e.g. logo sampling) but must leave
   * the kernel renderable immediately.
   */
  init(gl: KernelRenderingContext, ctx: KernelFrameContext): void;

  /**
   * Advance simulation + render one frame.
   * @param tMs  monotonically increasing elapsed time since init (ms)
   * @param dtMs delta since previous frame (ms), already clamped by the host
   */
  frame(tMs: number, dtMs: number): void;

  /** Canvas size and/or DPR changed; backing store already resized. */
  resize(ctx: KernelFrameContext): void;

  /** Theme/palette changed at runtime (no remount). */
  setTheme(theme: ThemeName, palette: KernelPalette): void;

  /**
   * Pointer moved (CSS px relative to canvas) or left (`active === false`).
   * Optional — pointer-inert kernels can omit it.
   */
  pointer?(x: number, y: number, active: boolean): void;

  /**
   * Click on a blank area of the page (CSS px relative to canvas). The host
   * filters out clicks that land on interactive content. Optional.
   */
  click?(x: number, y: number): void;

  /**
   * A foreground GLYPH was dragged/thrown through the field at (x,y) (CSS px),
   * moving by (dx,dy) px this frame, disturbing an area of ~`radius` px with the
   * given `strength` (~0..3). Lets a dragged glyph genuinely move the underlying
   * world — the disturbance scales with the glyph's size, like the pointer but
   * area-relative. Optional; pointer-inert kernels can omit it.
   */
  wake?(x: number, y: number, dx: number, dy: number, radius: number, strength: number): void;

  /**
   * Page obstacle geometry changed — bounding rects (canvas px) of the glass
   * cards + headings the swarm should flow around. Harvested by the host on
   * resize + throttled scroll. Optional.
   */
  obstacles?(rects: { x: number; y: number; w: number; h: number }[]): void;

  /**
   * Scroll position / velocity changed. `y` is the live scroll offset (px),
   * `vy` is the smoothed, clamped scroll velocity (px/frame, positive = down).
   * `yMax` is `0` when the page isn't scrollable. Optional — scroll-inert
   * kernels can omit it. Never fired under `prefers-reduced-motion`.
   */
  scroll?(y: number, vy: number, yMax: number): void;

  /**
   * The active mark's signed distance field changed (or was cleared with
   * `null`). A glyph-coupled world uploads it to `uGlyphField` and is *shaped
   * by* the mark; a world that hasn't opted in ignores this entirely. Optional.
   */
  setGlyphField?(field: GlyphField | null): void;

  /**
   * Paint a single representative frame for `prefers-reduced-motion`. Falls
   * back to one `frame()` call if not provided.
   */
  renderStatic?(): void;

  /** Release all GL/canvas resources and listeners. */
  dispose(): void;
}

/** Factory used by the registry; keeps kernels lazily constructable. */
export type KernelFactory = () => Kernel;

/** Registry entry — drives the switcher UI and host construction. */
export interface KernelDescriptor {
  id: KernelId;
  label: string;
  /** One-line caption shown under the switcher. */
  blurb: string;
  substrate: KernelSubstrate;
  create: KernelFactory;
  /** If true, the host resolves to `fallbackId` when float render-targets are
   *  unsupported (probed before instantiation) — never a black canvas. */
  requiresFloatTex?: boolean;
  /** If true, the host resolves to `fallbackId` when WebGPU (`navigator.gpu`)
   *  is unavailable — the premium voxel tier degrades to its WebGL fallback. */
  requiresWebGPU?: boolean;
  /** Fallback world when float renderability is missing (default DEFAULT_KERNEL_ID). */
  fallbackId?: KernelId;
}
