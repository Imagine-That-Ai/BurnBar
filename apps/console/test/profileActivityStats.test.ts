import { describe, expect, it } from "vitest";

import {
  activeDayCount,
  addDays,
  computeStreaks,
  dayOfWeek,
  formatDayLabel,
  intensityBucket,
  peakDay,
  toDayKey,
  weekStart,
  weeklyTotals,
} from "../lib/profile/activityStats";
import type { DailyPoint } from "../lib/usage";

function pts(...entries: [string, number][]): DailyPoint[] {
  return entries.map(([day, tokens]) => ({ day, tokens }));
}

describe("day helpers", () => {
  it("round-trips a Date through a day key", () => {
    expect(toDayKey(new Date(Date.UTC(2026, 1, 1)))).toBe("2026-02-01");
  });

  it("addDays crosses month and year boundaries", () => {
    expect(addDays("2026-02-28", 1)).toBe("2026-03-01");
    expect(addDays("2026-01-01", -1)).toBe("2025-12-31");
    expect(addDays("2024-02-28", 1)).toBe("2024-02-29"); // leap year
  });

  it("dayOfWeek is Sunday-based", () => {
    expect(dayOfWeek("2026-02-01")).toBe(0); // a Sunday
    expect(dayOfWeek("2026-02-02")).toBe(1);
  });

  it("weekStart snaps to the Sunday on or before", () => {
    expect(weekStart("2026-02-04")).toBe("2026-02-01");
    expect(weekStart("2026-02-01")).toBe("2026-02-01");
  });

  it("formatDayLabel is deterministic without Intl", () => {
    expect(formatDayLabel("2026-02-01")).toBe("Feb 1, 2026");
  });
});

describe("computeStreaks", () => {
  it("returns zeros for no activity", () => {
    expect(computeStreaks(new Set(), "2026-08-16")).toEqual({ current: 0, longest: 0 });
  });

  it("counts a streak ending today", () => {
    const days = new Set(["2026-08-14", "2026-08-15", "2026-08-16"]);
    expect(computeStreaks(days, "2026-08-16")).toEqual({ current: 3, longest: 3 });
  });

  it("a quiet today does not break yesterday's streak", () => {
    const days = new Set(["2026-08-14", "2026-08-15"]);
    expect(computeStreaks(days, "2026-08-16")).toEqual({ current: 2, longest: 2 });
  });

  it("a gap yesterday ends the current streak", () => {
    const days = new Set(["2026-08-13", "2026-08-14"]);
    expect(computeStreaks(days, "2026-08-16")).toEqual({ current: 0, longest: 2 });
  });

  it("finds the longest run anywhere in history", () => {
    const days = new Set([
      "2026-01-01",
      "2026-01-02",
      "2026-05-03",
      "2026-05-04",
      "2026-05-05",
      "2026-05-06",
    ]);
    expect(computeStreaks(days, "2026-08-16")).toEqual({ current: 0, longest: 4 });
  });

  it("handles a single active day", () => {
    expect(computeStreaks(new Set(["2026-08-16"]), "2026-08-16")).toEqual({
      current: 1,
      longest: 1,
    });
  });

  it("treats duplicate-free unordered input the same (set semantics)", () => {
    const days = new Set(["2026-08-16", "2026-08-14", "2026-08-15"]);
    expect(computeStreaks(days, "2026-08-16").longest).toBe(3);
  });
});

describe("series math", () => {
  it("peakDay picks the max, earliest on ties, null when all zero", () => {
    expect(peakDay(pts(["2026-01-01", 5], ["2026-01-02", 9], ["2026-01-03", 9]))).toEqual({
      day: "2026-01-02",
      tokens: 9,
    });
    expect(peakDay(pts(["2026-01-01", 0]))).toBeNull();
    expect(peakDay([])).toBeNull();
  });

  it("activeDayCount ignores zero-token days", () => {
    expect(activeDayCount(pts(["2026-01-01", 5], ["2026-01-02", 0], ["2026-01-03", 1]))).toBe(2);
  });

  it("weeklyTotals buckets into Sunday-start weeks, ascending", () => {
    const weeks = weeklyTotals(
      pts(["2026-02-01", 1], ["2026-02-03", 2], ["2026-02-10", 4]),
    );
    expect(weeks).toEqual([
      { weekStart: "2026-02-01", tokens: 3 },
      { weekStart: "2026-02-08", tokens: 4 },
    ]);
  });
});

describe("intensityBucket", () => {
  it("zero activity and zero max both map to bucket 0", () => {
    expect(intensityBucket(0, 100)).toBe(0);
    expect(intensityBucket(50, 0)).toBe(0);
  });

  it("sqrt-scales against the max", () => {
    // ratios after sqrt: 1/16→0.25, 1/4→0.5, 9/16→0.75, 1→1
    expect(intensityBucket(100, 1600)).toBe(1);
    expect(intensityBucket(400, 1600)).toBe(2);
    expect(intensityBucket(900, 1600)).toBe(3);
    expect(intensityBucket(1600, 1600)).toBe(4);
  });
});
