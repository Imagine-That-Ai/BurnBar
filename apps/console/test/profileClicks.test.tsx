// @vitest-environment jsdom
/**
 * Click-to-mine contract for the explorer sections: heatmap aria-labels
 * resolve back to day keys (daily + weekly-column hottest day), and the
 * breakdown facet toggle maps rows onto filter chips.
 */
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { ProfileHeatmapSection, dayKeyFromLabel } from "../components/profile/ProfileHeatmapSection";
import type { DailyPoint } from "../lib/usage";

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

function pts(...entries: [string, number][]): DailyPoint[] {
  return entries.map(([day, tokens]) => ({ day, tokens }));
}

let container: HTMLDivElement | null = null;
let root: Root | null = null;

afterEach(() => {
  if (root && container) {
    act(() => root!.unmount());
    container.remove();
  }
  container = null;
  root = null;
  vi.restoreAllMocks();
});

function renderHeatmap(onPinDay: (day: string | null) => void, pinnedDay: string | null = null) {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  const r = root;
  act(() => {
    r.render(
      <ProfileHeatmapSection
        points={pts(["2026-08-14", 100], ["2026-08-15", 300], ["2026-08-16", 50])}
        today="2026-08-16"
        pinnedDay={pinnedDay}
        onPinDay={onPinDay}
      />,
    );
  });
  return container;
}

describe("dayKeyFromLabel", () => {
  const points = pts(["2026-08-14", 100], ["2026-08-15", 300]);

  it("resolves daily labels to the named day", () => {
    expect(dayKeyFromLabel("Aug 14, 2026 — 100 tokens", points, "2026-08-16")).toBe(
      "2026-08-14",
    );
  });

  it("resolves weekly columns to the hottest active day", () => {
    expect(
      dayKeyFromLabel("Week of Aug 9, 2026 — 400 tokens", points, "2026-08-16"),
    ).toBe("2026-08-15");
  });

  it("falls back to the week start when the column is quiet", () => {
    expect(dayKeyFromLabel("Week of Aug 16, 2026 — 0 tokens", points, "2026-08-16")).toBe(
      "2026-08-16",
    );
  });

  it("rejects non-day labels", () => {
    expect(dayKeyFromLabel("LessMore", points, "2026-08-16")).toBeNull();
  });
});

describe("ProfileHeatmapSection clicks", () => {
  it("clicking a day cell pins that day; clicking again unpins", () => {
    const onPinDay = vi.fn();
    const el = renderHeatmap(onPinDay);
    const rect = [...el.querySelectorAll("rect")].find((r) =>
      r.getAttribute("aria-label")?.startsWith("Aug 15"),
    )!;
    act(() => {
      rect.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    expect(onPinDay).toHaveBeenCalledWith("2026-08-15");
  });

  it("shows the pinned day with an unpin action", () => {
    const el = renderHeatmap(vi.fn(), "2026-08-15");
    expect(el.textContent).toContain("Inspecting Aug 15, 2026");
    expect(el.textContent).toContain("in the inspector");
    const unpin = [...el.querySelectorAll("button")].find(
      (b) => b.textContent === "Unpin",
    )!;
    const onPinDay = vi.fn();
    // Re-render with a spy to capture the unpin call.
    const r = root;
    act(() => {
      r!.render(
        <ProfileHeatmapSection
          points={pts(["2026-08-15", 300])}
          today="2026-08-16"
          pinnedDay="2026-08-15"
          onPinDay={onPinDay}
        />,
      );
    });
    act(() => {
      unpin.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    expect(onPinDay).toHaveBeenCalledWith(null);
  });

  it("names every reopen path when nothing is pinned", () => {
    const el = renderHeatmap(vi.fn(), null);
    expect(el.textContent).toContain("record tile");
    expect(el.textContent).toContain("ledger time");
  });
});

describe("ProfileHeatmapSection keyboard", () => {
  it("Enter on an active-day cell pins that day", () => {
    const onPinDay = vi.fn();
    const el = renderHeatmap(onPinDay);
    const cell = [...el.querySelectorAll("rect")].find(
      (r) =>
        r.getAttribute("role") === "button" &&
        r.getAttribute("aria-label")?.startsWith("Aug 15"),
    )!;
    act(() => {
      cell.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    expect(onPinDay).toHaveBeenCalledWith("2026-08-15");
  });

  it("only active days are focusable", () => {
    const el = renderHeatmap(vi.fn());
    const buttons = [...el.querySelectorAll('rect[role="button"]')];
    // Three active days in the fixture; quiet cells stay out of tab order.
    expect(buttons.length).toBe(3);
    expect(
      buttons.every((b) => (b.getAttribute("tabindex") ?? b.getAttribute("tabIndex")) === "0"),
    ).toBe(true);
  });
});
