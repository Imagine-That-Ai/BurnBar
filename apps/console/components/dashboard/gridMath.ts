/**
 * Pure grid geometry for the draggable/resizable glass grid.
 *
 * No React, no DOM, no dependencies — every function here is total and
 * deterministic so it can be unit-tested directly (test/dashboard/gridMath).
 * The layout model is column-based, à la react-grid-layout, but intentionally
 * minimal: a fixed column count, uniform row height, fixed gap, snap-to-grid
 * placement, and a top-left free-slot finder. No free-form collision reflow —
 * that is a documented follow-up.
 */

export interface GridRect {
  /** Column index of the left edge (0-based). */
  x: number;
  /** Row index of the top edge (0-based). */
  y: number;
  /** Width in columns. */
  w: number;
  /** Height in rows. */
  h: number;
}

export const GRID = {
  cols: 12,
  rowHeight: 84,
  gap: 16,
  minW: 3,
  minH: 2,
} as const;

// Hard ceiling on rows so a tampered/huge persisted value can never blow up the
// grid height into a blank, unscrollable dashboard.
export const MAX_ROWS = 400;

/** Pixel width of a single column for a given container width. */
export function columnWidth(
  containerWidth: number,
  cols: number = GRID.cols,
  gap: number = GRID.gap,
): number {
  const usable = containerWidth - gap * (cols - 1);
  return Math.max(1, usable / cols);
}

/** Left offset in px for a column index. */
export function colToPx(col: number, colW: number, gap: number = GRID.gap): number {
  return col * (colW + gap);
}

/** Top offset in px for a row index. */
export function rowToPx(
  row: number,
  rowH: number = GRID.rowHeight,
  gap: number = GRID.gap,
): number {
  return row * (rowH + gap);
}

/** Pixel width spanned by `w` columns. */
export function spanWidthPx(w: number, colW: number, gap: number = GRID.gap): number {
  return w * colW + (w - 1) * gap;
}

/** Pixel height spanned by `h` rows. */
export function spanHeightPx(
  h: number,
  rowH: number = GRID.rowHeight,
  gap: number = GRID.gap,
): number {
  return h * rowH + (h - 1) * gap;
}

/** Nearest column index for a left offset in px (>= 0). */
export function pxToCol(px: number, colW: number, gap: number = GRID.gap): number {
  return Math.max(0, Math.round(px / (colW + gap)));
}

/** Nearest row index for a top offset in px (>= 0). */
export function pxToRow(
  px: number,
  rowH: number = GRID.rowHeight,
  gap: number = GRID.gap,
): number {
  return Math.max(0, Math.round(px / (rowH + gap)));
}

/** Nearest column span (>= 1) for a pixel width. */
export function pxToColSpan(px: number, colW: number, gap: number = GRID.gap): number {
  return Math.max(1, Math.round((px + gap) / (colW + gap)));
}

/** Nearest row span (>= 1) for a pixel height. */
export function pxToRowSpan(
  px: number,
  rowH: number = GRID.rowHeight,
  gap: number = GRID.gap,
): number {
  return Math.max(1, Math.round((px + gap) / (rowH + gap)));
}

function clampInt(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, Math.round(value)));
}

/** Constrain a rect to the grid: integer cells, min/max sizes, within columns. */
export function clampRect(
  rect: GridRect,
  cols: number = GRID.cols,
  minW: number = GRID.minW,
  minH: number = GRID.minH,
): GridRect {
  const w = clampInt(rect.w, Math.min(minW, cols), cols);
  const h = clampInt(rect.h, minH, MAX_ROWS);
  const x = clampInt(rect.x, 0, cols - w);
  const y = clampInt(rect.y, 0, MAX_ROWS);
  return { x, y, w, h };
}

/** True when two rects share any cell. */
export function rectsOverlap(a: GridRect, b: GridRect): boolean {
  return (
    a.x < b.x + b.w &&
    a.x + a.w > b.x &&
    a.y < b.y + b.h &&
    a.y + a.h > b.y
  );
}

/** Lowest occupied row + 1 (i.e. the first fully-empty row), 0 when empty. */
export function nextRow(rects: GridRect[]): number {
  return rects.reduce((max, r) => Math.max(max, r.y + r.h), 0);
}

/**
 * First top-left free position for a w×h card among `occupied` rects.
 * Always terminates: the bottom of the stack is guaranteed free.
 */
export function findFreeSlot(
  occupied: GridRect[],
  w: number,
  h: number,
  cols: number = GRID.cols,
): { x: number; y: number } {
  const width = Math.min(w, cols);
  const maxY = nextRow(occupied) + h + 1;
  for (let y = 0; y <= maxY; y++) {
    for (let x = 0; x <= cols - width; x++) {
      const candidate: GridRect = { x, y, w: width, h };
      if (!occupied.some((r) => rectsOverlap(candidate, r))) {
        return { x, y };
      }
    }
  }
  return { x: 0, y: nextRow(occupied) };
}

/**
 * Snap an absolute pixel rect (during a drag/resize) back onto the grid.
 * `mode` keeps the anchored edges fixed: "move" preserves size, "resize"
 * preserves the top-left origin (the width is capped against the origin so a
 * right-anchored card grows in place instead of sliding left).
 */
export function snapPxRect(
  px: { left: number; top: number; width: number; height: number },
  colW: number,
  cols: number = GRID.cols,
  rowH: number = GRID.rowHeight,
  gap: number = GRID.gap,
  mode: "move" | "resize" = "move",
): GridRect {
  const x = pxToCol(px.left, colW, gap);
  const y = pxToRow(px.top, rowH, gap);
  let w = pxToColSpan(px.width, colW, gap);
  const h = pxToRowSpan(px.height, rowH, gap);
  if (mode === "resize") {
    // Keep the left edge fixed: never let the card spill past the last column.
    w = Math.max(1, Math.min(w, cols - x));
  }
  return clampRect({ x, y, w, h }, cols);
}
