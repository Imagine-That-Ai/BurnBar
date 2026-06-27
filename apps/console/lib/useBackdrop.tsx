"use client";

import * as React from "react";

import { isKernelId } from "@/lib/gl/engine/registry";
import type { KernelId } from "@/lib/gl/engine/types";

/**
 * The single source of truth for the console-wide animated backdrop kernel.
 * It's rendered once globally (every tab) and changed from the dashboard's
 * Appearance picker or the Experimental gallery — both write here, so the whole
 * console updates live and the choice persists.
 */
const DEFAULT_KERNEL: KernelId = "fluid-aurora";
const STORAGE_KEY = "burnbar.console.backdrop";

interface BackdropState {
  kernelId: KernelId;
  setKernelId: (id: KernelId) => void;
}

const BackdropContext = React.createContext<BackdropState>({
  kernelId: DEFAULT_KERNEL,
  setKernelId: () => {},
});

export function BackdropProvider({ children }: { children: React.ReactNode }) {
  const [kernelId, setKernelState] = React.useState<KernelId>(DEFAULT_KERNEL);

  React.useEffect(() => {
    let saved: string | null = null;
    try {
      saved = window.localStorage.getItem(STORAGE_KEY);
    } catch {
      /* private mode / blocked */
    }
    if (isKernelId(saved)) setKernelState(saved);
    // Keep multiple tabs in sync.
    const onStorage = (e: StorageEvent) => {
      if (e.key === STORAGE_KEY && isKernelId(e.newValue)) setKernelState(e.newValue);
    };
    window.addEventListener("storage", onStorage);
    return () => window.removeEventListener("storage", onStorage);
  }, []);

  const setKernelId = React.useCallback((id: KernelId) => {
    if (!isKernelId(id)) return;
    setKernelState(id);
    try {
      window.localStorage.setItem(STORAGE_KEY, id);
    } catch {
      /* non-fatal */
    }
  }, []);

  const value = React.useMemo(() => ({ kernelId, setKernelId }), [kernelId, setKernelId]);
  return <BackdropContext.Provider value={value}>{children}</BackdropContext.Provider>;
}

export function useBackdrop(): BackdropState {
  return React.useContext(BackdropContext);
}
