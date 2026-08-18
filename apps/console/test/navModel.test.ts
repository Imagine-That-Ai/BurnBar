/**
 * The nav model is the single source of truth for the CommandRail and the ⌘K
 * palette: group order, destination membership, active-route resolution, and
 * fuzzy filtering all pin here so both surfaces can never drift apart.
 */
import { describe, expect, it } from "vitest";

import {
  filterPaletteEntries,
  groupPaletteEntries,
  isNavActive,
  NAV_GROUPS,
  navPaletteEntries,
} from "../components/nav/navModel";

describe("NAV_GROUPS", () => {
  it("groups destinations by intent in the Observe → Vault → System rhythm", () => {
    expect(NAV_GROUPS.map((g) => g.label)).toEqual(["Observe", "Vault", "System"]);
  });

  it("leads Observe with Profile, then Basin, then Studio", () => {
    const observe = NAV_GROUPS[0];
    expect(observe.items.map((i) => i.label)).toEqual(["Profile", "Basin", "Studio"]);
  });

  it("covers every console route exactly once", () => {
    const hrefs = NAV_GROUPS.flatMap((g) => g.items.map((i) => i.href)).sort();
    expect(hrefs).toEqual(
      ["/", "/dashboard", "/escrow", "/experimental", "/inventory", "/pensieve", "/profile", "/settings"].sort(),
    );
  });
});

describe("isNavActive", () => {
  it("exact-matches routes, including the root", () => {
    expect(isNavActive("/profile", "/profile")).toBe(true);
    expect(isNavActive("/", "/")).toBe(true);
    expect(isNavActive("/dashboard", "/")).toBe(false);
    expect(isNavActive("/profile", "/")).toBe(false);
  });
});

describe("filterPaletteEntries", () => {
  const entries = navPaletteEntries();

  it("returns everything in group order for an empty query", () => {
    const result = filterPaletteEntries(entries, "");
    expect(result.map((e) => e.label)).toEqual(entries.map((e) => e.label));
  });

  it("matches on label prefix before label substring", () => {
    const result = filterPaletteEntries(entries, "pen");
    expect(result.map((e) => e.label)).toEqual(["Pensieve"]);
  });

  it("matches keywords that never appear in the label", () => {
    expect(filterPaletteEntries(entries, "escrow").map((e) => e.label)).toEqual(["Trust"]);
    expect(filterPaletteEntries(entries, "tokens").map((e) => e.label)).toEqual(["Profile"]);
    expect(filterPaletteEntries(entries, "home").map((e) => e.label)).toEqual(["Basin"]);
  });

  it("is case-insensitive and trims whitespace", () => {
    expect(filterPaletteEntries(entries, "  STUDIO ").map((e) => e.label)).toEqual(["Studio"]);
  });

  it("returns an empty list when nothing matches", () => {
    expect(filterPaletteEntries(entries, "zzzz")).toEqual([]);
  });
});

describe("groupPaletteEntries", () => {
  it("merges rows under their section, preserving first-seen order", () => {
    const filtered = filterPaletteEntries(navPaletteEntries(), "e");
    const groups = groupPaletteEntries(filtered);
    // Every section appears at most once, and rows carry their group's label.
    expect(groups.map(([label]) => label)).toEqual([...new Set(filtered.map((e) => e.group))]);
    for (const [label, rows] of groups) {
      for (const row of rows) expect(row.group).toBe(label);
    }
  });

  it("keeps score-sorted results merged into single sections", () => {
    // "s" matches several groups at different ranks; sections must not repeat.
    const filtered = filterPaletteEntries(navPaletteEntries(), "s");
    const labels = groupPaletteEntries(filtered).map(([label]) => label);
    expect(new Set(labels).size).toBe(labels.length);
  });
});
