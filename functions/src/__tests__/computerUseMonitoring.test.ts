import { describe, expect, it } from "vitest";

import { __testing__ } from "../computerUseMonitoring.js";

describe("computer use monitoring rollup guards", () => {
  it("derives the rollup owner only from canonical user collection paths", () => {
    expect(
      __testing__.uidFromComputerUseCollectionPath(
        "users/alice-uid/computer_use_actions/action-1",
        "computer_use_actions",
      ),
    ).toBe("alice-uid");
    expect(
      __testing__.uidFromComputerUseCollectionPath(
        "users/alice-uid/computer_use_sessions/session-1",
        "computer_use_sessions",
      ),
    ).toBe("alice-uid");
  });

  it("rejects malformed, nested, or wrong-collection paths", () => {
    expect(
      __testing__.uidFromComputerUseCollectionPath(
        "tenants/t1/users/alice-uid/computer_use_actions/action-1",
        "computer_use_actions",
      ),
    ).toBeNull();
    expect(
      __testing__.uidFromComputerUseCollectionPath(
        "users/alice-uid/computer_use_sessions/session-1",
        "computer_use_actions",
      ),
    ).toBeNull();
    expect(
      __testing__.uidFromComputerUseCollectionPath("users//computer_use_actions/action-1", "computer_use_actions"),
    ).toBeNull();
  });

  it("caps per-user daily vision spend before writing global operator rollups", () => {
    const cap = __testing__.limits.maxRollupVisionSpendUSDPerUserPerDay;

    expect(__testing__.boundedVisionSpendContribution(0, cap + 100)).toBe(cap);
    expect(__testing__.boundedVisionSpendContribution(cap - 0.25, 10)).toBe(0.25);
    expect(__testing__.boundedVisionSpendContribution(cap, 10)).toBe(0);
    expect(__testing__.boundedVisionSpendContribution(0, Number.POSITIVE_INFINITY)).toBe(0);
    expect(__testing__.boundedVisionSpendContribution(0, -1)).toBe(0);
  });

  it("keeps actual operator spend separate from the capped per-user envelope", () => {
    const perUserCap = __testing__.limits.maxRollupVisionSpendUSDPerUserPerDay;
    const perActionCap = __testing__.limits.maxRollupVisionSpendUSDPerAction;

    expect(__testing__.sanitizedVisionSpendContribution(perUserCap + 7)).toBe(perUserCap + 7);
    expect(__testing__.boundedVisionSpendContribution(0, perUserCap + 7)).toBe(perUserCap);
    expect(__testing__.sanitizedVisionSpendContribution(perActionCap + 100)).toBe(perActionCap);
  });
});
