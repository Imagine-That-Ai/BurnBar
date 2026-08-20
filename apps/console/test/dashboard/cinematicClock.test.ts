import { describe, expect, it } from "vitest";

import {
  advanceCinematicPresent,
  cinematicPresentFps,
  newCinematicClockState,
  shutterAlpha,
} from "../../lib/gl/engine/cinematicClock";

describe("cinematicPresentFps", () => {
  it("picks a divisor of refresh and never 30 on 144", () => {
    expect(cinematicPresentFps(60)).toBe(30);
    expect(cinematicPresentFps(120)).toBe(30);
    expect(cinematicPresentFps(144)).toBe(36);
    expect(cinematicPresentFps(144)).not.toBe(30);
  });
});

describe("advanceCinematicPresent", () => {
  it("skips sub-interval ticks and presents with real dt plus shutter alpha", () => {
    const state = newCinematicClockState();
    expect(advanceCinematicPresent(state, 0, 30).presented).toBe(true);
    expect(advanceCinematicPresent(state, 8, 30).presented).toBe(false);
    const step = advanceCinematicPresent(state, 34, 30);
    expect(step.presented).toBe(true);
    expect(step.dt).toBeGreaterThan(16);
    expect(step.alpha).toBeCloseTo(shutterAlpha(step.dt));
    expect(step.alpha).toBeLessThan(1);
  });
});
