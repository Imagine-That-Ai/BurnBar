/**
 * lazyKernel — defer a kernel's heavy module (its GLSL + helpers) out of the
 * app-shell bundle and load it on first use via dynamic `import()`.
 *
 * The registry wraps each non-default kernel factory in `lazyKernel`. The proxy
 * exposes the cheap static fields (`id`, `label`, `substrate`) synchronously so
 * the host can size the canvas and pick the GL/2D context immediately; the heavy
 * factory module is imported on the first `init()`/`frame()` call. While the
 * module is loading, shader-backed `frame()`/`renderStatic()` calls no-op;
 * lazy 2D proxies paint their palette base immediately so WebKitGTK never
 * shows a transparent backdrop during chunk resolution. The host keeps the
 * incoming slot at `opacity:0` during the 700ms crossfade, and a warm dynamic
 * import resolves in tens of milliseconds.
 *
 * Net effect on the bundle: each kernel's GLSL + helpers move from the eager
 * app-shell chunk into an on-demand chunk, paid for only when the visitor
 * actually switches to that kernel. The default kernel (constellation) and the
 * small originals stay eager so first paint is instant.
 */

import type {
  Kernel,
  KernelFactory,
  KernelFrameContext,
  KernelId,
  KernelPalette,
  KernelRenderingContext,
  KernelSubstrate,
  ThemeName,
} from "./types";
import { toCss } from "./palette";

/** A loader that dynamically imports the real kernel factory. */
export type LazyKernelLoader = () => Promise<KernelFactory>;

/**
 * Return a proxy `Kernel` that defers to `loader()` for the real implementation.
 * `id`/`label`/`substrate` are known statically (cheap) so the host can mount
 * the canvas immediately; the heavy factory is imported on first use.
 */
export function lazyKernel(
  id: KernelId,
  label: string,
  substrate: KernelSubstrate,
  loader: LazyKernelLoader
): Kernel {
  // The real kernel, once loaded. `pending` tracks the in-flight import so a
  // rapid sequence of calls coalesces on one load.
  let real: Kernel | null = null;
  let pending: Promise<Kernel> | null = null;
  let disposed = false;
  // Stash the init args so the real kernel can init as soon as it loads.
  let pendingInit: { ctx: KernelRenderingContext; frame: KernelFrameContext } | null = null;
  // A renderStatic() requested while the module was still loading. In reduced
  // motion there is no rAF loop to paint a later frame, so a lazy kernel would
  // otherwise never draw — replay the static frame once the real kernel is ready.
  let pendingStatic = false;

  /**
   * Paint the contractually truthful 2D base while a lazy chunk is resolving.
   *
   * The host has already sized and exposed the canvas by the time `init()`
   * returns. WebKitGTK can take long enough to resolve a dynamic import that
   * leaving the fresh canvas transparent reads as a black/blank backdrop. A
   * palette-backed fill is the same base every 2D kernel paints during its own
   * init, and setting the transform here keeps high-DPR canvases fully covered.
   * WebGL/WebGPU proxies deliberately never enter this path.
   */
  function paint2dPlaceholder(frame: KernelFrameContext, context: KernelRenderingContext): void {
    if (substrate !== "2d") return;
    const canvas = context as CanvasRenderingContext2D;
    canvas.setTransform(frame.dpr, 0, 0, frame.dpr, 0, 0);
    canvas.fillStyle = toCss(frame.palette.bg);
    canvas.fillRect(0, 0, frame.width, frame.height);
  }

  function ensure(): Promise<Kernel> {
    if (real) return Promise.resolve(real);
    if (!pending) {
      try {
        pending = loader()
          .then((factory) => {
            // If dispose() fired while the import was in-flight, abandon: never
            // construct a real kernel (it would orphan GL resources on a dead slot).
            if (disposed) {
              pending = null;
              return null as unknown as Kernel;
            }
            real = factory();
            // If init was called before the module loaded, run it now — unless
            // the slot's GL context died while the chunk was in flight (rapid
            // kernel switching under context-budget pressure). Compiling on a
            // lost context only produces a spurious shader error; the engine's
            // own contextlost path is already replacing this slot.
            if (pendingInit) {
              const maybeGl = pendingInit.ctx as WebGL2RenderingContext;
              const dead =
                substrate === "webgl2" &&
                typeof maybeGl.isContextLost === "function" &&
                maybeGl.isContextLost();
              if (!dead) real.init(pendingInit.ctx, pendingInit.frame);
              pendingInit = null;
            }
            // Replay a static frame requested during load (reduced-motion path).
            if (pendingStatic) {
              real.renderStatic?.();
              pendingStatic = false;
            }
            pending = null;
            return real;
          })
          .catch(() => {
            // Dynamic imports can fail on a stale/offline WebView. Keep the
            // already-painted 2D base and let a later init retry instead of
            // creating an unhandled Promise rejection.
            pending = null;
            return null as unknown as Kernel;
          });
      } catch {
        // A wrapper around a dynamic import can throw before returning its
        // Promise. Treat that boundary like a rejected chunk as well.
        pending = Promise.resolve(null as unknown as Kernel).then((result) => {
          pending = null;
          return result;
        });
      }
    }
    return pending;
  }

  return {
    id,
    label,
    substrate,
    init(ctx, frame) {
      pendingInit = { ctx, frame };
      paint2dPlaceholder(frame, ctx);
      void ensure();
    },
    frame(tMs: number, dtMs: number) {
      real?.frame(tMs, dtMs);
      // else: still loading — no-op (canvas is opacity:0 during crossfade).
    },
    resize(frame) {
      if (real) {
        real.resize(frame);
      } else if (pendingInit) {
        pendingInit = { ...pendingInit, frame };
        paint2dPlaceholder(frame, pendingInit.ctx);
      }
    },
    setTheme(theme, palette) {
      if (real) {
        real.setTheme(theme, palette);
      } else if (pendingInit) {
        const nextFrame: KernelFrameContext = { ...pendingInit.frame, theme, palette };
        pendingInit = { ...pendingInit, frame: nextFrame };
        paint2dPlaceholder(nextFrame, pendingInit.ctx);
      }
    },
    pointer(x, y, active) {
      real?.pointer?.(x, y, active);
    },
    click(x, y) {
      real?.click?.(x, y);
    },
    obstacles(rects) {
      real?.obstacles?.(rects);
    },
    scroll(y, vy, yMax) {
      real?.scroll?.(y, vy, yMax);
    },
    renderStatic() {
      if (real) real.renderStatic?.();
      else pendingStatic = true; // replay once the module finishes loading
    },
    dispose() {
      disposed = true;
      pendingStatic = false;
      real?.dispose();
      real = null;
      pending = null;
      pendingInit = null;
    },
  };
}

// Re-export the palette/theme types the proxy references (keeps the import surface tidy).
export type { KernelPalette, ThemeName };
