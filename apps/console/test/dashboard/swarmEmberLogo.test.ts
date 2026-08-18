import { describe, expect, it } from "vitest";

import {
  BURNBAR_LOGO_COUNT,
  BURNBAR_LOGO_PACKED,
  BURNBAR_LOGO_STRIDE,
  ROLE_BAR,
  ROLE_CRESCENT,
  ROLE_FLAME,
  ROLE_TIP,
} from "../../lib/gl/engine/kernels/swarmEmberLogoData";
import {
  buildDashboardCycle,
  burnBarLogoPoints,
  createSwarmEmberKernel,
  logoHeroCycle,
} from "../../lib/gl/engine/kernels/swarmEmberKernel";

describe("Swarm Ember logo cloud", () => {
  it("packs a dense, centered sampling of the official mark", () => {
    expect(BURNBAR_LOGO_COUNT).toBeGreaterThan(1500);
    expect(BURNBAR_LOGO_PACKED.length).toBe(BURNBAR_LOGO_COUNT * BURNBAR_LOGO_STRIDE);

    const pts = burnBarLogoPoints();
    expect(pts).toHaveLength(BURNBAR_LOGO_COUNT);

    let sx = 0;
    let sy = 0;
    const roles = new Set<number>();
    for (const p of pts) {
      expect(p.x).toBeGreaterThanOrEqual(-1);
      expect(p.x).toBeLessThanOrEqual(1);
      expect(p.y).toBeGreaterThanOrEqual(-1);
      expect(p.y).toBeLessThanOrEqual(1);
      expect(p.rgb[0] + p.rgb[1] + p.rgb[2]).toBeGreaterThan(40);
      roles.add(p.role);
      sx += p.x;
      sy += p.y;
    }
    // Density is heavier in the bars than the flame tip, so the mass
    // centroid sits a little below origin — the bounding box is what must
    // stay framed on the mark.
    expect(sx / pts.length).toBeCloseTo(0, 1);
    expect(Math.abs(sy / pts.length)).toBeLessThan(0.2);
    const xs = pts.map((p) => p.x);
    const ys = pts.map((p) => p.y);
    expect((Math.min(...xs) + Math.max(...xs)) / 2).toBeCloseTo(0, 1);
    expect((Math.min(...ys) + Math.max(...ys)) / 2).toBeCloseTo(0, 1);
    expect(roles.has(ROLE_FLAME)).toBe(true);
    expect(roles.has(ROLE_BAR)).toBe(true);
    expect(roles.has(ROLE_CRESCENT)).toBe(true);
    expect(roles.has(ROLE_TIP)).toBe(true);
  });

  it("hero cycle is mark then swarm — no provider slideshow", () => {
    expect(logoHeroCycle()).toEqual(["shapeBurnBarLogo", "swarm"]);
  });

  it("keeps the dashboard cycle contract for Linux/macOS", () => {
    expect(buildDashboardCycle(["codex"], true, true)).toHaveLength(2);
    expect(buildDashboardCycle([], true, true)).toEqual(["swarm"]);
    expect(buildDashboardCycle([], false, true)).toEqual([
      "swarm",
      "shapeDollar",
      "swarm",
      "shapeCode",
      "swarm",
      "shapeBurnBarLogo",
      "swarm",
      "shapeRings",
      "swarm",
      "shapeRouterFlow",
    ]);
    expect(buildDashboardCycle(["codex"], false, false)).toEqual(["swarm"]);
  });

  it("constructs the hero kernel without a DOM", () => {
    const kernel = createSwarmEmberKernel({ logoHero: true, enableSwarmSparkles: true });
    expect(kernel.id).toBe("swarmEmber");
    expect(kernel.substrate).toBe("2d");
    expect(kernel.label).toBe("Swarm Ember");
  });
});
