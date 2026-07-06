/**
 * Standalone bootstrap for the offline WKWebView kernel backdrop bundle.
 *
 * This is the source of truth for the committed
 * `AgentLens/Resources/KernelBackdrop/kernel-backdrop.js` (a minified esbuild
 * IIFE shared verbatim by the macOS AND iOS apps). Regenerate with:
 *
 *   node scripts/build-kernel-backdrop.mjs
 *
 * The bootstrap mirrors what the console does with {@link BackdropEngine},
 * minus React: find-or-create the `#host` stage, mount the engine with the
 * kernel named by `location.hash` → `?kernel=` → `"fluid-aurora"` → first
 * registry entry, and expose the tiny `window.__*` bridge the native
 * `KernelBackdropView` / `MobileWebGLKernelBackdropView` coordinators drive
 * through `evaluateJavaScript`.
 */

import { BackdropEngine } from "../../packages/gl-engine/src/engine/BackdropEngine";
import { KERNELS, isKernelId } from "../../packages/gl-engine/src/engine/registry";
import type { KernelId, KernelSubstrate } from "../../packages/gl-engine/src/engine/types";

interface KernelBridgeMeta {
  id: KernelId;
  label: string;
  blurb: string;
  substrate: KernelSubstrate;
}

declare global {
  interface Window {
    /** Switch the live kernel. Returns false (and no-ops) for junk ids. */
    __setKernel?: (id: string) => boolean;
    /** Switch the palette theme; anything but "light"/"dark" is ignored. */
    __setTheme?: (theme: string) => void;
    /** The kernel actually shown (may differ from requested on GL fallback). */
    __getKernel?: () => KernelId;
    /** Import-free registry metadata for native pickers. */
    __kernels?: KernelBridgeMeta[];
    /** Set once the bridge above is callable; natives poll this before driving. */
    __backdropReady?: boolean;
  }
}

/** Matches the console default the native coordinators assume. */
const PREFERRED_DEFAULT = "fluid-aurora";

function initialKernel(): KernelId {
  try {
    const hash = (location.hash || "").replace(/^#/, "").trim();
    if (isKernelId(hash)) return hash;
    const query = new URLSearchParams(location.search).get("kernel");
    if (isKernelId(query)) return query;
  } catch {
    /* URL parsing never takes the backdrop down */
  }
  return isKernelId(PREFERRED_DEFAULT) ? PREFERRED_DEFAULT : KERNELS[0]!.id;
}

function mount(): void {
  let host = document.getElementById("host");
  if (!host) {
    host = document.createElement("div");
    host.id = "host";
    document.body.appendChild(host);
  }
  host.style.position = "fixed";
  host.style.inset = "0";
  host.style.width = "100%";
  host.style.height = "100%";
  host.style.overflow = "hidden";

  const engine = new BackdropEngine(host, { theme: "dark", initialKernel: initialKernel() });

  window.__setKernel = (id: string): boolean => {
    if (!isKernelId(id)) return false;
    engine.setKernel(id);
    return true;
  };
  window.__setTheme = (theme: string): void => {
    if (theme === "dark" || theme === "light") engine.setTheme(theme);
  };
  window.__getKernel = (): KernelId => engine.getResolvedKernel();
  window.__kernels = KERNELS.map(
    (k): KernelBridgeMeta => ({ id: k.id, label: k.label, blurb: k.blurb, substrate: k.substrate })
  );
  window.__backdropReady = true;
  window.addEventListener("hashchange", () => {
    const hash = (location.hash || "").replace(/^#/, "").trim();
    if (isKernelId(hash)) engine.setKernel(hash);
  });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", mount, { once: true });
} else {
  mount();
}
