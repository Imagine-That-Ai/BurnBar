import { describe, expect, it } from "vitest";

import { placeTooltip, TOOLTIP_MARGIN } from "../lib/profile/tooltipPlacement";

const VIEWPORT = { width: 1280, height: 800 };
const CARD = { width: 176, height: 120 };

describe("placeTooltip", () => {
  it("floats above a mid-viewport anchor, centered on it", () => {
    const p = placeTooltip({ x: 600, y: 400, width: 11, height: 11 }, CARD, VIEWPORT);
    expect(p.above).toBe(true);
    expect(p.top).toBe(400 - 120 - 8);
    expect(p.left).toBeCloseTo(600 + 11 / 2 - 176 / 2, 5);
  });

  it("flips below when the top has no room for the card", () => {
    const p = placeTooltip({ x: 600, y: 40, width: 11, height: 11 }, CARD, VIEWPORT);
    expect(p.above).toBe(false);
    expect(p.top).toBe(40 + 11 + 8);
  });

  it("stays above a bottom-docked anchor when the top fits", () => {
    const p = placeTooltip({ x: 600, y: 700, width: 11, height: 11 }, CARD, VIEWPORT);
    expect(p.above).toBe(true);
  });

  it("clamps into the left and right viewport edges", () => {
    const left = placeTooltip({ x: 4, y: 400, width: 11, height: 11 }, CARD, VIEWPORT);
    expect(left.left).toBe(TOOLTIP_MARGIN);
    const right = placeTooltip({ x: 1268, y: 400, width: 11, height: 11 }, CARD, VIEWPORT);
    expect(right.left).toBe(1280 - 176 - TOOLTIP_MARGIN);
  });

  it("picks the roomier side when neither side fits", () => {
    const tiny = { width: 200, height: 100 };
    const card = { width: 176, height: 90 };
    // Anchor near the bottom: below has ~no room, above wins by comparison.
    const p = placeTooltip({ x: 10, y: 80, width: 11, height: 11 }, card, tiny);
    expect(p.above).toBe(true);
  });
});
