/**
 * BackdropEngine — framework-agnostic owner of the kernel runtime.
 *
 * Responsibilities (everything a kernel should NOT have to think about):
 *  - canvas creation/teardown per kernel (2D or WebGL2, the right context type)
 *  - a single monotonic rAF clock; pause on offscreen / hidden tab
 *  - DPR-aware sizing via ResizeObserver
 *  - pointer routing (window-level, mapped to canvas space)
 *  - prefers-reduced-motion (static frame, no loop)
 *  - crossfade transitions when switching kernels (both run during the fade)
 *  - graceful WebGL2 fallback to a 2D kernel
 *
 * The React layer ({@link KernelHost}) is a thin wrapper that constructs one
 * engine and forwards prop changes. Kept as a class so it is unit-testable and
 * has zero React coupling.
 */

import type { GlyphField } from "../glyph/field/glyphField";
import { detectGlCapabilities, type GlCapabilities } from "./gl/glCapabilities";
import { resolvePalette } from "./palette";
import {
  BackdropReadabilityStabilizer,
  fallbackReadabilityProfile,
  type BackdropReadabilityProfile,
} from "./readability";
import type { SwarmEmberKernelOptions } from "./kernels/swarmEmberKernel";
// Eager import: createSlot() is synchronous and must return a Kernel immediately,
// so the options-override path for swarmEmber can't use a dynamic import(). The
// registry's lazyKernel path handles the default (no-options) case; this value
// import is only reached when swarmEmberOptions is set (linux-desktop dashboard).
import { createSwarmEmberKernel } from "./kernels/swarmEmberKernel";
import {
  DEFAULT_KERNEL_ID,
  getKernelDescriptor,
  resolveKernelResolution,
} from "./registry";
import type {
  Kernel,
  KernelFrameContext,
  KernelId,
  KernelPalette,
  KernelResolution,
  KernelSubstrate,
  ThemeName,
} from "./types";

const FADE_MS = 700;
const READABILITY_SAMPLE_INTERVAL_MS = 500;
const READABILITY_SAMPLE_POINTS = [0.14, 0.5, 0.86] as const;
const REGION_SAMPLE_POINTS = [0.18, 0.5, 0.82] as const;
const READABILITY_BUFFER_WIDTH = 24;
const READABILITY_BUFFER_HEIGHT = 16;
// Fragment-shader kernels are soft, full-screen fields — high DPR is wasted
// detail at real cost, so cap WebGL lower than the crisp 2D particle canvases.
const DPR_CAP: Record<KernelSubstrate, number> = {
  "2d": 2,
  webgl2: 1.2,
  webgpu: 1,
};

interface Slot {
  id: KernelId;
  canvas: HTMLCanvasElement;
  kernel: Kernel;
  substrate: KernelSubstrate;
  context: CanvasRenderingContext2D | WebGL2RenderingContext | GPUCanvasContext | null;
  outgoing: boolean;
  disposeTimer: number | null;
  contextLost: boolean;
  onContextLost: ((event: Event) => void) | null;
  onContextRestored: (() => void) | null;
}

export interface BackdropEngineOptions {
  theme: ThemeName;
  initialKernel?: KernelId;
  /** When set, used instead of {@link resolvePalette} (e.g. Linux shell skin accents). */
  palette?: KernelPalette;
  /** Host overrides when mounting `swarmEmber` (e.g. Linux dashboard cinematic pace). */
  swarmEmberOptions?: SwarmEmberKernelOptions;
  /** Optional render cap for low-power/native preview hosts. Zero is uncapped. */
  maxFps?: number;
  /** Notified with the kernel actually shown (may differ on GL fallback). */
  onResolve?: (id: KernelId) => void;
  /** Bounded-cadence WCAG profile derived from the frames actually rendered. */
  onReadability?: (profile: BackdropReadabilityProfile) => void;
  /** Viewport-space bounds for text-bearing areas that expose the canvas. */
  readabilityRegions?: () => readonly DOMRectReadOnly[];
  /** Notified with the requested-vs-resolved capability receipt. */
  onStatus?: (status: KernelResolution) => void;
  /**
   * Deterministic host profile for performance certification. Production
   * callers leave this unset so the engine follows the user's OS preference.
   */
  reducedMotionOverride?: boolean;
}

export interface BackdropRuntimeState {
  hostVisible: boolean;
  renderLoopScheduled: boolean;
  reducedMotion: boolean;
  resolvedKernel: KernelId;
}

function detectWebgl2(): { supported: boolean; caps: GlCapabilities } {
  try {
    const c = document.createElement("canvas");
    const gl = c.getContext("webgl2");
    if (!gl)
      return {
        supported: false,
        caps: { colorBufferFloat: false, floatBlend: false },
      };
    const caps = detectGlCapabilities(gl);
    gl.getExtension("WEBGL_lose_context")?.loseContext();
    return { supported: true, caps };
  } catch {
    return {
      supported: false,
      caps: { colorBufferFloat: false, floatBlend: false },
    };
  }
}

export class BackdropEngine {
  readonly glSupported: boolean;
  private readonly glCaps: GlCapabilities;

  private container: HTMLElement;
  private slots: Slot[] = [];
  private activeId: KernelId;
  /** Latest user request, kept separately from the resolved/visible slot. */
  private requestedKernelId: KernelId;
  private theme: ThemeName;
  private palette: KernelPalette;
  private swarmEmberOptions?: SwarmEmberKernelOptions;
  private onResolve?: (id: KernelId) => void;
  private onReadability?: (profile: BackdropReadabilityProfile) => void;
  private readabilityRegions?: () => readonly DOMRectReadOnly[];
  private readability = new BackdropReadabilityStabilizer();
  private readabilityCanvas: HTMLCanvasElement | null = null;
  private readabilityContext: CanvasRenderingContext2D | null = null;
  private readabilityWorker: Worker | null | undefined;
  private readabilityWorkerURL: string | null = null;
  private readabilityWorkerRequest = 0;
  private readabilityWorkerPending = new Map<
    number,
    { resolve: (rgba: Uint8ClampedArray | null) => void; timeout: number }
  >();
  private lastReadabilityProfile: BackdropReadabilityProfile | null = null;
  private lastReadabilitySample = -Infinity;
  private readabilitySampling = false;
  private readabilityResampleRequested = false;
  private destroyed = false;
  private onStatus?: (status: KernelResolution) => void;

  private width = 0;
  private height = 0;
  private tMs = 0;
  private lastNow = 0;
  private raf: number | null = null;

  private visible = true;
  private pageVisible = true;
  /** A lost WebGL slot should be retried once the window is visible again. */
  private retryRequestedKernelOnVisible = false;
  /** Native-host visibility (window occlusion/minimize/app-hide), driven by
   *  the embedder via {@link setHostVisible}. Browsers never touch this. */
  private hostVisible = true;
  private reducedMotion = false;
  private maxFps = 0;
  private lastFrameAdvanceAt = 0;

  private pointer = { x: 0, y: 0, active: false };

  /** The active mark's SDF, owned here so it survives world crossfades and is
   *  handed to every slot (current + newcomer) — spec §2.2. */
  private glyphField: GlyphField | null = null;

  private scroll = { y: 0, vy: 0, yMax: 0 };
  private scrollDelta = 0;
  private lastHarvest = -1e9;

  private resizeObs: ResizeObserver | null = null;
  private intersectionObs: IntersectionObserver | null = null;
  private mql: MediaQueryList | null = null;
  // Deferred initial-harvest handles, tracked so destroy() can cancel them and
  // never reference a torn-down engine (matters under React StrictMode remounts).
  private initialHarvestRaf: number | null = null;
  private initialHarvestTimer: number | null = null;
  private initialReadabilityRaf: number | null = null;

  constructor(container: HTMLElement, opts: BackdropEngineOptions) {
    this.container = container;
    const detected = detectWebgl2();
    this.glSupported = detected.supported;
    this.glCaps = detected.caps;
    this.theme = opts.theme;
    this.palette = opts.palette ?? resolvePalette(opts.theme);
    this.swarmEmberOptions = opts.swarmEmberOptions;
    this.onResolve = opts.onResolve;
    this.onReadability = opts.onReadability;
    this.readabilityRegions = opts.readabilityRegions;
    this.onStatus = opts.onStatus;
    this.activeId = opts.initialKernel ?? DEFAULT_KERNEL_ID;
    this.requestedKernelId = this.activeId;
    this.maxFps =
      opts.maxFps && opts.maxFps > 0 ? Math.min(opts.maxFps, 60) : 0;

    this.reducedMotion = opts.reducedMotionOverride ?? (
      typeof window !== "undefined" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    );

    const rect = container.getBoundingClientRect();
    this.width = rect.width || window.innerWidth;
    this.height = rect.height || window.innerHeight;

    this.mountInitial();
    this.attachObservers();
    if (!this.reducedMotion) {
      this.startLoop();
    } else {
      this.scheduleReadabilitySample();
    }
  }

  // ── Public API ─────────────────────────────────────────────

  setKernel(id: KernelId): void {
    this.transitionKernel(id, false);
  }

  /**
   * Mount a request, optionally rebuilding an otherwise matching active slot.
   * The force path is used after a compositor-driven WebGL context loss: the
   * resolved id can still equal `activeId` even though the existing slot is
   * no longer renderable.
   */
  private transitionKernel(id: KernelId, force: boolean): void {
    this.requestedKernelId = id;
    const requested = this.resolveKernel(id);
    if (
      !force &&
      requested.resolvedId === this.activeId &&
      this.slots.some((s) => s.id === requested.resolvedId && !s.outgoing && !s.contextLost)
    ) {
      // A different WebGL2 request can resolve to the already-mounted 2D
      // default. Still publish the request so the UI does not claim that the
      // requested shader is running when it is actually using the fallback.
      this.publishResolution(requested);
      return;
    }
    // Finalize any still-fading slots, then retire the current ones.
    this.finalizeOutgoing();
    for (const slot of this.slots) {
      slot.outgoing = true;
      slot.canvas.style.opacity = "0";
      slot.disposeTimer = window.setTimeout(
        () => this.disposeSlot(slot),
        FADE_MS + 80,
      );
    }

    const slot = this.createSlot(requested.resolvedId);
    this.activeId = slot.id;
    if (slot.id === requested.resolvedId && slot.substrate === requested.resolvedSubstrate) {
      this.retryRequestedKernelOnVisible = false;
    }
    this.publishResolution(this.withSlotResolution(requested, slot));
    this.harvestObstacles(true); // a freshly-switched kernel gets current geometry
    this.emitPaletteReadability();

    // A context can disappear between the capability probe and the switch
    // (common when a WebKit/VM compositor is suspended). `createSlot` then
    // returns the visible 2D default. Reveal that fallback synchronously so a
    // throttled or backgrounded rAF cannot leave every canvas at opacity:0.
    const contextFallback = slot.id !== requested.resolvedId;
    if (contextFallback) slot.canvas.style.opacity = "1";

    // Fade the newcomer in on the next frame (lets the transition apply).
    requestAnimationFrame(() => {
      if (slot.canvas.parentNode) slot.canvas.style.opacity = "1";
    });
    if (this.reducedMotion) slot.kernel.renderStatic?.();
    this.scheduleReadabilitySample();
  }

  setTheme(theme: ThemeName): void {
    if (theme === this.theme) return;
    this.theme = theme;
    this.palette = resolvePalette(theme);
    for (const slot of this.slots) {
      slot.kernel.setTheme(theme, this.palette);
      if (this.reducedMotion) slot.kernel.renderStatic?.();
    }
    this.readability.reset();
    this.emitPaletteReadability();
    this.scheduleReadabilitySample();
  }

  /**
   * Re-resolve the current theme's palette (the user edited their custom color
   * scheme) and push it to every live kernel, so all worlds recolor instantly
   * without a remount. A no-op visual change is harmless.
   */
  refreshPalette(): void {
    this.palette = resolvePalette(this.theme);
    for (const slot of this.slots) {
      slot.kernel.setTheme(this.theme, this.palette);
      if (this.reducedMotion) slot.kernel.renderStatic?.();
    }
    this.emitPaletteReadability();
    this.scheduleReadabilitySample();
  }

  /**
   * Push a resolved palette to every live kernel without touching the global
   * custom-palette store (shell skin, previews, etc.).
   */
  setPalette(palette: KernelPalette): void {
    this.palette = {
      theme: this.theme,
      bg: [...palette.bg] as KernelPalette["bg"],
      accents: palette.accents.map(
        (a) => [...a] as KernelPalette["accents"][0],
      ),
      ink: [...palette.ink] as KernelPalette["ink"],
      intensity: palette.intensity,
    };
    for (const slot of this.slots) {
      slot.kernel.setTheme(this.theme, this.palette);
      if (this.reducedMotion) slot.kernel.renderStatic?.();
    }
    this.emitPaletteReadability();
    this.scheduleReadabilitySample();
  }

  getResolvedKernel(): KernelId {
    return this.activeId;
  }

  /** Runtime truth used by native hosts to confirm that occlusion commands
   *  reached the actual engine rather than merely reaching the WKWebView. */
  getRuntimeState(): BackdropRuntimeState {
    return {
      hostVisible: this.hostVisible,
      renderLoopScheduled: this.raf !== null,
      reducedMotion: this.reducedMotion,
      resolvedKernel: this.activeId,
    };
  }

  /**
   * Native embedders (the macOS/iOS WKWebView backdrop) call this when the
   * hosting window's occlusion state changes. `document.hidden` never fires
   * for a window that is merely covered by another window or minimized, so
   * without this hook the rAF loop keeps burning GPU/CPU behind fully
   * occluded windows. Fully stops the loop (not just early-returns) so an
   * occluded backdrop costs ~0; restarting is seamless — same pattern as the
   * reduced-motion toggle.
   */
  setHostVisible(hostVisible: boolean): void {
    if (this.hostVisible === hostVisible) return;
    this.hostVisible = hostVisible;
    if (!hostVisible) {
      if (this.raf !== null) {
        cancelAnimationFrame(this.raf);
        this.raf = null;
      }
      // Readability sampling uses its own one-shot rAF. Leaving that callback
      // armed while the host is occluded defeats the zero-work contract and
      // leaves a stale callback behind for every pause/resume cycle.
      if (this.initialReadabilityRaf !== null) {
        cancelAnimationFrame(this.initialReadabilityRaf);
        this.initialReadabilityRaf = null;
      }
    } else if (this.raf === null && !this.reducedMotion) {
      this.startLoop();
      this.scheduleReadabilitySample();
    }
  }

  /** Cap native/embedded previews without changing the browser default. */
  setMaxFps(fps: number): void {
    this.maxFps = Number.isFinite(fps) && fps > 0 ? Math.min(fps, 60) : 0;
    this.lastFrameAdvanceAt = performance.now();
  }

  /** A foreground glyph was dragged/thrown through the field — forward to the
   *  active kernel so the underlying world genuinely reacts (area-relative). */
  wake(
    x: number,
    y: number,
    dx: number,
    dy: number,
    radius: number,
    strength: number,
  ): void {
    for (const slot of this.slots) {
      if (!slot.outgoing) slot.kernel.wake?.(x, y, dx, dy, radius, strength);
    }
  }

  /** Bind the active mark's signed distance field (or clear with `null`). The
   *  engine owns it so it persists across world switches and is replayed to
   *  every newly mounted slot — a glyph-coupled world is *shaped by* the mark;
   *  a world that hasn't opted in ignores it (spec §2.2). */
  setGlyphField(field: GlyphField | null): void {
    this.glyphField = field;
    for (const slot of this.slots) slot.kernel.setGlyphField?.(field);
  }

  destroy(): void {
    this.destroyed = true;
    if (this.raf !== null) cancelAnimationFrame(this.raf);
    if (this.initialHarvestRaf !== null)
      cancelAnimationFrame(this.initialHarvestRaf);
    if (this.initialHarvestTimer !== null)
      clearTimeout(this.initialHarvestTimer);
    if (this.initialReadabilityRaf !== null)
      cancelAnimationFrame(this.initialReadabilityRaf);
    this.resizeObs?.disconnect();
    this.intersectionObs?.disconnect();
    document.removeEventListener("visibilitychange", this.onVisibility);
    window.removeEventListener("pointermove", this.onPointerMove);
    window.removeEventListener("pointerout", this.onPointerOut);
    window.removeEventListener("scroll", this.onScroll, true);
    window.removeEventListener("click", this.onClick);
    this.mql?.removeEventListener("change", this.onReducedMotionChange);
    for (const slot of [...this.slots]) this.disposeSlot(slot);
    this.slots = [];
    this.readabilityCanvas = null;
    this.readabilityContext = null;
    this.readabilityWorker?.terminate();
    if (this.readabilityWorkerURL) URL.revokeObjectURL(this.readabilityWorkerURL);
    for (const pending of this.readabilityWorkerPending.values()) {
      clearTimeout(pending.timeout);
      pending.resolve(null);
    }
    this.readabilityWorkerPending.clear();
    this.readabilityWorker = null;
    this.readabilityWorkerURL = null;
  }

  // ── Slot lifecycle ─────────────────────────────────────────

  private resolveKernel(id: KernelId): KernelResolution {
    const base = resolveKernelResolution(id, this.glCaps, this.glSupported);
    const desc = getKernelDescriptor(id);
    // WebGPU premium tier degrades to its WebGL fallback when navigator.gpu is
    // absent (older OS/browser) — same "never black" contract.
    if (
      base.reason === "native" &&
      (desc.requiresWebGPU || desc.substrate === "webgpu") &&
      typeof navigator !== "undefined" &&
      !("gpu" in navigator)
    ) {
      const fallbackId = desc.fallbackId ?? DEFAULT_KERNEL_ID;
      const fallback = getKernelDescriptor(fallbackId);
      return {
        ...base,
        resolvedId: fallbackId,
        resolvedSubstrate: fallback.substrate,
        reason: "webgpu-unavailable",
        fallback: fallbackId !== id,
      };
    }
    return base;
  }

  private withSlotResolution(requested: KernelResolution, slot: Slot): KernelResolution {
    if (slot.id === requested.resolvedId) return requested;
    return {
      ...requested,
      resolvedId: slot.id,
      resolvedSubstrate: slot.substrate,
      reason: "context-unavailable",
      fallback: slot.id !== requested.requestedId,
    };
  }

  private publishResolution(status: KernelResolution): void {
    this.onStatus?.(status);
    this.onResolve?.(status.resolvedId);
  }

  private mountInitial(): void {
    const requested = this.resolveKernel(this.activeId);
    const slot = this.createSlot(requested.resolvedId);
    this.activeId = slot.id;
    slot.canvas.style.opacity = "1";
    this.publishResolution(this.withSlotResolution(requested, slot));
    if (this.reducedMotion) slot.kernel.renderStatic?.();
  }

  private frameCtx(substrate: KernelSubstrate): KernelFrameContext {
    const dpr = Math.min(window.devicePixelRatio || 1, DPR_CAP[substrate]);
    return {
      width: this.width,
      height: this.height,
      dpr,
      theme: this.theme,
      palette: this.palette,
      reducedMotion: this.reducedMotion,
      caps: this.glCaps,
    };
  }

  private sizeCanvas(slot: Slot): void {
    const dpr = Math.min(window.devicePixelRatio || 1, DPR_CAP[slot.substrate]);
    slot.canvas.width = Math.max(1, Math.round(this.width * dpr));
    slot.canvas.height = Math.max(1, Math.round(this.height * dpr));
    slot.canvas.style.width = `${this.width}px`;
    slot.canvas.style.height = `${this.height}px`;
  }

  private createSlot(id: KernelId, depth = 0): Slot {
    const desc = getKernelDescriptor(id);
    const kernel: Kernel =
      id === "swarmEmber" && this.swarmEmberOptions
        ? createSwarmEmberKernel(this.swarmEmberOptions)
        : desc.create();
    const substrate = kernel.substrate;

    const canvas = document.createElement("canvas");
    canvas.setAttribute("aria-hidden", "true");
    canvas.style.cssText =
      "position:absolute;inset:0;display:block;opacity:0;" +
      `transition:opacity ${FADE_MS}ms ease;will-change:opacity;`;
    this.container.appendChild(canvas);

    const slot: Slot = {
      id: kernel.id,
      canvas,
      kernel,
      substrate,
      context: null,
      outgoing: false,
      disposeTimer: null,
      contextLost: false,
      onContextLost: null,
      onContextRestored: null,
    };
    this.sizeCanvas(slot);
    // Track the slot BEFORE init so every failure path can dispose it cleanly
    // (removes the canvas, runs kernel.dispose(), untracks) — no orphans.
    this.slots.push(slot);

    let ctx:
      | CanvasRenderingContext2D
      | WebGL2RenderingContext
      | GPUCanvasContext
      | null = null;
    if (substrate === "webgpu") {
      // The kernel acquires its own GPUDevice asynchronously and configures
      // this context in init(); the host only hands over the canvas context.
      ctx = canvas.getContext("webgpu");
      if (!ctx) {
        // WebGPU isn't vendored in the console; degrade to the default kernel.
        // (No curated kernel uses the webgpu substrate, so this is dead-safe.)
        this.disposeSlot(slot);
        return depth < 2 ? this.createSlot(DEFAULT_KERNEL_ID, depth + 1) : slot;
      }
    } else if (substrate === "webgl2") {
      ctx = canvas.getContext("webgl2", {
        alpha: true,
        antialias: false,
        depth: false,
        stencil: false,
        premultipliedAlpha: true,
        // Ambient backdrops don't need dGPU clocks: "low-power" renders the
        // exact same frames on the efficiency GPU tier and saves real battery
        // ("high-performance" forces higher clocks / the discrete GPU on Macs).
        powerPreference: "low-power",
        preserveDrawingBuffer: false,
      });
      if (!ctx) {
        // GL went away mid-session — fall back to the default 2D kernel.
        this.disposeSlot(slot);
        return depth < 2 ? this.createSlot(DEFAULT_KERNEL_ID, depth + 1) : slot;
      }
    } else {
      ctx = canvas.getContext("2d", { alpha: true });
      if (!ctx) {
        // 2D unavailable is catastrophic; tear down and return an inert slot.
        this.disposeSlot(slot);
        return slot;
      }
    }

    slot.context = ctx;
    if (substrate === "webgl2") {
      // The kernel also listens so it can rebuild its own programs. The host
      // listener is deliberately attached first and owns the user-visible
      // fallback: a compositor can lose a context while rAF is throttled, so
      // waiting for the next frame would leave the whole backdrop transparent.
      slot.onContextLost = (event: Event) => {
        event.preventDefault();
        slot.contextLost = true;
        if (!slot.outgoing && this.slots.includes(slot)) {
          this.retryRequestedKernelOnVisible = true;
          this.transitionKernel(this.requestedKernelId, true);
        }
      };
      slot.onContextRestored = () => {
        slot.contextLost = false;
      };
      canvas.addEventListener("webglcontextlost", slot.onContextLost, false);
      canvas.addEventListener("webglcontextrestored", slot.onContextRestored, false);
    }

    try {
      kernel.init(ctx, this.frameCtx(substrate));
    } catch (err) {
      // A kernel that throws on init must never take the backdrop down with
      // it — degrade to the 2D default so the field is never black.
      // Constant format string: `id` is caller-supplied, and console.* treats its
      // first argument as a format string — an id containing "%s" would swallow
      // `err` and hide the very failure this line exists to report.
      console.error("[backdrop] %s init failed — falling back to %s:", id, DEFAULT_KERNEL_ID, err);
      this.disposeSlot(slot);
      return depth < 2 ? this.createSlot(DEFAULT_KERNEL_ID, depth + 1) : slot;
    }
    // Replay the live field so a newly mounted/crossfading world inherits the
    // active mark (it survives switches — spec §2.2).
    if (this.glyphField) kernel.setGlyphField?.(this.glyphField);
    return slot;
  }

  private disposeSlot(slot: Slot): void {
    if (slot.disposeTimer !== null) {
      clearTimeout(slot.disposeTimer);
      slot.disposeTimer = null;
    }
    if (slot.onContextLost) {
      slot.canvas.removeEventListener("webglcontextlost", slot.onContextLost);
      slot.onContextLost = null;
    }
    if (slot.onContextRestored) {
      slot.canvas.removeEventListener("webglcontextrestored", slot.onContextRestored);
      slot.onContextRestored = null;
    }
    try {
      slot.kernel.dispose();
    } catch {
      /* ignore teardown errors */
    }
    // Deterministically release the GL context the engine created for this
    // slot. Shader kernels lose their own context in dispose(), but a LAZY
    // kernel disposed before its chunk resolves never constructs the real
    // kernel — its dispose() is a no-op and the context would leak until GC.
    // Under rapid kernel switching (theme flipping) those leaks pile toward
    // the browser's per-page context budget and get the LIVE context killed.
    // loseContext() on an already-lost context is a no-op, so this is safe to
    // do unconditionally.
    if (slot.substrate === "webgl2" && slot.context) {
      (slot.context as WebGL2RenderingContext)
        .getExtension("WEBGL_lose_context")
        ?.loseContext();
    }
    if (slot.canvas.parentNode) slot.canvas.parentNode.removeChild(slot.canvas);
    this.slots = this.slots.filter((s) => s !== slot);
  }

  private finalizeOutgoing(): void {
    for (const slot of [...this.slots]) {
      if (slot.outgoing) this.disposeSlot(slot);
    }
  }

  // ── Loop ───────────────────────────────────────────────────

  private startLoop(): void {
    this.lastNow = performance.now();
    const loop = (now: number) => {
      this.raf = requestAnimationFrame(loop);
      if (!this.visible || !this.pageVisible || !this.hostVisible) {
        this.lastNow = now;
        this.lastFrameAdvanceAt = now;
        return;
      }
      if (this.maxFps > 0) {
        const minimumInterval = 1000 / this.maxFps;
        if (now - this.lastFrameAdvanceAt < minimumInterval) return;
        this.lastFrameAdvanceAt = now;
      }
      const dt = Math.min(now - this.lastNow, this.maxFps > 0 ? 100 : 32);
      this.lastNow = now;
      this.tMs += dt;

      // Fold raw scroll delta into a smoothed, clamped velocity, then decay.
      // When scrolling stops the velocity trails off over ~130ms for a funky
      // afterglow without lagging the wind itself.
      this.scroll.vy = this.scroll.vy * 0.82 + this.scrollDelta * 0.18;
      this.scrollDelta = 0;
      if (this.scroll.vy > 120) this.scroll.vy = 120;
      else if (this.scroll.vy < -120) this.scroll.vy = -120;
      // Snap to rest under a deadband. Without this, float decay never reaches
      // exactly 0 and scroll() would dispatch every frame forever on any
      // scrollable page. The 0.05 threshold is sub-pixel and imperceptible.
      if (Math.abs(this.scroll.vy) < 0.05) {
        this.scroll.vy = 0;
      }
      if (this.scroll.vy !== 0) {
        for (const slot of this.slots) {
          slot.kernel.scroll?.(this.scroll.y, this.scroll.vy, this.scroll.yMax);
        }
      }

      for (const slot of this.slots) {
        slot.kernel.frame(this.tMs, dt);
      }
      if (now - this.lastReadabilitySample >= READABILITY_SAMPLE_INTERVAL_MS) {
        void this.emitReadability(now);
      }
    };
    this.raf = requestAnimationFrame(loop);
  }

  // ── Adaptive foreground sampling ──────────────────────────

  private emitPaletteReadability(): void {
    if (!this.onReadability) return;
    const profile = this.readability.update({
      samples: [this.palette.bg, ...this.palette.accents, this.palette.ink],
      source: "palette",
      nowMs: performance.now(),
    });
    this.lastReadabilityProfile = profile;
    this.onReadability(profile);
  }

  private scheduleReadabilitySample(): void {
    if (!this.hostVisible || !this.onReadability || this.initialReadabilityRaf !== null) return;
    this.initialReadabilityRaf = requestAnimationFrame((now) => {
      this.initialReadabilityRaf = null;
      void this.emitReadability(now, true);
    });
  }

  private async emitReadability(now: number, force = false): Promise<void> {
    if (!this.onReadability) return;
    if (!force && now - this.lastReadabilitySample < READABILITY_SAMPLE_INTERVAL_MS) return;
    if (this.readabilitySampling) {
      this.readabilityResampleRequested = true;
      return;
    }
    this.readabilitySampling = true;
    this.lastReadabilitySample = now;

    try {
      const result = await this.readabilitySamples();
      if (this.destroyed) return;
      const baseProfile = result.samples.length > 0
        ? this.readability.update({ samples: result.samples, source: "canvas", nowMs: now })
        : fallbackReadabilityProfile(this.palette);
      const profile = {
        ...baseProfile,
        samplingDurationMs: result.blockingDurationMs,
      };

      const previous = this.lastReadabilityProfile;
      const materiallyChanged =
        !previous ||
        previous.tone !== profile.tone ||
        previous.source !== profile.source ||
        Math.abs(previous.scrimOpacity - profile.scrimOpacity) >= 0.0125 ||
        Math.abs(previous.minLuminance - profile.minLuminance) >= 0.025 ||
        Math.abs(previous.maxLuminance - profile.maxLuminance) >= 0.025;
      if (!materiallyChanged) return;
      this.lastReadabilityProfile = profile;
      this.onReadability(profile);
    } finally {
      this.readabilitySampling = false;
      if (this.readabilityResampleRequested && !this.destroyed) {
        this.readabilityResampleRequested = false;
        this.lastReadabilitySample = -Infinity;
        this.scheduleReadabilitySample();
      }
    }
  }

  private async readabilitySamples(): Promise<{
    samples: KernelPalette["accents"];
    blockingDurationMs: number;
  }> {
    const samples: KernelPalette["accents"] = [];
    const regionPoints = this.readabilityRegionPoints();
    let blockingDurationMs = 0;
    for (const slot of this.slots) {
      const result = await this.readSlotSamples(slot, regionPoints);
      samples.push(...result.samples);
      blockingDurationMs += result.blockingDurationMs;
    }
    return { samples, blockingDurationMs };
  }

  private readabilityRegionPoints(): Array<readonly [number, number]> {
    const regions = this.readabilityRegions?.() ?? [];
    if (regions.length === 0) {
      return READABILITY_SAMPLE_POINTS.flatMap((y) =>
        READABILITY_SAMPLE_POINTS.map((x) => [x, y] as const),
      );
    }

    const containerRect = this.container.getBoundingClientRect();
    const width = Math.max(1, containerRect.width);
    const height = Math.max(1, containerRect.height);
    return regions.slice(0, 4).flatMap((region) =>
      REGION_SAMPLE_POINTS.map((unit, index) => {
        const crossUnit = REGION_SAMPLE_POINTS[REGION_SAMPLE_POINTS.length - 1 - index];
        const x = region.left + region.width * unit - containerRect.left;
        const y = region.top + region.height * crossUnit - containerRect.top;
        return [Math.min(1, Math.max(0, x / width)), Math.min(1, Math.max(0, y / height))] as const;
      }),
    );
  }

  private async readSlotSamples(
    slot: Slot,
    points: Array<readonly [number, number]>,
  ): Promise<{ samples: KernelPalette["accents"]; blockingDurationMs: number }> {
    let blockingDurationMs = 0;
    let bitmap: ImageBitmap | null = null;
    try {
      if (!this.readabilityCanvas) {
        this.readabilityCanvas = document.createElement("canvas");
        this.readabilityCanvas.width = READABILITY_BUFFER_WIDTH;
        this.readabilityCanvas.height = READABILITY_BUFFER_HEIGHT;
        this.readabilityContext = this.readabilityCanvas.getContext("2d", {
          alpha: true,
          willReadFrequently: true,
        });
      }
      const context = this.readabilityContext;
      if (!context) return { samples: [], blockingDurationMs };
      if (typeof createImageBitmap === "function") {
        const schedulingStarted = performance.now();
        const bitmapPromise = createImageBitmap(slot.canvas, {
          resizeWidth: READABILITY_BUFFER_WIDTH,
          resizeHeight: READABILITY_BUFFER_HEIGHT,
          resizeQuality: "low",
        });
        blockingDurationMs += performance.now() - schedulingStarted;
        bitmap = await bitmapPromise;
      }
      if (bitmap) {
        const postingStarted = performance.now();
        const workerResult = this.readBitmapOffMainThread(bitmap);
        blockingDurationMs += performance.now() - postingStarted;
        if (workerResult) {
          bitmap = null; // ownership transferred to the worker
          const rgba = await workerResult;
          if (rgba) {
            const processingStarted = performance.now();
            const samples = this.samplesFromRgba(rgba, points);
            blockingDurationMs += performance.now() - processingStarted;
            return { samples, blockingDurationMs };
          }
        }
      }
      const processingStarted = performance.now();
      context.clearRect(0, 0, READABILITY_BUFFER_WIDTH, READABILITY_BUFFER_HEIGHT);
      context.drawImage(
        bitmap ?? slot.canvas,
        0,
        0,
        READABILITY_BUFFER_WIDTH,
        READABILITY_BUFFER_HEIGHT,
      );
      const rgba = context.getImageData(
        0,
        0,
        READABILITY_BUFFER_WIDTH,
        READABILITY_BUFFER_HEIGHT,
      ).data;
      const samples = this.samplesFromRgba(rgba, points);
      blockingDurationMs += performance.now() - processingStarted;
      return { samples, blockingDurationMs };
    } catch {
      return { samples: [], blockingDurationMs };
    } finally {
      bitmap?.close();
    }
  }

  private samplesFromRgba(
    rgba: ArrayLike<number>,
    points: Array<readonly [number, number]>,
  ): KernelPalette["accents"] {
    return points.map(([xUnit, yUnit]) => {
      const x = Math.min(
        READABILITY_BUFFER_WIDTH - 1,
        Math.max(0, Math.round(xUnit * (READABILITY_BUFFER_WIDTH - 1))),
      );
      const y = Math.min(
        READABILITY_BUFFER_HEIGHT - 1,
        Math.max(0, Math.round(yUnit * (READABILITY_BUFFER_HEIGHT - 1))),
      );
      const offset = (y * READABILITY_BUFFER_WIDTH + x) * 4;
      const alpha = (rgba[offset + 3] ?? 255) / 255;
      return [
        (rgba[offset] ?? 0) * alpha + this.palette.bg[0] * (1 - alpha),
        (rgba[offset + 1] ?? 0) * alpha + this.palette.bg[1] * (1 - alpha),
        (rgba[offset + 2] ?? 0) * alpha + this.palette.bg[2] * (1 - alpha),
      ];
    });
  }

  private readBitmapOffMainThread(bitmap: ImageBitmap): Promise<Uint8ClampedArray | null> | null {
    const worker = this.getReadabilityWorker();
    if (!worker) return null;
    const id = ++this.readabilityWorkerRequest;
    return new Promise((resolve) => {
      const timeout = window.setTimeout(() => {
        this.readabilityWorkerPending.delete(id);
        resolve(null);
      }, 750);
      this.readabilityWorkerPending.set(id, { resolve, timeout });
      worker.postMessage({ id, bitmap }, [bitmap]);
    });
  }

  private getReadabilityWorker(): Worker | null {
    if (this.readabilityWorker !== undefined) return this.readabilityWorker;
    if (
      typeof Worker === "undefined" ||
      typeof Blob === "undefined" ||
      typeof URL === "undefined" ||
      typeof OffscreenCanvas === "undefined"
    ) {
      this.readabilityWorker = null;
      return null;
    }

    const source = `
      const canvas = new OffscreenCanvas(${READABILITY_BUFFER_WIDTH}, ${READABILITY_BUFFER_HEIGHT});
      const context = canvas.getContext("2d", { alpha: true, willReadFrequently: true });
      self.onmessage = (event) => {
        const { id, bitmap } = event.data;
        try {
          context.clearRect(0, 0, canvas.width, canvas.height);
          context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
          bitmap.close();
          const rgba = context.getImageData(0, 0, canvas.width, canvas.height).data;
          self.postMessage({ id, rgba: rgba.buffer }, [rgba.buffer]);
        } catch (error) {
          try { bitmap.close(); } catch (_) {}
          self.postMessage({ id, rgba: null });
        }
      };
    `;
    try {
      this.readabilityWorkerURL = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
      const worker = new Worker(this.readabilityWorkerURL);
      worker.onmessage = (event: MessageEvent<{ id: number; rgba: ArrayBuffer | null }>) => {
        const pending = this.readabilityWorkerPending.get(event.data.id);
        if (!pending) return;
        clearTimeout(pending.timeout);
        this.readabilityWorkerPending.delete(event.data.id);
        pending.resolve(event.data.rgba ? new Uint8ClampedArray(event.data.rgba) : null);
      };
      worker.onerror = () => {
        worker.terminate();
        this.readabilityWorker = null;
        for (const pending of this.readabilityWorkerPending.values()) {
          clearTimeout(pending.timeout);
          pending.resolve(null);
        }
        this.readabilityWorkerPending.clear();
      };
      this.readabilityWorker = worker;
      return worker;
    } catch {
      this.readabilityWorker = null;
      return null;
    }
  }

  // ── Observers / input ──────────────────────────────────────

  private attachObservers(): void {
    this.resizeObs = new ResizeObserver((entries) => {
      const entry = entries[0];
      if (!entry) return;
      const { width, height } = entry.contentRect;
      if (width === 0 || height === 0) return;
      this.width = width;
      this.height = height;
      for (const slot of this.slots) {
        this.sizeCanvas(slot);
        slot.kernel.resize(this.frameCtx(slot.substrate));
      }
      this.harvestObstacles(true);
      this.scheduleReadabilitySample();
    });
    this.resizeObs.observe(this.container);

    // Deferred initial harvest (let the page content lay out first). Tracked so
    // destroy() can cancel them — they would otherwise fire on a torn-down engine.
    this.initialHarvestRaf = requestAnimationFrame(() =>
      this.harvestObstacles(true),
    );
    this.initialHarvestTimer = window.setTimeout(
      () => this.harvestObstacles(true),
      700,
    );

    this.intersectionObs = new IntersectionObserver(
      (entries) => {
        this.visible = entries[0]?.isIntersecting ?? true;
      },
      { threshold: 0 },
    );
    this.intersectionObs.observe(this.container);

    document.addEventListener("visibilitychange", this.onVisibility);
    window.addEventListener("pointermove", this.onPointerMove, {
      passive: true,
    });
    window.addEventListener("pointerout", this.onPointerOut, { passive: true });
    window.addEventListener("scroll", this.onScroll, {
      passive: true,
      capture: true,
    });
    window.addEventListener("click", this.onClick, { passive: true });

    this.mql = window.matchMedia("(prefers-reduced-motion: reduce)");
    this.mql.addEventListener("change", this.onReducedMotionChange);
  }

  private onVisibility = (): void => {
    const wasVisible = this.pageVisible;
    this.pageVisible = !document.hidden;
    if (this.pageVisible) this.scheduleReadabilitySample();
    if (!wasVisible && this.pageVisible && this.retryRequestedKernelOnVisible) {
      // A context can remain unavailable for the hidden window's lifetime and
      // recover only after the compositor presents it again. Force a fresh
      // slot so the requested shader gets another context acquisition attempt.
      this.transitionKernel(this.requestedKernelId, true);
    }
  };

  private onPointerMove = (e: PointerEvent): void => {
    const rect = this.container.getBoundingClientRect();
    this.pointer.x = e.clientX - rect.left;
    this.pointer.y = e.clientY - rect.top;
    this.pointer.active = true;
    for (const slot of this.slots) {
      slot.kernel.pointer?.(this.pointer.x, this.pointer.y, true);
    }
  };

  private onPointerOut = (): void => {
    this.pointer.active = false;
    for (const slot of this.slots) {
      slot.kernel.pointer?.(this.pointer.x, this.pointer.y, false);
    }
  };

  private onClick = (e: MouseEvent): void => {
    // Only blank backdrop areas spawn particles — ignore clicks that land on
    // interactive content, glass cards, pills, or the switcher.
    const target = e.target as Element | null;
    if (
      target?.closest?.(
        "a, button, input, textarea, select, label, [role='button']," +
          ".glass-frost, .glass-refract, .glass-pill, .studio-switcher",
      )
    ) {
      return;
    }
    const rect = this.container.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    for (const slot of this.slots) {
      if (!slot.outgoing) slot.kernel.click?.(x, y);
    }
  };

  /**
   * Harvest the bounding rects of the glass cards + headings so kernels can
   * make the field flow around the page's words and boxes. DOM-reading
   * (getBoundingClientRect) — only called on resize, throttled scroll, kernel
   * switch, and a deferred initial pass; never in the rAF frame loop.
   */
  private harvestObstacles(force = false): void {
    const now = typeof performance !== "undefined" ? performance.now() : 0;
    if (!force && now - this.lastHarvest < 300) return;
    this.lastHarvest = now;
    const wantsObstacles = this.slots.some(
      (s) => !s.outgoing && s.kernel.obstacles,
    );
    if (!wantsObstacles) return;

    const base = this.container.getBoundingClientRect();
    const vh = window.innerHeight;
    const els = document.querySelectorAll<HTMLElement>(
      ".glass-frost, .glass-refract, h1, h2",
    );
    const rects: { x: number; y: number; w: number; h: number }[] = [];
    els.forEach((el) => {
      if (rects.length >= 24) return;
      const r = el.getBoundingClientRect();
      if (r.width < 8 || r.height < 8) return;
      if (r.bottom < -140 || r.top > vh + 140) return; // off-screen — skip
      rects.push({
        x: r.left - base.left,
        y: r.top - base.top,
        w: r.width,
        h: r.height,
      });
    });
    for (const slot of this.slots) {
      if (!slot.outgoing) slot.kernel.obstacles?.(rects);
    }
  }

  private onScroll = (e: Event): void => {
    // Capture mode catches scrolls from inner containers (modals, panels,
    // scroll areas). Only react to genuine document scroll so an inner panel
    // scrolling never injects stale velocity or phantom page deltas.
    const target = e.target;
    if (target !== document && target !== document.documentElement) {
      return;
    }
    const ny = window.scrollY || window.pageYOffset || 0;
    const delta = ny - this.scroll.y;
    const docEl = document.documentElement;
    this.scroll.y = ny;
    this.scroll.yMax = Math.max(
      0,
      (docEl?.scrollHeight ?? 0) - window.innerHeight,
    );
    this.scrollDelta += delta;
    this.harvestObstacles(); // throttled internally
  };

  private onReducedMotionChange = (e: MediaQueryListEvent): void => {
    this.reducedMotion = e.matches;
    if (e.matches) {
      if (this.raf !== null) {
        cancelAnimationFrame(this.raf);
        this.raf = null;
      }
      for (const slot of this.slots) slot.kernel.renderStatic?.();
      this.scheduleReadabilitySample();
    } else if (this.raf === null) {
      this.startLoop();
      this.scheduleReadabilitySample();
    }
  };
}
