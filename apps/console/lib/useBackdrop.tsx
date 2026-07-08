"use client";

import * as React from "react";
import { usePathname } from "next/navigation";

import { isKernelId } from "@openburnbar/gl-engine/engine/registry";
import type { KernelId } from "@openburnbar/gl-engine/engine/types";

/**
 * The single source of truth for the console-wide animated backdrop kernel.
 * It's rendered once globally (every tab) and changed from the dashboard's
 * Appearance picker or the Experimental gallery — both write here, so the whole
 * console updates live and the choice persists.
 *
 * Precedence: ?kernel=<id> (inspection / shareable-preview override, read once
 *             on mount, NEVER persisted) > localStorage (the member's choice) >
 *             DEFAULT_KERNEL.
 *
 * `inkEnabled` is false on /dashboard — that route owns its own glass-plate
 * legibility (the `.lg-card` token overrides), so the global ink scrim +
 * light-ink token remap stays off there. Every other route opts in.
 */
const DEFAULT_KERNEL: KernelId = "fluid-aurora";
const STORAGE_KEY = "burnbar.console.backdrop";

interface BackdropState {
  kernelId: KernelId;
  setKernelId: (id: KernelId) => void;
  /** True on every route except /dashboard (which owns its own legibility). */
  inkEnabled: boolean;
}

const BackdropContext = React.createContext<BackdropState>({
  kernelId: DEFAULT_KERNEL,
  setKernelId: () => {},
  inkEnabled: true,
});

/** Read a one-shot `?kernel=<id>` override from the URL (client only). */
function readKernelOverride(): KernelId | null {
  if (typeof window === "undefined") return null;
  try {
    const v = new URLSearchParams(window.location.search).get("kernel");
    return isKernelId(v) ? v : null;
  } catch {
    return null;
  }
}

export function BackdropProvider({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const [stored, setStored] = React.useState<KernelId>(DEFAULT_KERNEL);
  // `?kernel=` override: highest precedence, read once on mount, never written
  // back to localStorage. An explicit user selection clears it (their choice
  // wins and persists). SSR renders with no override → no hydration mismatch.
  const [override, setOverride] = React.useState<KernelId | null>(null);

  React.useEffect(() => {
    setOverride(readKernelOverride());

    let saved: string | null = null;
    try {
      saved = window.localStorage.getItem(STORAGE_KEY);
    } catch {
      /* private mode / blocked */
    }
    if (isKernelId(saved)) setStored(saved);

    // Keep multiple tabs in sync.
    const onStorage = (e: StorageEvent) => {
      if (e.key === STORAGE_KEY && isKernelId(e.newValue)) setStored(e.newValue);
    };
    window.addEventListener("storage", onStorage);
    return () => window.removeEventListener("storage", onStorage);
  }, []);

  const setKernelId = React.useCallback((id: KernelId) => {
    if (!isKernelId(id)) return;
    setOverride(null); // an explicit pick supersedes any ?kernel= preview
    setStored(id);
    try {
      window.localStorage.setItem(STORAGE_KEY, id);
    } catch {
      /* non-fatal */
    }
  }, []);

  const kernelId = override ?? stored;
  const inkEnabled = pathname !== "/dashboard";

  const value = React.useMemo(
    () => ({ kernelId, setKernelId, inkEnabled }),
    [kernelId, setKernelId, inkEnabled],
  );
  return <BackdropContext.Provider value={value}>{children}</BackdropContext.Provider>;
}

export function useBackdrop(): BackdropState {
  return React.useContext(BackdropContext);
}
