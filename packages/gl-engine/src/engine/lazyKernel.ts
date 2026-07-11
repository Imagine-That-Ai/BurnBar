/**
 * lazyKernel — defer a kernel's heavy module (its GLSL + helpers) out of the
 * app-shell bundle and load it on first use via dynamic `import()`.
 *
 * The registry wraps each non-default kernel factory in `lazyKernel`. The proxy
 * exposes the cheap static fields (`id`, `label`, `substrate`) synchronously so
 * the host can size the canvas and pick the GL/2D context immediately; the heavy
 * factory module is imported on the first `init()`/`frame()` call. While the
 * module is loading, `frame()`/`renderStatic()` no-op — the host keeps the
 * incoming slot at `opacity:0` during the 700ms crossfade, so a blank frame or
 * two is invisible, and a warm dynamic import resolves in tens of milliseconds.
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

  function ensure(): Promise<Kernel> {
    if (real) return Promise.resolve(real);
    if (!pending) {
      pending = loader().then((factory) => {
        // If dispose() fired while the import was in-flight, abandon: never
        // construct a real kernel (it would orphan GL resources on a dead slot).
        if (disposed) {
          pending = null;
          return null as unknown as Kernel;
        }
        real = factory();
        // If init was called before the module loaded, run it now.
        if (pendingInit) {
          real.init(pendingInit.ctx, pendingInit.frame);
          pendingInit = null;
        }
        // Replay a static frame requested during load (reduced-motion path).
        if (pendingStatic) {
          real.renderStatic?.();
          pendingStatic = false;
        }
        pending = null;
        return real;
      });
    }
    return pending;
  }

  return {
    id,
    label,
    substrate,
    init(ctx, frame) {
      pendingInit = { ctx, frame };
      void ensure();
    },
    frame(tMs: number, dtMs: number) {
      real?.frame(tMs, dtMs);
      // else: still loading — no-op (canvas is opacity:0 during crossfade).
    },
    resize(frame) {
      real?.resize(frame);
    },
    setTheme(theme, palette) {
      real?.setTheme(theme, palette);
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
