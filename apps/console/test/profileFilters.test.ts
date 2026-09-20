/**
 * Filter model contract for the mineable /profile explorer:
 * URL parse/serialize round-trips, window slicing, rollup-vs-event routing,
 * and the 91k-event All+facet snap guard.
 */
import { describe, expect, it } from "vitest";

import {
  clearMineFilters,
  effectiveRange,
  emptyFilters,
  needsEventPath,
  parseProfileFilters,
  serializeProfileFilters,
  sliceDailyPoints,
  snapWindowForEventFacets,
  toggleFacetValue,
  unsupportedRollupFacets,
} from "../lib/profile/profileFilters";
import type { DailyPoint } from "../lib/usage";

function pts(...entries: [string, number][]): DailyPoint[] {
  return entries.map(([day, tokens]) => ({ day, tokens }));
}

describe("parseProfileFilters", () => {
  it("defaults to All + tokens + no facets", () => {
    expect(parseProfileFilters("")).toEqual(emptyFilters());
    expect(parseProfileFilters("?")).toEqual(emptyFilters());
  });

  it("parses the full shareable query", () => {
    const f = parseProfileFilters(
      "?w=90d&p=claude-code,codex&m=gpt-5.3&h=claude-code&a=acct-1&d=mac&metric=spend&day=2026-09-01",
    );
    expect(f.window).toBe("90d");
    expect(f.facets.providers).toEqual(["claude-code", "codex"]);
    expect(f.facets.models).toEqual(["gpt-5.3"]);
    expect(f.facets.harnesses).toEqual(["claude-code"]);
    expect(f.facets.accounts).toEqual(["acct-1"]);
    expect(f.facets.devices).toEqual(["mac"]);
    expect(f.metric).toBe("spend");
    expect(f.day).toBe("2026-09-01");
  });

  it("parses custom dates and the entity focus", () => {
    const f = parseProfileFilters("?from=2026-08-01&to=2026-08-16&entity=model:gpt-5.3");
    expect(f.from).toBe("2026-08-01");
    expect(f.to).toBe("2026-08-16");
    expect(f.entity).toEqual({ kind: "model", id: "gpt-5.3" });
  });

  it("rejects malformed days, windows, metrics, and entities", () => {
    const f = parseProfileFilters("?w=forever&day=not-a-day&metric=money&entity=bogus");
    expect(f.window).toBe("all");
    expect(f.day).toBeNull();
    expect(f.metric).toBe("tokens");
    expect(f.entity).toBeNull();
  });

  it("dedupes facet values", () => {
    expect(parseProfileFilters("?p=a,a,b").facets.providers).toEqual(["a", "b"]);
  });
});

describe("serializeProfileFilters", () => {
  it("serializes defaults to the empty string", () => {
    expect(serializeProfileFilters(emptyFilters())).toBe("");
  });

  it("round-trips a full filter set", () => {
    const f = parseProfileFilters(
      "?w=30d&from=2026-08-01&to=2026-08-16&p=a&m=b&h=c&a=d&d=e&metric=runs&day=2026-08-16&entity=session:abc",
    );
    expect(parseProfileFilters(serializeProfileFilters(f))).toEqual(f);
  });
});

describe("effectiveRange + sliceDailyPoints", () => {
  const points = pts(
    ["2026-08-01", 10],
    ["2026-08-10", 20],
    ["2026-08-16", 30],
  );

  it("presets anchor on today", () => {
    expect(effectiveRange({ window: "7d", from: null, to: null }, "2026-08-16")).toEqual({
      fromDay: "2026-08-10",
      toDay: "2026-08-16",
    });
    expect(effectiveRange({ window: "all", from: null, to: null }, "2026-08-16")).toEqual({
      fromDay: null,
      toDay: "2026-08-16",
    });
  });

  it("custom dates override the preset", () => {
    expect(
      effectiveRange({ window: "all", from: "2026-08-01", to: "2026-08-10" }, "2026-08-16"),
    ).toEqual({ fromDay: "2026-08-01", toDay: "2026-08-10" });
  });

  it("slices the daily series to the active range", () => {
    const sliced = sliceDailyPoints(
      points,
      { window: "7d", from: null, to: null },
      "2026-08-16",
    );
    expect(sliced.map((p) => p.day)).toEqual(["2026-08-10", "2026-08-16"]);
  });

  it("All keeps every day up to today", () => {
    const sliced = sliceDailyPoints(
      [...points, { day: "2026-08-17", tokens: 99 }],
      { window: "all", from: null, to: null },
      "2026-08-16",
    );
    expect(sliced.map((p) => p.day)).toEqual(["2026-08-01", "2026-08-10", "2026-08-16"]);
  });
});

describe("rollup-vs-event routing", () => {
  it("provider-only filters stay on the rollup", () => {
    const f = { ...emptyFilters(), facets: { ...emptyFilters().facets, providers: ["a"] } };
    expect(unsupportedRollupFacets(f)).toEqual([]);
    expect(needsEventPath(f)).toBe(false);
  });

  it("model/harness/account/device facets need the event path", () => {
    for (const group of ["models", "harnesses", "accounts", "devices"] as const) {
      const f = { ...emptyFilters(), facets: { ...emptyFilters().facets, [group]: ["x"] } };
      expect(unsupportedRollupFacets(f)).toContain(group);
      expect(needsEventPath(f)).toBe(true);
    }
  });

  it("a pinned day or entity forces the event path", () => {
    expect(needsEventPath({ ...emptyFilters(), day: "2026-08-16" })).toBe(true);
    expect(
      needsEventPath({ ...emptyFilters(), entity: { kind: "model", id: "x" } }),
    ).toBe(true);
  });
});

describe("snapWindowForEventFacets (the 91k guard)", () => {
  it("snaps All + a model filter to 90d", () => {
    const f = { ...emptyFilters(), facets: { ...emptyFilters().facets, models: ["gpt-5.3"] } };
    expect(snapWindowForEventFacets(f)).toMatchObject({ window: "90d" });
  });

  it("leaves non-All, custom-range, and rollup-only filters alone", () => {
    expect(snapWindowForEventFacets(emptyFilters())).toBeNull();
    const preset = {
      ...emptyFilters(),
      window: "30d" as const,
      facets: { ...emptyFilters().facets, models: ["x"] },
    };
    expect(snapWindowForEventFacets(preset)).toBeNull();
    const custom = {
      ...emptyFilters(),
      from: "2026-08-01",
      facets: { ...emptyFilters().facets, models: ["x"] },
    };
    expect(snapWindowForEventFacets(custom)).toBeNull();
  });
});

describe("toggleFacetValue + clearMineFilters", () => {
  it("toggles add/remove", () => {
    expect(toggleFacetValue([], "a")).toEqual(["a"]);
    expect(toggleFacetValue(["a", "b"], "a")).toEqual(["b"]);
  });

  it("clear keeps the metric", () => {
    const f = {
      ...emptyFilters(),
      window: "30d" as const,
      metric: "spend" as const,
      facets: { ...emptyFilters().facets, models: ["x"] },
    };
    expect(clearMineFilters(f)).toMatchObject({ window: "all", metric: "spend" });
    expect(clearMineFilters(f).facets.models).toEqual([]);
  });
});
