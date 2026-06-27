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
import { DEFAULT_KERNEL_ID, getKernelDescriptor } from "./registry";
import type {
  Kernel,
  KernelFrameContext,
  KernelId,
  KernelPalette,
  KernelSubstrate,
  ThemeName,
} from "./types";

const FADE_MS = 700;
// Fragment-shader kernels are soft, full-screen fields — high DPR is wasted
// detail at real cost, so cap WebGL lower than the crisp 2D particle canvases.
const DPR_CAP: Record<KernelSubstrate, number> = { "2d": 2, webgl2: 1.2, webgpu: 1 };

interface Slot {
  id: KernelId;
  canvas: HTMLCanvasElement;
  kernel: Kernel;
  substrate: KernelSubstrate;
  outgoing: boolean;
  disposeTimer: number | null;
}

export interface BackdropEngineOptions {
  theme: ThemeName;
  initialKernel?: KernelId;
  /** Notified with the kernel actually shown (may differ on GL fallback). */
  onResolve?: (id: KernelId) => void;
}

function detectWebgl2(): { supported: boolean; caps: GlCapabilities } {
  try {
    const c = document.createElement("canvas");
    const gl = c.getContext("webgl2");
    if (!gl) return { supported: false, caps: { colorBufferFloat: false, floatBlend: false } };
    const caps = detectGlCapabilities(gl);
    gl.getExtension("WEBGL_lose_context")?.loseContext();
    return { supported: true, caps };
  } catch {
    return { supported: false, caps: { colorBufferFloat: false, floatBlend: false } };
  }
}

export class BackdropEngine {
  readonly glSupported: boolean;
  private readonly glCaps: GlCapabilities;

  private container: HTMLElement;
  private slots: Slot[] = [];
  private activeId: KernelId;
  private theme: ThemeName;
  private palette: KernelPalette;
  private onResolve?: (id: KernelId) => void;

  private width = 0;
  private height = 0;
  private tMs = 0;
  private lastNow = 0;
  private raf: number | null = null;

  private visible = true;
  private pageVisible = true;
  private reducedMotion = false;

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

  constructor(container: HTMLElement, opts: BackdropEngineOptions) {
    this.container = container;
    const detected = detectWebgl2();
    this.glSupported = detected.supported;
    this.glCaps = detected.caps;
    this.theme = opts.theme;
    this.palette = resolvePalette(opts.theme);
    this.onResolve = opts.onResolve;
    this.activeId = opts.initialKernel ?? DEFAULT_KERNEL_ID;

    this.reducedMotion =
      typeof window !== "undefined" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    const rect = container.getBoundingClientRect();
    this.width = rect.width || window.innerWidth;
    this.height = rect.height || window.innerHeight;

    this.mountInitial();
    this.attachObservers();
    if (!this.reducedMotion) this.startLoop();
  }

  // ── Public API ─────────────────────────────────────────────

  setKernel(id: KernelId): void {
    const resolved = this.resolveId(id);
    if (resolved === this.activeId && this.slots.some((s) => s.id === resolved && !s.outgoing)) {
      return;
    }
    // Finalize any still-fading slots, then retire the current ones.
    this.finalizeOutgoing();
    for (const slot of this.slots) {
      slot.outgoing = true;
      slot.canvas.style.opacity = "0";
      slot.disposeTimer = window.setTimeout(() => this.disposeSlot(slot), FADE_MS + 80);
    }

    const slot = this.createSlot(resolved);
    this.activeId = slot.id;
    this.onResolve?.(slot.id);
    this.harvestObstacles(true); // a freshly-switched kernel gets current geometry

    // Fade the newcomer in on the next frame (lets the transition apply).
    requestAnimationFrame(() => {
      slot.canvas.style.opacity = "1";
    });
    if (this.reducedMotion) slot.kernel.renderStatic?.();
  }

  setTheme(theme: ThemeName): void {
    if (theme === this.theme) return;
    this.theme = theme;
    this.palette = resolvePalette(theme);
    for (const slot of this.slots) {
      slot.kernel.setTheme(theme, this.palette);
      if (this.reducedMotion) slot.kernel.renderStatic?.();
    }
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
  }

  getResolvedKernel(): KernelId {
    return this.activeId;
  }

  /** A foreground glyph was dragged/thrown through the field — forward to the
   *  active kernel so the underlying world genuinely reacts (area-relative). */
  wake(x: number, y: number, dx: number, dy: number, radius: number, strength: number): void {
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
    if (this.raf !== null) cancelAnimationFrame(this.raf);
    if (this.initialHarvestRaf !== null) cancelAnimationFrame(this.initialHarvestRaf);
    if (this.initialHarvestTimer !== null) clearTimeout(this.initialHarvestTimer);
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
  }

  // ── Slot lifecycle ─────────────────────────────────────────

  private resolveId(id: KernelId): KernelId {
    const desc = getKernelDescriptor(id);
    if (desc.substrate === "webgl2" && !this.glSupported) return DEFAULT_KERNEL_ID;
    // Capability gate (D1): a float-target kernel on a no-float-RT machine
    // resolves to its fallback BEFORE instantiation — never a black canvas.
    if (desc.requiresFloatTex && !this.glCaps.colorBufferFloat) {
      return desc.fallbackId ?? DEFAULT_KERNEL_ID;
    }
    // WebGPU premium tier degrades to its WebGL fallback when navigator.gpu is
    // absent (older OS/browser) — same "never black" contract.
    if (
      (desc.requiresWebGPU || desc.substrate === "webgpu") &&
      typeof navigator !== "undefined" &&
      !("gpu" in navigator)
    ) {
      return desc.fallbackId ?? DEFAULT_KERNEL_ID;
    }
    return desc.id;
  }

  private mountInitial(): void {
    const slot = this.createSlot(this.resolveId(this.activeId));
    this.activeId = slot.id;
    slot.canvas.style.opacity = "1";
    this.onResolve?.(slot.id);
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
    const kernel: Kernel = desc.create();
    const substrate = kernel.substrate;

    const canvas = document.createElement("canvas");
    canvas.setAttribute("aria-hidden", "true");
    canvas.style.cssText =
      "position:absolute;inset:0;display:block;opacity:0;" +
      `transition:opacity ${FADE_MS}ms ease;will-change:opacity;`;
    this.container.appendChild(canvas);

    const slot: Slot = { id: kernel.id, canvas, kernel, substrate, outgoing: false, disposeTimer: null };
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
        alpha: false,
        antialias: false,
        depth: false,
        stencil: false,
        premultipliedAlpha: true,
        powerPreference: "high-performance",
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

    kernel.init(ctx, this.frameCtx(substrate));
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
    try {
      slot.kernel.dispose();
    } catch {
      /* ignore teardown errors */
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
      if (!this.visible || !this.pageVisible) {
        this.lastNow = now;
        return;
      }
      const dt = Math.min(now - this.lastNow, 32);
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
    };
    this.raf = requestAnimationFrame(loop);
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
    });
    this.resizeObs.observe(this.container);

    // Deferred initial harvest (let the page content lay out first). Tracked so
    // destroy() can cancel them — they would otherwise fire on a torn-down engine.
    this.initialHarvestRaf = requestAnimationFrame(() => this.harvestObstacles(true));
    this.initialHarvestTimer = window.setTimeout(() => this.harvestObstacles(true), 700);

    this.intersectionObs = new IntersectionObserver(
      (entries) => {
        this.visible = entries[0]?.isIntersecting ?? true;
      },
      { threshold: 0 }
    );
    this.intersectionObs.observe(this.container);

    document.addEventListener("visibilitychange", this.onVisibility);
    window.addEventListener("pointermove", this.onPointerMove, { passive: true });
    window.addEventListener("pointerout", this.onPointerOut, { passive: true });
    window.addEventListener("scroll", this.onScroll, { passive: true, capture: true });
    window.addEventListener("click", this.onClick, { passive: true });

    this.mql = window.matchMedia("(prefers-reduced-motion: reduce)");
    this.mql.addEventListener("change", this.onReducedMotionChange);
  }

  private onVisibility = (): void => {
    this.pageVisible = !document.hidden;
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
          ".glass-frost, .glass-refract, .glass-pill, .studio-switcher"
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
    if (!force && now - this.lastHarvest < 150) return;
    this.lastHarvest = now;
    const wantsObstacles = this.slots.some((s) => !s.outgoing && s.kernel.obstacles);
    if (!wantsObstacles) return;

    const base = this.container.getBoundingClientRect();
    const vh = window.innerHeight;
    const els = document.querySelectorAll<HTMLElement>(
      ".glass-frost, .glass-refract, h1, h2"
    );
    const rects: { x: number; y: number; w: number; h: number }[] = [];
    els.forEach((el) => {
      if (rects.length >= 24) return;
      const r = el.getBoundingClientRect();
      if (r.width < 8 || r.height < 8) return;
      if (r.bottom < -140 || r.top > vh + 140) return; // off-screen — skip
      rects.push({ x: r.left - base.left, y: r.top - base.top, w: r.width, h: r.height });
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
    this.scroll.yMax = Math.max(0, (docEl?.scrollHeight ?? 0) - window.innerHeight);
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
    } else if (this.raf === null) {
      this.startLoop();
    }
  };
}
