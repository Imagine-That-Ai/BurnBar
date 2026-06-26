import { describe, expect, it } from "vitest";

import { buildMockWindow } from "@/lib/dashboard/mockUsage";
import type { DashboardRange } from "@/lib/dashboard/types";

const RANGES: DashboardRange[] = ["today", "7d", "30d"];

describe("buildMockWindow", () => {
  it("is deterministic (same seed → identical window)", () => {
    for (const r of RANGES) {
      expect(buildMockWindow(r)).toEqual(buildMockWindow(r));
    }
  });

  it("produces a well-formed, internally consistent window", () => {
    for (const r of RANGES) {
      const w = buildMockWindow(r);
      expect(w.range).toBe(r);
      expect(w.totalCostUsd).toBeGreaterThan(0);
      expect(w.providers.length).toBeGreaterThan(0);

      // Provider costs sum to ~the total (rounding tolerance).
      const sum = w.providers.reduce((s, p) => s + p.costUsd, 0);
      expect(Math.abs(sum - w.totalCostUsd)).toBeLessThanOrEqual(0.05 * w.totalCostUsd + 0.5);

      // Providers are sorted by cost desc.
      for (let i = 1; i < w.providers.length; i++) {
        expect(w.providers[i - 1]!.costUsd).toBeGreaterThanOrEqual(w.providers[i]!.costUsd);
      }

      // Rates are within [0,1].
      expect(w.cacheHitRate).toBeGreaterThanOrEqual(0);
      expect(w.cacheHitRate).toBeLessThanOrEqual(1);
      for (const p of w.providers) {
        expect(p.cacheHitRate).toBeGreaterThanOrEqual(0);
        expect(p.cacheHitRate).toBeLessThanOrEqual(1);
      }
    }
  });

  it("cost curve is monotonic non-decreasing, normalized, ending at total", () => {
    const w = buildMockWindow("7d");
    expect(w.costCurve[0]!.t).toBe(0);
    expect(w.costCurve[w.costCurve.length - 1]!.t).toBe(1);
    for (let i = 1; i < w.costCurve.length; i++) {
      expect(w.costCurve[i]!.cumulativeUsd).toBeGreaterThanOrEqual(
        w.costCurve[i - 1]!.cumulativeUsd,
      );
    }
    expect(w.costCurve[w.costCurve.length - 1]!.cumulativeUsd).toBeCloseTo(w.totalCostUsd, 1);
  });

  it("fusion savings are non-negative", () => {
    const w = buildMockWindow("30d");
    expect(w.fusion.savedUsd).toBeGreaterThanOrEqual(0);
    expect(w.fusion.fusionRuns).toBeGreaterThan(0);
  });

  it("provider ids match brand-logo / swarm convention (kebab-ish)", () => {
    const w = buildMockWindow("today");
    for (const p of w.providers) {
      expect(p.id).toMatch(/^[a-z0-9-]+$/);
    }
  });
});
