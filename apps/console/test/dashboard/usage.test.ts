import { describe, expect, it } from "vitest";

import {
  currentMonthKey,
  emptyRollup,
  normalizeAllowance,
  normalizeQuotaSnapshot,
  normalizeRollup,
} from "@/lib/usage";

describe("normalizeRollup", () => {
  it("returns a zeroed rollup for non-object input", () => {
    expect(normalizeRollup(null, "30d")).toEqual(emptyRollup("30d"));
    expect(normalizeRollup("garbage", "7d")).toEqual(emptyRollup("7d"));
  });

  it("coerces totals defensively (missing / non-numeric → 0)", () => {
    const r = normalizeRollup({ totals: { requests: 5, tokens: "x", costUsd: NaN } }, "today");
    expect(r.totals.requests).toBe(5);
    expect(r.totals.tokens).toBe(0);
    expect(r.totals.costUsd).toBe(0);
  });

  it("sorts provider summaries by cost desc and fills defaults", () => {
    const r = normalizeRollup(
      {
        providerSummaries: [
          { provider: "openai", totalCost: 2, totalTokens: 10, totalRequests: 1 },
          { provider: "anthropic", totalCost: 9, totalTokens: 99 },
          { notAProvider: true },
        ],
      },
      "30d",
    );
    expect(r.providerSummaries.map((p) => p.provider)).toEqual(["anthropic", "openai", "unknown"]);
    expect(r.providerSummaries[1]!.totalRequests).toBe(1);
    expect(r.providerSummaries[2]!.totalCost).toBe(0);
  });

  it("flattens the dailyPoints map into an ascending-by-day series", () => {
    const r = normalizeRollup(
      { dailyPoints: { "2026-06-03": 30, "2026-06-01": 10, "2026-06-02": 20 } },
      "7d",
    );
    expect(r.dailyPoints.map((p) => p.day)).toEqual(["2026-06-01", "2026-06-02", "2026-06-03"]);
    expect(r.dailyPoints.map((p) => p.tokens)).toEqual([10, 20, 30]);
  });

  it("cleans dailyProviderTokens: keeps positive splits, drops zeros, junk, and empty days", () => {
    const r = normalizeRollup(
      {
        dailyProviderTokens: {
          "2026-06-02": { anthropic: 120, openai: 80, junk: "x", zero: 0 },
          "2026-06-01": { openai: 50 },
          "2026-06-03": { allZero: 0 },
          "2026-06-04": "not-a-record",
        },
      },
      "all_time",
    );
    expect(r.dailyProviderTokens).toEqual({
      "2026-06-01": { openai: 50 },
      "2026-06-02": { anthropic: 120, openai: 80 },
    });
  });

  it("defaults dailyProviderTokens to an empty map when absent (legacy docs)", () => {
    expect(normalizeRollup({}, "all_time").dailyProviderTokens).toEqual({});
    expect(emptyRollup("all_time").dailyProviderTokens).toEqual({});
  });

  it("normalizes a Firestore-Timestamp computedAt to ISO", () => {
    const r1 = normalizeRollup({ computedAt: "2026-06-01T00:00:00.000Z" }, "30d");
    expect(r1.computedAt).toBe("2026-06-01T00:00:00.000Z");
    const r2 = normalizeRollup({ computedAt: { seconds: 1750000000, nanoseconds: 0 } }, "30d");
    expect(typeof r2.computedAt).toBe("string");
    const r3 = normalizeRollup({}, "30d");
    expect(r3.computedAt).toBeNull();
  });
});

describe("normalizeQuotaSnapshot", () => {
  it("returns null for junk", () => {
    expect(normalizeQuotaSnapshot(null)).toBeNull();
  });

  it("computes remaining from limit-used when remaining is absent", () => {
    const q = normalizeQuotaSnapshot({
      provider: "anthropic",
      confidence: "high",
      buckets: [{ name: "tokens", used: 30, limit: 100 }],
    });
    expect(q).not.toBeNull();
    expect(q!.buckets[0]!.remaining).toBe(70);
    expect(q!.confidence).toBe("high");
  });

  it("marks unbounded buckets with remaining -1 and defaults bad confidence to stale", () => {
    const q = normalizeQuotaSnapshot({
      provider: "ollama",
      confidence: "bogus",
      buckets: [{ name: "requests", used: 5, limit: -1 }],
    });
    expect(q!.buckets[0]!.remaining).toBe(-1);
    expect(q!.confidence).toBe("stale");
  });
});

describe("normalizeAllowance", () => {
  it("derives available/remaining and applies plan defaults", () => {
    const a = normalizeAllowance(
      {
        includedFusionSearches: 100,
        topupFusionSearchesPurchased: 50,
        fusionSearchesUsed: 120,
        monthlyFusionSearchCap: 1000,
      },
      "2026-06",
    );
    expect(a.available).toBe(150);
    expect(a.remaining).toBe(30);
    expect(a.monthlyCap).toBe(1000);
  });

  it("falls back to plan defaults when the doc is empty", () => {
    const a = normalizeAllowance({}, "2026-06");
    expect(a.included).toBe(100);
    expect(a.used).toBe(0);
    expect(a.remaining).toBe(100);
    expect(a.monthlyCap).toBe(1000);
  });

  it("clamps available to the monthly cap when top-ups exceed it (mirrors server)", () => {
    const a = normalizeAllowance(
      {
        includedFusionSearches: 300,
        topupFusionSearchesPurchased: 5000, // pushes included+purchased past the cap
        fusionSearchesUsed: 100,
        monthlyFusionSearchCap: 2000,
      },
      "2026-06",
    );
    expect(a.available).toBe(2000); // min(2000, 5300), NOT 5300
    expect(a.remaining).toBe(1900);
  });
});

describe("currentMonthKey", () => {
  it("formats YYYY-MM in UTC", () => {
    expect(currentMonthKey(new Date(Date.UTC(2026, 5, 26)))).toBe("2026-06");
    expect(currentMonthKey(new Date(Date.UTC(2026, 0, 1)))).toBe("2026-01");
  });
});
