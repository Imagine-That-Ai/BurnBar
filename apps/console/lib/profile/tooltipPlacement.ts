/**
 * Viewport-aware placement for floating hover cards (heatmap day card).
 *
 * The heatmap lives in a horizontal scroll container, whose overflow clips
 * anything positioned outside it — so the card portals to `document.body`
 * with `position: fixed` and lands here: prefer above the anchor, flip below
 * when the top has no room, and clamp horizontally into the viewport. Pure
 * numbers in, pure numbers out — the component measures, this decides.
 */

/** Anchor rect in viewport (client) coordinates. */
export interface TooltipAnchor {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface TooltipSize {
  width: number;
  height: number;
}

export interface TooltipViewport {
  width: number;
  height: number;
}

export interface TooltipPlacement {
  left: number;
  top: number;
  /** True when the card sits above the anchor (for tests + arrow styling). */
  above: boolean;
}

/** Minimum gap to the viewport edges and between anchor and card. */
export const TOOLTIP_MARGIN = 12;
const ANCHOR_GAP = 8;

export function placeTooltip(
  anchor: TooltipAnchor,
  size: TooltipSize,
  viewport: TooltipViewport,
): TooltipPlacement {
  const spaceAbove = anchor.y - TOOLTIP_MARGIN;
  const spaceBelow = viewport.height - (anchor.y + anchor.height) - TOOLTIP_MARGIN;
  // Above when it fits there; otherwise below when that fits; otherwise the
  // roomier side (a giant card on a tiny viewport still picks sanely).
  const above =
    spaceAbove >= size.height || (spaceBelow < size.height && spaceAbove >= spaceBelow);
  const unclampedTop = above
    ? anchor.y - size.height - ANCHOR_GAP
    : anchor.y + anchor.height + ANCHOR_GAP;
  // Horizontal already clamps. Do the same on Y: a card taller than both
  // remaining gutters (zoom, short window) still has to stay on-screen.
  const minTop = TOOLTIP_MARGIN;
  const maxTop = Math.max(minTop, viewport.height - size.height - TOOLTIP_MARGIN);
  const top = Math.min(Math.max(unclampedTop, minTop), maxTop);

  const idealLeft = anchor.x + anchor.width / 2 - size.width / 2;
  const minLeft = TOOLTIP_MARGIN;
  const maxLeft = Math.max(minLeft, viewport.width - size.width - TOOLTIP_MARGIN);
  const left = Math.min(Math.max(idealLeft, minLeft), maxLeft);

  return { left, top, above };
}
