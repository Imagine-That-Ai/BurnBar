import { describe, expect, it } from "vitest";

import {
  CARD_DEFS,
  CARD_IDS,
  DEFAULT_DASHBOARD_ITEMS,
  KERNEL_ID_SET,
  buildFallbackState,
  isCardId,
} from "@/components/dashboard/cardRegistry";
import { GRID, rectsOverlap } from "@/components/dashboard/gridMath";

describe("card registry", () => {
  it("declares the nine §7 cards with unique ids", () => {
    expect(CARD_DEFS).toHaveLength(9);
    expect(new Set(CARD_IDS).size).toBe(9);
  });

  it("every card has a component, icon, and a valid default size", () => {
    for (const def of CARD_DEFS) {
      expect(typeof def.component).toBe("function");
      expect(def.icon).toBeTruthy();
      expect(def.defaultSize.w).toBeGreaterThanOrEqual(GRID.minW);
      expect(def.defaultSize.h).toBeGreaterThanOrEqual(GRID.minH);
      expect(def.defaultSize.w).toBeLessThanOrEqual(GRID.cols);
    }
  });

  it("isCardId guards correctly", () => {
    expect(isCardId("burn")).toBe(true);
    expect(isCardId("nope")).toBe(false);
    expect(isCardId(42)).toBe(false);
  });

  it("default layout places every card without overlaps", () => {
    expect(DEFAULT_DASHBOARD_ITEMS).toHaveLength(9);
    expect(new Set(DEFAULT_DASHBOARD_ITEMS.map((i) => i.cardId)).size).toBe(9);
    for (const it of DEFAULT_DASHBOARD_ITEMS) {
      expect(isCardId(it.cardId)).toBe(true);
      expect(it.rect.x + it.rect.w).toBeLessThanOrEqual(GRID.cols);
    }
    for (let i = 0; i < DEFAULT_DASHBOARD_ITEMS.length; i++) {
      for (let j = i + 1; j < DEFAULT_DASHBOARD_ITEMS.length; j++) {
        expect(
          rectsOverlap(DEFAULT_DASHBOARD_ITEMS[i]!.rect, DEFAULT_DASHBOARD_ITEMS[j]!.rect),
        ).toBe(false);
      }
    }
  });

  it("fallback state is internally consistent", () => {
    const s = buildFallbackState();
    expect(s.items).toHaveLength(9);
    expect(KERNEL_ID_SET.has(s.appearance.kernelId)).toBe(true);
    expect(s.appearance.frost).toBeGreaterThanOrEqual(0);
    expect(s.appearance.frost).toBeLessThanOrEqual(1);
  });
});
