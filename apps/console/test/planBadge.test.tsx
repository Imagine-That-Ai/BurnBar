// @vitest-environment jsdom
/**
 * Render-level gate for the PlanBadge membership lockup: paid tiers lead with
 * the cloud crest (the visual anchor) and stack the tier name over a "plan"
 * micro-label; free tier has no crest and stays a plain text pill.
 */
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it } from "vitest";

import { PlanBadge } from "../components/PlanBadge";

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

let container: HTMLDivElement;
let root: Root;

function render(tier: "free" | "pro" | "ultra") {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  act(() => {
    root.render(<PlanBadge tier={tier} />);
  });
  return container;
}

afterEach(() => {
  act(() => root.unmount());
  container.remove();
});

describe("PlanBadge", () => {
  it("leads with the ultra crest image for ultra tier", () => {
    const el = render("ultra");
    const img = el.querySelector("img");
    expect(img?.getAttribute("src")).toBe("/brand/burnbar_cloud_ultra_crest.svg");
    expect(el.textContent).toContain("ultra");
    expect(el.textContent?.toLowerCase()).toContain("plan");
  });

  it("uses the pro crest for pro tier", () => {
    const el = render("pro");
    expect(el.querySelector("img")?.getAttribute("src")).toBe(
      "/brand/burnbar_cloud_pro_crest.svg",
    );
  });

  it("renders a text-only pill for free tier", () => {
    const el = render("free");
    expect(el.querySelector("img")).toBeNull();
    expect(el.textContent).toContain("free plan");
  });
});
