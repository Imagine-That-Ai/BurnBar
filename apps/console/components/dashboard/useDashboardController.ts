"use client";

import * as React from "react";

import { isKernelId } from "@/lib/gl/engine/registry";
import type { KernelId } from "@/lib/gl/engine/types";
import {
  CARD_DEF_BY_ID,
  CARD_ID_SET,
  KERNEL_ID_SET,
  buildFallbackState,
  isCardId,
  rectsOf,
  type CardId,
} from "./cardRegistry";
import { findFreeSlot, type GridRect } from "./gridMath";
import {
  loadDashboardState,
  safeLocalStorage,
  saveDashboardState,
  type DashboardLayoutItem,
  type DashboardState,
} from "./layoutStore";

export interface DashboardController {
  items: DashboardLayoutItem[];
  kernelId: KernelId;
  frost: number;
  editable: boolean;
  placedIds: ReadonlySet<string>;
  setEditable: (v: boolean) => void;
  addCard: (cardId: CardId) => void;
  removeCard: (cardId: string) => void;
  updateRect: (cardId: string, rect: GridRect) => void;
  setKernel: (id: KernelId) => void;
  setFrost: (frost: number) => void;
  reset: () => void;
}

export function useDashboardController(): DashboardController {
  const fallback = React.useMemo(() => buildFallbackState(), []);
  const [state, setState] = React.useState<DashboardState>(fallback);
  const [hydrated, setHydrated] = React.useState(false);
  const [editable, setEditable] = React.useState(false);

  // Hydrate from localStorage after mount (keeps SSR/prerender deterministic).
  React.useEffect(() => {
    const storage = safeLocalStorage();
    const loaded = loadDashboardState(storage, {
      validCardIds: CARD_ID_SET,
      validKernelIds: KERNEL_ID_SET,
      fallback,
    });
    setState(loaded);
    setHydrated(true);
  }, [fallback]);

  // Persist on change, but only after hydration so we never clobber stored
  // state with the initial fallback on first paint.
  React.useEffect(() => {
    if (!hydrated) return;
    saveDashboardState(safeLocalStorage(), state);
  }, [state, hydrated]);

  const addCard = React.useCallback((cardId: CardId) => {
    setState((prev) => {
      if (prev.items.some((it) => it.cardId === cardId)) return prev;
      const def = CARD_DEF_BY_ID[cardId];
      if (!def) return prev;
      const slot = findFreeSlot(rectsOf(prev.items), def.defaultSize.w, def.defaultSize.h);
      const item: DashboardLayoutItem = {
        cardId,
        rect: { x: slot.x, y: slot.y, w: def.defaultSize.w, h: def.defaultSize.h },
      };
      return { ...prev, items: [...prev.items, item] };
    });
  }, []);

  const removeCard = React.useCallback((cardId: string) => {
    setState((prev) => ({ ...prev, items: prev.items.filter((it) => it.cardId !== cardId) }));
  }, []);

  const updateRect = React.useCallback((cardId: string, rect: GridRect) => {
    setState((prev) => ({
      ...prev,
      items: prev.items.map((it) => (it.cardId === cardId ? { ...it, rect } : it)),
    }));
  }, []);

  const setKernel = React.useCallback((id: KernelId) => {
    if (!isKernelId(id)) return;
    setState((prev) => ({ ...prev, appearance: { ...prev.appearance, kernelId: id } }));
  }, []);

  const setFrost = React.useCallback((frost: number) => {
    const clamped = Math.min(1, Math.max(0, frost));
    setState((prev) => ({ ...prev, appearance: { ...prev.appearance, frost: clamped } }));
  }, []);

  const reset = React.useCallback(() => {
    // Return to the default board; the persistence effect then rewrites it as
    // the canonical saved state.
    setState(buildFallbackState());
  }, []);

  const placedIds = React.useMemo(
    () => new Set(state.items.map((it) => it.cardId)),
    [state.items],
  );

  const kernelId: KernelId = isKernelId(state.appearance.kernelId)
    ? state.appearance.kernelId
    : fallback.appearance.kernelId as KernelId;

  // Defend the render path against any non-card id sneaking through.
  const items = React.useMemo(
    () => state.items.filter((it) => isCardId(it.cardId)),
    [state.items],
  );

  return {
    items,
    kernelId,
    frost: state.appearance.frost,
    editable,
    placedIds,
    setEditable,
    addCard,
    removeCard,
    updateRect,
    setKernel,
    setFrost,
    reset,
  };
}
