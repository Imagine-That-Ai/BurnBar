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
  dailyModelTokens?: Record<string, Record<string, number>>,
  dailyModelProviders?: Record<string, Record<string, string>>,
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
        dailyModelTokens={dailyModelTokens}
        dailyModelProviders={dailyModelProviders}
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
    expect(document.body.textContent).not.toContain("123,456");
    const rect = hoverDay(el, "Aug 14");
    // Portaled to the body so the scroll container can never clip it.
    expect(document.body.textContent).toContain("123,456");
    expect(document.body.textContent).toContain("tokens");
    // The hovered cell gets the accent-deep stroke ring.
    expect(rect.getAttribute("stroke")).toBe("var(--accent-deep)");
    const svg = el.querySelector("svg")!;
    act(() => {
      svg.dispatchEvent(new MouseEvent("mouseout", { bubbles: true }));
    });
    expect(document.body.textContent).not.toContain("123,456");
  });

  it("hover card breaks the day down by provider when the split is present", () => {
    const el = render(pts(["2026-08-14", 1000]), "daily", TODAY, {
      "2026-08-14": { anthropic: 500, openai: 300, moonshot: 150, google: 50 },
    });
    hoverDay(el, "Aug 14");
    const card = document.querySelector(".glass-pane--elevated")!;
    expect(card.textContent).toContain("Anthropic");
    expect(card.textContent).toContain("50%");
    expect(card.textContent).toContain("OpenAI");
    expect(card.textContent).toContain("30%");
    expect(card.textContent).toContain("Moonshot");
    expect(card.textContent).toContain("15%");
    // Fourth provider folds into "other".
    expect(card.textContent).not.toContain("Google");
    expect(card.textContent).toContain("other");
    expect(card.textContent).toContain("5%");
  });

  it("hover card shows tokens only when the day has no provider split", () => {
    const el = render(pts(["2026-08-14", 700]), "daily", TODAY, {});
    hoverDay(el, "Aug 14");
    const card = document.querySelector(".glass-pane--elevated")!;
    expect(card.textContent).toContain("700");
    expect(card.querySelector("ul")).toBeNull();
  });

  it("provider split stays out of weekly mode even when data exists", () => {
    const el = render(pts(["2026-08-14", 1000]), "weekly", TODAY, {
      "2026-08-14": { anthropic: 1000 },
    });
    hoverDay(el, "Week of Aug 9");
    const card = document.querySelector(".glass-pane--elevated")!;
    expect(card.textContent).toContain("1,000");
    expect(card.textContent).toContain("tokens that week");
    expect(card.querySelector("ul")).toBeNull();
  });

  it("positions the card above mid-grid cells and flips it below the top rows", () => {
    const el = render(pts(["2026-08-16", 100], ["2026-08-18", 200]), "daily", "2026-08-22");
    const mockRect = (node: Element, x: number, y: number) => {
      node.getBoundingClientRect = () =>
        ({ x, y, width: 11, height: 11, top: y, left: x } as DOMRect);
    };
    const sunday = [...el.querySelectorAll("rect")].find((r) =>
      r.getAttribute("aria-label")?.startsWith("Aug 16"),
    )!;
    const tuesday = [...el.querySelectorAll("rect")].find((r) =>
      r.getAttribute("aria-label")?.startsWith("Aug 18"),
    )!;
    // Top-docked cell: no room above → flipped below.
    mockRect(sunday, 600, 10);
    act(() => {
      sunday.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    });
    let card = document.querySelector<HTMLElement>(".glass-pane--elevated")!;
    expect(card.dataset.placement).toBe("below");
    // Mid-grid cell: floats above.
    mockRect(tuesday, 600, 400);
    act(() => {
      tuesday.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    });
    card = document.querySelector<HTMLElement>(".glass-pane--elevated")!;
    expect(card.dataset.placement).toBe("above");
  });

  it("dismisses the card on scroll instead of stranding it", () => {
    const el = render(pts(["2026-08-14", 123_456]), "daily");
    hoverDay(el, "Aug 14");
    expect(document.querySelector(".glass-pane--elevated")).toBeTruthy();
    act(() => {
      window.dispatchEvent(new Event("scroll"));
    });
    expect(document.querySelector(".glass-pane--elevated")).toBeNull();
  });

  it("paints daily cells in the dominant provider's brand hue", () => {
    const el = render(pts(["2026-08-14", 1000]), "daily", TODAY, {
      "2026-08-14": { anthropic: 800, openai: 200 },
    });
    const cell = [...el.querySelectorAll("rect")].find((r) =>
      r.getAttribute("aria-label")?.startsWith("Aug 14"),
    )!;
    // Anthropic wins 800/1000 — the cell wears its fill, not the accent.
    expect(cell.getAttribute("fill")).not.toBe("var(--accent)");
    expect(cell.getAttribute("fill")).toContain("#CC785C");
    const title = cell.querySelector("title")!;
    expect(title.textContent).toContain("Anthropic leads");
  });

  it("falls back to the accent when a day has no split", () => {
    const el = render(pts(["2026-08-14", 1000]), "daily", TODAY, {
      "2026-08-15": { anthropic: 500 },
    });
    const cell = [...el.querySelectorAll("rect")].find((r) =>
      r.getAttribute("aria-label")?.startsWith("Aug 14"),
    )!;
    expect(cell.getAttribute("fill")).toBe("var(--accent)");
  });

  it("paints daily cells by dominant model when the provider split is absent", () => {
    const el = render(
      pts(["2026-08-14", 1000]),
      "daily",
      TODAY,
      undefined,
      { "2026-08-14": { "gpt-5.3": 700, "kimi-k2": 300 } },
    );
    const cell = [...el.querySelectorAll("rect")].find((r) =>
      r.getAttribute("aria-label")?.startsWith("Aug 14"),
    )!;
    expect(cell.getAttribute("fill")).not.toBe("var(--accent)");
    // Model mix reaches the hover card when providers can't.
    hoverDay(el, "Aug 14");
    const card = document.querySelector(".glass-pane--elevated")!;
    expect(card.textContent).toContain("GPT 5.3");
    expect(card.textContent).toContain("70%");
  });

  it("blends weekly columns across the week's top shares", () => {
    const el = render(pts(["2026-08-14", 600], ["2026-08-15", 400]), "weekly", TODAY, {
      "2026-08-14": { anthropic: 600 },
      "2026-08-15": { openai: 400 },
    });
    const labels = [...el.querySelectorAll("rect")].map((r) => r.getAttribute("aria-label"));
    const weekLabel = labels.find((l) => l?.startsWith("Week of Aug 9"));
    expect(weekLabel).toBe("Week of Aug 9, 2026 — 1K tokens");
    const cell = [...el.querySelectorAll("rect")].find(
      (r) => r.getAttribute("aria-label") === weekLabel,
    )!;
    // Multi-share weeks reference a real SVG paint server, not a CSS string.
    const fill = cell.getAttribute("fill") ?? "";
    expect(fill.startsWith("url(#profile-week-")).toBe(true);
    const gradId = fill.slice(5, -1); // strip `url(#` … `)`
    const grad = [...el.querySelectorAll("linearGradient")].find(
      (g) => g.getAttribute("id") === gradId,
    )!;
    expect(grad).toBeTruthy();
    const offsets = [...grad.querySelectorAll("stop")].map((s) =>
      s.getAttribute("offset"),
    );
    // 60/40 hard-stop bands: 0→60, 60→100.
    expect(offsets).toEqual(["0.0%", "60.0%", "60.0%", "100.0%"]);
    // This is the peak week, so it paints at full bucket opacity (magnitude
    // encoding is pinned separately in "paints single-share weeks solid").
    expect(cell.getAttribute("fill-opacity")).toBe("1");
  });

  it("paints single-share weeks solid with bucket opacity", () => {
    // Two weeks: a quiet 100-token week and a 1,600-token peak week, so the
    // bucket opacity differs between them (magnitude still encodes).
    const el = render(pts(["2026-08-09", 100], ["2026-08-16", 1600]), "weekly", TODAY, {
      "2026-08-09": { anthropic: 100 },
      "2026-08-16": { anthropic: 1600 },
    });
    const quiet = [...el.querySelectorAll("rect")].find((r) =>
      r.getAttribute("aria-label")?.startsWith("Week of Aug 9"),
    )!;
    // One share → solid dominant fill, no paint-server indirection.
    expect(quiet.getAttribute("fill")).toContain("#CC785C");
    // sqrt(100/1600) = 0.25 → bucket 1 → 0.28, dimmer than the peak week.
    expect(quiet.getAttribute("fill-opacity")).toBe("0.28");
    const peak = [...el.querySelectorAll("rect")].find((r) =>
      r.getAttribute("aria-label")?.startsWith("Week of Aug 16"),
    )!;
    expect(peak.getAttribute("fill-opacity")).toBe("1");
  });

  it("names the weekly leader from the weekly aggregate", () => {
    const el = render(pts(["2026-08-14", 600], ["2026-08-15", 400]), "weekly", TODAY, {
      "2026-08-14": { anthropic: 600 },
      "2026-08-15": { openai: 400 },
    });
    const titles = [...el.querySelectorAll("rect")].map(
      (r) => r.querySelector("title")?.textContent ?? "",
    );
    const weekTitles = titles.filter((t) => t.startsWith("Week of Aug 9"));
    expect(weekTitles.length).toBeGreaterThan(1);
    // Every row in the column names the WEEK winner (anthropic 600 > 400).
    for (const t of weekTitles) expect(t).toContain("Anthropic leads");
  });

  it("restricts weekly blends to the displayed range", () => {
    // Points cover Aug 14–16 only, but the split map carries an older day.
    const el = render(pts(["2026-08-14", 100], ["2026-08-16", 100]), "weekly", TODAY, {
      "2026-08-01": { openai: 9_999 },
      "2026-08-14": { anthropic: 100 },
      "2026-08-16": { anthropic: 100 },
    });
    const cell = [...el.querySelectorAll("rect")].find((r) =>
      r.getAttribute("aria-label")?.startsWith("Week of Aug 9"),
    )!;
    const title = cell.querySelector("title")!;
    // Aug 1 (out of range) must not leak into the week's color or leader.
    expect(title.textContent).toContain("Anthropic leads");
    expect(title.textContent).not.toContain("OpenAI");
  });

  it("falls back to model blends when the provider map is empty", () => {
    const el = render(
      pts(["2026-08-14", 600], ["2026-08-15", 400]),
      "weekly",
      TODAY,
      {},
      { "2026-08-14": { "gpt-5.3": 600 }, "2026-08-15": { "kimi-k2": 400 } },
    );
    const cell = [...el.querySelectorAll("rect")].find((r) =>
      r.getAttribute("aria-label")?.startsWith("Week of Aug 9"),
    )!;
    const fill = cell.getAttribute("fill") ?? "";
    expect(fill.startsWith("url(#profile-week-")).toBe(true);
  });

  it("colors model cells by stored provider, not the model prefix", () => {
    const el = render(
      pts(["2026-08-14", 1000]),
      "daily",
      TODAY,
      undefined,
      { "2026-08-14": { "gpt-5.3": 1000 } },
      { "2026-08-14": { "gpt-5.3": "openai" } },
    );
    const cell = [...el.querySelectorAll("rect")].find((r) =>
      r.getAttribute("aria-label")?.startsWith("Aug 14"),
    )!;
    // OpenAI's brand (#00A67E), not the generic accent the raw id resolves to.
    expect(cell.getAttribute("fill")).toContain("#00A67E");
  });

  it("adds an other row when the model hover truncates", () => {
    const el = render(
      pts(["2026-08-14", 1000]),
      "daily",
      TODAY,
      undefined,
      {
        "2026-08-14": { a: 400, b: 300, c: 150, d: 100, e: 50 },
      },
    );
    hoverDay(el, "Aug 14");
    const card = document.querySelector(".glass-pane--elevated")!;
    expect(card.textContent).toContain("other");
    expect(card.textContent).toContain("5%");
  });
});
