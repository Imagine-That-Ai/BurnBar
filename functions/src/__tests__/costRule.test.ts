/**
 * One cost rule (Wave 2.5, decision 3): `costUSD` is canonical, `costUsd` and
 * `cost` are read-only legacy fallbacks. The cross-client fixture in
 * `tests/fixtures/cost-rule/v1.json` must produce the identical total on all
 * three clients (this test, the Android JVM test, and the Swift test) —
 * normative spec in `tests/fixtures/cost-rule/README.md`.
 */
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { effectiveCostUSD, totalCostUSD } from "../costRule.js";

describe("effectiveCostUSD", () => {
  it("prefers costUSD over legacy spellings", () => {
    expect(effectiveCostUSD({ costUSD: 1.25, costUsd: 999, cost: 888 })).toBe(1.25);
  });

  it("zero costUSD wins over positive legacy values", () => {
    expect(effectiveCostUSD({ costUSD: 0, costUsd: 4, cost: 4 })).toBe(0);
  });

  it("falls through negative canon to legacy", () => {
    expect(effectiveCostUSD({ costUSD: -1, costUsd: 0.25, cost: 5 })).toBe(0.25);
  });

  it("returns 0 when every spelling is negative", () => {
    expect(effectiveCostUSD({ costUSD: -1, costUsd: -2, cost: -3 })).toBe(0);
  });

  it("never coerces strings", () => {
    expect(effectiveCostUSD({ costUSD: "1.5", costUsd: "2.5", cost: "3.5" })).toBe(0);
    expect(effectiveCostUSD({ costUSD: "9.99", costUsd: 1.5 })).toBe(1.5);
  });

  it("treats null, undefined, and absent as no value", () => {
    expect(effectiveCostUSD({})).toBe(0);
    expect(effectiveCostUSD({ costUSD: null, costUsd: null, cost: null })).toBe(0);
    expect(effectiveCostUSD({ costUSD: undefined, costUsd: 0.5 })).toBe(0.5);
  });

  it("skips NaN and infinities", () => {
    expect(effectiveCostUSD({ costUSD: Number.NaN, costUsd: 1 })).toBe(1);
    expect(effectiveCostUSD({ costUSD: Number.POSITIVE_INFINITY, cost: 2 })).toBe(2);
  });
});

describe("cost-rule fixture (cross-client)", () => {
  it("produces the pinned per-event values and total", () => {
    const fixturePath = join(process.cwd(), "..", "tests", "fixtures", "cost-rule", "v1.json");
    const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as {
      version: number;
      expectedTotal: number;
      events: Array<{
        id: string;
        costUSD?: unknown;
        costUsd?: unknown;
        cost?: unknown;
        expectedEffective: number;
      }>;
    };
    expect(fixture.version).toBe(1);
    for (const event of fixture.events) {
      expect(effectiveCostUSD(event)).toBe(event.expectedEffective);
    }
    expect(totalCostUSD(fixture.events)).toBe(fixture.expectedTotal);
  });
});
