import { describe, expect, it } from "vitest";

import { __testing__ } from "../computerUseBudget.js";

describe("computer use budget spend accounting", () => {
  it("uses capped envelope spend for global kill-switch projection", () => {
    expect(
      __testing__.budgetedRollupVisionSpendUSD({
        visionModelSpendUSD: 47.25,
        cappedVisionModelSpendUSD: 5,
      }),
    ).toBe(5);
  });

  it("falls back to actual spend only for legacy rollups missing the capped field", () => {
    expect(
      __testing__.budgetedRollupVisionSpendUSD({
        visionModelSpendUSD: 4.5,
      }),
    ).toBe(4.5);
  });

  it("ignores malformed capped spend instead of trusting inflated actual spend", () => {
    expect(
      __testing__.budgetedRollupVisionSpendUSD({
        visionModelSpendUSD: 47.25,
        cappedVisionModelSpendUSD: Number.POSITIVE_INFINITY,
      }),
    ).toBe(0);
    expect(
      __testing__.budgetedRollupVisionSpendUSD({
        visionModelSpendUSD: Number.POSITIVE_INFINITY,
        cappedVisionModelSpendUSD: 4.5,
      }),
    ).toBe(4.5);
  });

  it("ignores negative and missing rollup spend", () => {
    expect(__testing__.budgetedRollupVisionSpendUSD({ cappedVisionModelSpendUSD: -1 })).toBe(0);
    expect(__testing__.budgetedRollupVisionSpendUSD({})).toBe(0);
  });
});
