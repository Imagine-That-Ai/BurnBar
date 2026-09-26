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
import { requireRecordArray } from "@openburnbar/functions-shared/shared/validators.js";

interface CostRuleFixtureEvent {
  id: string;
  costUSD?: unknown;
  costUsd?: unknown;
  cost?: unknown;
  expectedEffective: number;
}

interface CostRuleFixture {
  version: number;
  expectedTotal: number;
  events: CostRuleFixtureEvent[];
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// The pinned cross-client fixture is trusted shape-wise, but JSON.parse
// returns `any`: decode it through validators instead of asserting.
function parseCostRuleFixture(raw: unknown): CostRuleFixture {
  if (!isRecord(raw)) {
    throw new Error("cost-rule fixture must be an object");
  }
  const { version, expectedTotal, events } = raw;
  if (typeof version !== "number" || typeof expectedTotal !== "number") {
    throw new Error("cost-rule fixture needs numeric version/expectedTotal");
  }
  return {
    version,
    expectedTotal,
    events: requireRecordArray(events, "events", 1000).map((event, index) => {
      if (typeof event.id !== "string" || typeof event.expectedEffective !== "number") {
        throw new Error(`cost-rule fixture event ${index} needs a string id and numeric expectedEffective`);
      }
      return {
        id: event.id,
        costUSD: event.costUSD,
        costUsd: event.costUsd,
        cost: event.cost,
        expectedEffective: event.expectedEffective,
      };
    }),
  };
}

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
    const fixture = parseCostRuleFixture(JSON.parse(readFileSync(fixturePath, "utf8")));
    expect(fixture.version).toBe(1);
    for (const event of fixture.events) {
      expect(effectiveCostUSD(event)).toBe(event.expectedEffective);
    }
    expect(totalCostUSD(fixture.events)).toBe(fixture.expectedTotal);
  });
});
