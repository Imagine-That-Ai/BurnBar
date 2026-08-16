// @vitest-environment jsdom
/**
 * Render-level gate for the profile contribution heatmap.
 *
 * activityStats.test.ts pins the math; this pins the GRID — future days must
 * never render cells, days before the first activity stay blank, active days
 * get accent fills with hover labels, and the Weekly mode lifts every cell in
 * a column to the week's total.
 */
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it } from "vitest";

import { ContributionHeatmap } from "../components/profile/ContributionHeatmap";
import type { DailyPoint } from "../lib/usage";

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

const TODAY = "2026-08-16"; // a Sunday

function pts(...entries: [string, number][]): DailyPoint[] {
  return entries.map(([day, tokens]) => ({ day, tokens }));
}

let container: HTMLDivElement;
let root: Root;

function render(points: DailyPoint[], mode: "daily" | "weekly" | "cumulative") {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  act(() => {
    root.render(<ContributionHeatmap points={points} mode={mode} today={TODAY} />);
  });
  return container;
}

afterEach(() => {
  act(() => root.unmount());
  container.remove();
});

describe("ContributionHeatmap", () => {
  it("renders one cell per day from first activity through today, never future days", () => {
    const el = render(pts(["2026-08-14", 100], ["2026-08-16", 300]), "daily");
    const rects = el.querySelectorAll("rect");
    // 2026-08-14, 15, 16 — three days, no cells for the future week days.
    expect(rects.length).toBe(3);
    const labels = [...rects].map((r) => r.getAttribute("aria-label"));
    expect(labels.some((l) => l?.startsWith("Aug 14"))).toBe(true);
    expect(labels.some((l) => l?.startsWith("Aug 17"))).toBe(false);
  });

  it("fills active days with the accent and empties with the wash", () => {
    const el = render(pts(["2026-08-14", 100]), "daily");
    const active = [...el.querySelectorAll("rect")].find(
      (r) => r.getAttribute("fill") === "var(--accent)",
    );
    expect(active?.getAttribute("aria-label")).toBe("Aug 14, 2026 — 100 tokens");
    const empties = [...el.querySelectorAll("rect")].filter(
      (r) => r.getAttribute("fill") === "var(--color-mercury-wash)",
    );
    expect(empties.length).toBeGreaterThan(0);
  });

  it("weekly mode gives every active-week cell the week's total", () => {
    const el = render(pts(["2026-08-14", 100], ["2026-08-15", 200]), "weekly");
    const labels = [...el.querySelectorAll("rect")].map((r) => r.getAttribute("aria-label"));
    // Aug 14–15 share the week starting Sunday Aug 9; Aug 16 opens a new week.
    expect(labels.filter((l) => l === "Week of Aug 9, 2026 — 300 tokens").length).toBe(2);
    expect(labels).toContain("Week of Aug 16, 2026 — 0 tokens");
  });

  it("cumulative mode labels carry the running total", () => {
    const el = render(pts(["2026-08-14", 100], ["2026-08-16", 300]), "cumulative");
    const labels = [...el.querySelectorAll("rect")].map((r) => r.getAttribute("aria-label"));
    expect(labels).toContain("Aug 14, 2026 — 100 total");
    expect(labels).toContain("Aug 16, 2026 — 400 total");
  });

  it("with no activity, renders a year of empty cells and zero state", () => {
    const el = render([], "daily");
    const rects = el.querySelectorAll("rect");
    expect(rects.length).toBeGreaterThan(360);
    expect(
      [...rects].every((r) => r.getAttribute("fill") === "var(--color-mercury-wash)"),
    ).toBe(true);
  });
});
