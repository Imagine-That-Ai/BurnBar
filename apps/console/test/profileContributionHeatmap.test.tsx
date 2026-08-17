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

function render(
  points: DailyPoint[],
  mode: "daily" | "weekly" | "cumulative",
  today = TODAY,
  dailyProviderTokens?: Record<string, Record<string, number>>,
) {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  act(() => {
    root.render(
      <ContributionHeatmap
        points={points}
        mode={mode}
        today={today}
        dailyProviderTokens={dailyProviderTokens}
      />,
    );
  });
  return container;
}

/** Hover a day cell. React synthesizes mouseenter from a bubbling mouseover. */
function hoverDay(el: HTMLElement, dayLabelPrefix: string) {
  const rect = [...el.querySelectorAll("rect")].find((r) =>
    r.getAttribute("aria-label")?.startsWith(dayLabelPrefix),
  );
  expect(rect, `cell for ${dayLabelPrefix}`).toBeTruthy();
  act(() => {
    rect!.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
  });
  return rect!;
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

  it("grids from the earliest day even when points arrive unsorted", () => {
    const el = render(pts(["2026-08-16", 300], ["2026-08-14", 100]), "daily");
    const labels = [...el.querySelectorAll("rect")].map((r) => r.getAttribute("aria-label"));
    expect(labels.some((l) => l?.startsWith("Aug 14"))).toBe(true);
    expect(labels.some((l) => l?.startsWith("Aug 13"))).toBe(false);
  });

  it("never crowds month labels — a late-month start drops the next label", () => {
    // Grid starts Sat Aug 29 2026 (column 0 = week of Aug 23, labeled "Aug").
    // September's first column is only one column over, so "Sep" must not
    // render cheek-by-jowl with "Aug".
    const el = render(pts(["2026-08-29", 100]), "daily", "2026-09-01");
    const texts = [...el.querySelectorAll("text")].map((t) => t.textContent);
    expect(texts).toContain("Aug");
    expect(texts).not.toContain("Sep");
  });

  it("renders the Less→More scale legend with the five grid swatches", () => {
    const el = render(pts(["2026-08-14", 100]), "daily");
    const legend = el.querySelector('[aria-label="Heatmap scale from less to more tokens"]');
    expect(legend).toBeTruthy();
    expect(legend?.textContent).toBe("LessMore");
    expect(legend?.querySelectorAll("span[aria-hidden]").length).toBe(5);
  });

  it("hovering a day opens the card with the exact token count, and leaving closes it", () => {
    const el = render(pts(["2026-08-14", 123_456]), "daily");
    expect(el.textContent).not.toContain("123,456");
    const rect = hoverDay(el, "Aug 14");
    expect(el.textContent).toContain("123,456");
    expect(el.textContent).toContain("tokens");
    // The hovered cell gets the accent-deep stroke ring.
    expect(rect.getAttribute("stroke")).toBe("var(--accent-deep)");
    const svg = el.querySelector("svg")!;
    act(() => {
      svg.dispatchEvent(new MouseEvent("mouseout", { bubbles: true }));
    });
    expect(el.textContent).not.toContain("123,456");
  });

  it("hover card breaks the day down by provider when the split is present", () => {
    const el = render(pts(["2026-08-14", 1000]), "daily", TODAY, {
      "2026-08-14": { anthropic: 500, openai: 300, moonshot: 150, google: 50 },
    });
    hoverDay(el, "Aug 14");
    const card = el.querySelector(".glass-pane--elevated")!;
    expect(card.textContent).toContain("anthropic");
    expect(card.textContent).toContain("50%");
    expect(card.textContent).toContain("openai");
    expect(card.textContent).toContain("30%");
    expect(card.textContent).toContain("moonshot");
    expect(card.textContent).toContain("15%");
    // Fourth provider folds into "other".
    expect(card.textContent).not.toContain("google");
    expect(card.textContent).toContain("other");
    expect(card.textContent).toContain("5%");
  });

  it("hover card shows tokens only when the day has no provider split", () => {
    const el = render(pts(["2026-08-14", 700]), "daily", TODAY, {});
    hoverDay(el, "Aug 14");
    const card = el.querySelector(".glass-pane--elevated")!;
    expect(card.textContent).toContain("700");
    expect(card.querySelector("ul")).toBeNull();
  });

  it("provider split stays out of weekly mode even when data exists", () => {
    const el = render(pts(["2026-08-14", 1000]), "weekly", TODAY, {
      "2026-08-14": { anthropic: 1000 },
    });
    hoverDay(el, "Week of Aug 9");
    const card = el.querySelector(".glass-pane--elevated")!;
    expect(card.textContent).toContain("1,000");
    expect(card.textContent).toContain("tokens that week");
    expect(card.querySelector("ul")).toBeNull();
  });

  it("positions the card above mid-grid cells and flips it below the top rows", () => {
    // 2026-08-16 is a Sunday → row 0; 2026-08-18 is a Tuesday → row 2.
    const el = render(pts(["2026-08-16", 100], ["2026-08-18", 200]), "daily", "2026-08-22");
    hoverDay(el, "Aug 16");
    let card = el.querySelector<HTMLElement>(".glass-pane--elevated")!;
    expect(card.style.transform).toBe("translate(-50%, 0)"); // flipped below
    hoverDay(el, "Aug 18");
    card = el.querySelector<HTMLElement>(".glass-pane--elevated")!;
    expect(card.style.transform).toBe("translate(-50%, -100%)"); // above
  });
});
