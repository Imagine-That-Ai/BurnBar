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
import {
  advanceCinematicPresent,
  cinematicPresentFps,
  frameDeltaMs,
  shutterAlpha,
  shouldAdvancePresent,
} from "../../packages/gl-engine/src/engine/cinematicClock";
import {
  KERNELS,
  isKernelId,
} from "../../packages/gl-engine/src/engine/registry";
import type { BackdropReadabilityProfile } from "../../packages/gl-engine/src/engine/readability";
import type {
  KernelId,
  KernelSubstrate,
} from "../../packages/gl-engine/src/engine/types";

interface KernelBridgeMeta {
  id: KernelId;
  label: string;
  blurb: string;
  substrate: KernelSubstrate;
}

interface KernelBackdropRuntimeState {
  hostVisible: boolean;
  renderLoopScheduled: boolean;
  reducedMotion: boolean;
  resolvedKernel: KernelId;
}

declare global {
  interface Window {
    /** WebKit native-message bridge, absent in ordinary browsers. */
    webkit?: {
      messageHandlers?: {
        backdropReadability?: { postMessage: (profile: BackdropReadabilityProfile) => void };
      };
    };
    /** Switch the live kernel. Returns false (and no-ops) for junk ids. */
    __setKernel?: (id: string) => boolean;
    /** Switch the palette theme; anything but "light"/"dark" is ignored. */
    __setTheme?: (theme: string) => void;
    /** Cap embedded previews without changing the browser default. */
    __setMaxFps?: (fps: number) => void;
    /** The kernel actually shown (may differ from requested on GL fallback). */
    __getKernel?: () => KernelId;
    /** Actual engine visibility and render-loop state for native handshakes. */
    __getBackdropState?: () => KernelBackdropRuntimeState;
    /** Import-free registry metadata for native pickers. */
    __kernels?: KernelBridgeMeta[];
    /** Last measured foreground profile for diagnostics and native polling. */
    __getReadability?: () => BackdropReadabilityProfile | null;
    /**
     * Native occlusion bridge: the host calls `false` when the window is
     * fully occluded/minimized/hidden (document.hidden never fires for mere
     * window occlusion) and `true` when it becomes visible again. Fully
     * stops/restarts the render loop.
     */
    __setBackdropActive?: (active: boolean) => void;
    /** Set once the bridge above is callable; natives poll this before driving. */
    __backdropReady?: boolean;
    /** Pure cinematic clock — the Node harness drives these shipped functions. */
    __cinematicClock?: {
      cinematicPresentFps: typeof cinematicPresentFps;
      shouldAdvancePresent: typeof shouldAdvancePresent;
      frameDeltaMs: typeof frameDeltaMs;
      shutterAlpha: typeof shutterAlpha;
      advanceCinematicPresent: typeof advanceCinematicPresent;
    };
    __getCinematicDebug?: () => {
      lastDt: number;
      lastAlpha: number;
      presentCount: number;
      skipCount: number;
      maxFps: number;
    };
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

function initialMaxFps(): number {
  const value = Number(new URLSearchParams(location.search).get("maxFps"));
  return Number.isFinite(value) && value > 0 ? Math.min(value, 60) : 0;
}

function performanceMotionOverride(): boolean | undefined {
  try {
    return new URLSearchParams(location.search).get("motion") === "full" ? false : undefined;
  } catch {
    return undefined;
  }
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

  let readability: BackdropReadabilityProfile | null = null;
  const engine = new BackdropEngine(host, {
    theme: "dark",
    initialKernel: initialKernel(),
    maxFps: initialMaxFps(),
    onReadability: (profile) => {
      readability = profile;
      window.webkit?.messageHandlers?.backdropReadability?.postMessage(profile);
    },
    reducedMotionOverride: performanceMotionOverride(),
  });

  window.__setKernel = (id: string): boolean => {
    if (!isKernelId(id)) return false;
    engine.setKernel(id);
    return true;
  };
  window.__setTheme = (theme: string): void => {
    if (theme === "dark" || theme === "light") engine.setTheme(theme);
  };
  window.__setMaxFps = (fps: number): void => engine.setMaxFps(fps);
  window.__getKernel = (): KernelId => engine.getResolvedKernel();
  window.__getReadability = (): BackdropReadabilityProfile | null => readability;
  window.__getBackdropState = (): KernelBackdropRuntimeState => engine.getRuntimeState();
  window.__setBackdropActive = (active: boolean): void => {
    engine.setHostVisible(active === true);
  };
  window.__cinematicClock = {
    cinematicPresentFps,
    shouldAdvancePresent,
    frameDeltaMs,
    shutterAlpha,
    advanceCinematicPresent,
  };
  window.__getCinematicDebug = () => engine.getCinematicDebug();
  window.__kernels = KERNELS.map((k): KernelBridgeMeta => ({
    id: k.id,
    label: k.label,
    blurb: k.blurb,
    substrate: k.substrate,
  }));
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
