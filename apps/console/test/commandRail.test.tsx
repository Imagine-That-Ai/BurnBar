// @vitest-environment jsdom
/**
 * Render-level gate for the Command Rail.
 *
 * navModel.test.ts pins the model; this pins the CHROME — the rail renders the
 * three intent groups in order, marks the current route with
 * aria-current="page", and keeps Panic OUT of the nav list entirely (it lives
 * quarantined in the rail footer, and only for signed-in members).
 */
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { CommandRail } from "../components/nav/CommandRail";

let pathname = "/profile";

vi.mock("next/navigation", () => ({
  usePathname: () => pathname,
}));

vi.mock("@/lib/useAuth", () => ({
  useAuth: () => ({ user: null, signOut: vi.fn() }),
}));

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

let container: HTMLDivElement;
let root: Root;

function render() {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  act(() => {
    root.render(<CommandRail onOpenPalette={() => {}} />);
  });
  return container;
}

afterEach(() => {
  act(() => root.unmount());
  container.remove();
});

describe("CommandRail", () => {
  it("renders the intent groups in order with every destination", () => {
    const el = render();
    const rail = el.querySelector("aside")!;
    const groupLabels = [...rail.querySelectorAll("nav .eyebrow")].map((p) => p.textContent);
    expect(groupLabels).toEqual(["Observe", "Vault", "System"]);
    const links = [...rail.querySelectorAll("nav a")].map((a) => a.textContent);
    expect(links).toEqual([
      "Profile",
      "Basin",
      "Studio",
      "Inventory",
      "Pensieve",
      "Trust",
      "Experimental",
      "Settings",
    ]);
  });

  it("marks the current route with aria-current and only that route", () => {
    pathname = "/pensieve";
    const el = render();
    const current = el.querySelectorAll('aside nav a[aria-current="page"]');
    expect(current.length).toBe(1);
    expect(current[0].getAttribute("href")).toBe("/pensieve");
    expect(current[0].textContent).toBe("Pensieve");
  });

  it("keeps Panic out of the navigation list", () => {
    pathname = "/";
    const el = render();
    const navText = el.querySelector("aside nav")!.textContent ?? "";
    expect(navText).not.toContain("Panic");
  });

  it("offers the ⌘K jump-to affordance", () => {
    const el = render();
    const jump = [...el.querySelectorAll("aside button")].find((b) =>
      b.textContent?.includes("Jump to"),
    );
    expect(jump).toBeTruthy();
    expect(jump!.textContent).toContain("⌘K");
  });

  it("hides identity, sign-out, and Panic when signed out", () => {
    const el = render();
    const railText = el.querySelector("aside")!.textContent ?? "";
    expect(railText).not.toContain("Sign out");
    expect(railText).not.toContain("Panic");
  });
});
