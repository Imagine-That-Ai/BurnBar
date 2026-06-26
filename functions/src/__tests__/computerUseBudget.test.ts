import { describe, expect, it } from "vitest";

import { __testing__ } from "../computerUseBudget.js";

describe("computer use budget spend accounting", () => {
  it("uses actual operator spend when a rollup also carries capped envelope spend", () => {
    expect(
      __testing__.budgetedRollupVisionSpendUSD({
        visionModelSpendUSD: 47.25,
        cappedVisionModelSpendUSD: 5,
      }),
    ).toBe(47.25);
  });

  it("falls back to the capped field only for legacy malformed rollups", () => {
    expect(
      __testing__.budgetedRollupVisionSpendUSD({
        cappedVisionModelSpendUSD: 4.5,
      }),
    ).toBe(4.5);
    expect(
      __testing__.budgetedRollupVisionSpendUSD({
        visionModelSpendUSD: Number.POSITIVE_INFINITY,
        cappedVisionModelSpendUSD: 4.5,
      }),
    ).toBe(4.5);
  });

  it("ignores negative and missing rollup spend", () => {
    expect(__testing__.budgetedRollupVisionSpendUSD({ visionModelSpendUSD: -1 })).toBe(0);
    expect(__testing__.budgetedRollupVisionSpendUSD({})).toBe(0);
  });
});
