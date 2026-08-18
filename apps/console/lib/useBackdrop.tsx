"use client";

import * as React from "react";
import { usePathname } from "next/navigation";

import { isKernelId } from "@/lib/gl/engine/registry";
import type { KernelId } from "@/lib/gl/engine/types";
import { isThemeId } from "@/lib/useTheme";

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
 * One-time reverse migration: the short-lived per-theme backdrop experiment
 * stored picks in `burnbar.console.backdrop.byTheme` (and removed the legacy
 * key). If only that map exists, its most recent pick is folded back onto the
 * single-choice key so the member's backdrop survives the revert.
 *
 * `inkEnabled` is false on /dashboard — that route owns its own glass-plate
 * legibility (the `.lg-card` token overrides), so the global ink scrim +
 * light-ink token remap stays off there. Every other route opts in.
 */
const DEFAULT_KERNEL: KernelId = "fluid-aurora";
const STORAGE_KEY = "burnbar.console.backdrop";
const RETIRED_THEME_MAP_KEY = "burnbar.console.backdrop.byTheme";

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

/**
 * Read the member's persisted kernel. Falls back to the retired per-theme map
 * (folding its most recent valid pick back onto STORAGE_KEY) so a choice made
 * during the theme-pairing experiment is not lost.
 */
function readStoredKernel(): KernelId | null {
  try {
    const legacy = window.localStorage.getItem(STORAGE_KEY);
    if (isKernelId(legacy)) return legacy;

    const raw = window.localStorage.getItem(RETIRED_THEME_MAP_KEY);
    if (!raw) return null;
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null) return null;
    let recovered: KernelId | null = null;
    for (const [k, v] of Object.entries(parsed)) {
      if (isThemeId(k) && isKernelId(v)) recovered = v; // last valid wins
    }
    if (recovered) {
      window.localStorage.setItem(STORAGE_KEY, recovered);
      window.localStorage.removeItem(RETIRED_THEME_MAP_KEY);
    }
    return recovered;
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

    const saved = readStoredKernel();
    if (saved) setStored(saved);

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
