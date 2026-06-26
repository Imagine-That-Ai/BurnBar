import { describe, expect, it } from "vitest";

import {
  GRID,
  MAX_ROWS,
  clampRect,
  columnWidth,
  findFreeSlot,
  nextRow,
  pxToColSpan,
  rectsOverlap,
  resizeRectFromOrigin,
  snapPxRect,
  spanWidthPx,
  type GridRect,
} from "@/components/dashboard/gridMath";

describe("columnWidth", () => {
  it("accounts for inter-column gaps", () => {
    // 12 cols, 11 gaps of 16 => usable 1024 - 176 = 848 over 12.
    expect(columnWidth(1024, 12, 16)).toBeCloseTo(848 / 12, 5);
  });
  it("never returns a non-positive width", () => {
    expect(columnWidth(0)).toBeGreaterThan(0);
    expect(columnWidth(-50)).toBeGreaterThan(0);
  });
});

describe("span <-> px round trip", () => {
  it("recovers the span from its pixel width", () => {
    const colW = columnWidth(1024);
    for (let w = 1; w <= GRID.cols; w++) {
      expect(pxToColSpan(spanWidthPx(w, colW), colW)).toBe(w);
    }
  });
});

describe("clampRect", () => {
  it("enforces min sizes and grid bounds", () => {
    const r = clampRect({ x: -3, y: -1, w: 1, h: 1 });
    expect(r.x).toBe(0);
    expect(r.y).toBe(0);
    expect(r.w).toBeGreaterThanOrEqual(GRID.minW);
    expect(r.h).toBeGreaterThanOrEqual(GRID.minH);
  });
  it("keeps a card within the column count", () => {
    const r = clampRect({ x: 11, y: 0, w: 6, h: 2 });
    expect(r.x + r.w).toBeLessThanOrEqual(GRID.cols);
  });
  it("rounds fractional cells", () => {
    const r = clampRect({ x: 2.6, y: 1.4, w: 3.5, h: 2.2 });
    expect(Number.isInteger(r.x)).toBe(true);
    expect(Number.isInteger(r.y)).toBe(true);
    expect(Number.isInteger(r.w)).toBe(true);
    expect(Number.isInteger(r.h)).toBe(true);
  });
});

describe("rectsOverlap", () => {
  const a: GridRect = { x: 0, y: 0, w: 4, h: 3 };
  it("detects overlap", () => {
    expect(rectsOverlap(a, { x: 3, y: 2, w: 4, h: 3 })).toBe(true);
  });
  it("treats edge adjacency as non-overlap", () => {
    expect(rectsOverlap(a, { x: 4, y: 0, w: 4, h: 3 })).toBe(false);
    expect(rectsOverlap(a, { x: 0, y: 3, w: 4, h: 3 })).toBe(false);
  });
});

describe("findFreeSlot", () => {
  it("returns origin for an empty grid", () => {
    expect(findFreeSlot([], 4, 3)).toEqual({ x: 0, y: 0 });
  });
  it("never overlaps existing rects", () => {
    const occupied: GridRect[] = [
      { x: 0, y: 0, w: 4, h: 3 },
      { x: 4, y: 0, w: 8, h: 3 },
    ];
    const slot = findFreeSlot(occupied, 5, 4);
    const placed: GridRect = { x: slot.x, y: slot.y, w: 5, h: 4 };
    expect(occupied.some((r) => rectsOverlap(placed, r))).toBe(false);
    expect(placed.x + placed.w).toBeLessThanOrEqual(GRID.cols);
  });
  it("always terminates even when the grid is full at the top", () => {
    const occupied: GridRect[] = [{ x: 0, y: 0, w: 12, h: 2 }];
    const slot = findFreeSlot(occupied, 12, 2);
    expect(slot.y).toBeGreaterThanOrEqual(2);
  });
});

describe("nextRow", () => {
  it("is the lowest bottom edge", () => {
    expect(
      nextRow([
        { x: 0, y: 0, w: 4, h: 3 },
        { x: 4, y: 2, w: 4, h: 4 },
      ]),
    ).toBe(6);
  });
  it("is 0 when empty", () => {
    expect(nextRow([])).toBe(0);
  });
});

describe("clampRect upper bounds", () => {
  it("caps a huge tampered y/h to the row ceiling", () => {
    const r = clampRect({ x: 0, y: 9_999_999, w: 4, h: 9_999_999 });
    expect(r.y).toBeLessThanOrEqual(MAX_ROWS);
    expect(r.h).toBeLessThanOrEqual(MAX_ROWS);
    expect(r.h).toBeGreaterThanOrEqual(GRID.minH);
  });
});

describe("snapPxRect resize mode", () => {
  it("preserves the left/top origin and caps width at the right edge", () => {
    const colW = columnWidth(1024);
    // A card anchored near the right edge, grown wider than the remaining cols.
    const snapped = snapPxRect(
      {
        left: colToPxLocal(9, colW),
        top: 0,
        width: spanWidthPx(8, colW), // would overflow past col 12
        height: GRID.rowHeight * 2,
      },
      colW,
      GRID.cols,
      GRID.rowHeight,
      GRID.gap,
      "resize",
    );
    expect(snapped.x).toBe(9); // origin preserved, NOT shifted left
    expect(snapped.x + snapped.w).toBeLessThanOrEqual(GRID.cols);
  });
});

describe("resizeRectFromOrigin", () => {
  it("caps keyboard resize at the right edge without shifting origin", () => {
    const resized = resizeRectFromOrigin({ x: 9, y: 1, w: 3, h: 2 }, 1, 0);
    expect(resized).toEqual({ x: 9, y: 1, w: 3, h: 2 });
  });

  it("still applies minimum height and width", () => {
    const resized = resizeRectFromOrigin({ x: 2, y: 1, w: 4, h: 3 }, -20, -20);
    expect(resized.w).toBe(GRID.minW);
    expect(resized.h).toBe(GRID.minH);
  });
});

function colToPxLocal(col: number, colW: number) {
  return col * (colW + GRID.gap);
}

describe("snapPxRect", () => {
  it("snaps an arbitrary pixel rect onto valid grid cells", () => {
    const colW = columnWidth(1024);
    const snapped = snapPxRect(
      {
        left: colW * 2 + 6,
        top: GRID.rowHeight * 1 + 4,
        width: spanWidthPx(4, colW),
        height: GRID.rowHeight * 3,
      },
      colW,
    );
    expect(snapped.x).toBe(2);
    expect(snapped.w).toBe(4);
    expect(snapped.x + snapped.w).toBeLessThanOrEqual(GRID.cols);
  });
});
