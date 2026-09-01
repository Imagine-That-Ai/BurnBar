import { describe, expect, it } from "vitest";

import { needsProfileRebuild } from "@/lib/profile/rollupHealth";
import { emptyRollup, type UsageRollup } from "@/lib/usage";

function rollup(partial: Partial<UsageRollup>): UsageRollup {
  return { ...emptyRollup("all_time"), ...partial };
}

describe("needsProfileRebuild", () => {
  it("rebuilds a missing document", () => {
    expect(needsProfileRebuild(null)).toBe(true);
  });

  it("rebuilds a present but zeroed all_time document", () => {
    // The cheap scheduled path can write this before any device has published
    // usage. Treating it as healthy hides Re-sync and never counts later events.
    expect(needsProfileRebuild(emptyRollup("all_time"))).toBe(true);
    expect(
      needsProfileRebuild(
        rollup({ totals: { requests: 0, tokens: 0, costUsd: 0 }, computedAt: "2026-08-31T00:00:00.000Z" }),
      ),
    ).toBe(true);
  });

  it("rebuilds a pre-v3 document that has totals but no harness/combo/day-provider split", () => {
    expect(
      needsProfileRebuild(
        rollup({
          totals: { requests: 12, tokens: 40_000, costUsd: 1.2 },
          dailyPoints: [{ day: "2026-08-01", tokens: 40_000 }],
        }),
      ),
    ).toBe(true);
  });

  it("leaves a healthy v3 document alone", () => {
    expect(
      needsProfileRebuild(
        rollup({
          totals: { requests: 12, tokens: 40_000, costUsd: 1.2 },
          dailyPoints: [{ day: "2026-08-01", tokens: 40_000 }],
          executionSourceSummaries: [
            {
              sourceId: "claude-code",
              sourceName: "Claude Code",
              totalRequests: 12,
              totalTokens: 40_000,
              totalCost: 1.2,
            },
          ],
          dailyProviderTokens: { "2026-08-01": { anthropic: 40_000 } },
        }),
      ),
    ).toBe(false);
  });
});
