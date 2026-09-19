import { describe, expect, it } from "vitest";

import { emptyRollup, type UsageRollup } from "@/lib/usage";
import {
  profileRollupNeedsFullRebuild,
  rebuildUsageErrorMessage,
  rebuildUsageKeepsWaiting,
} from "@/lib/profile/rollupHealth";

function live(overrides: Partial<UsageRollup> = {}): UsageRollup {
  return { ...emptyRollup("all_time"), ...overrides };
}

describe("profileRollupNeedsFullRebuild", () => {
  it("treats a missing doc as needing a full rebuild", () => {
    expect(profileRollupNeedsFullRebuild(null)).toBe(true);
  });

  it("does not force-rebuild a true empty account (zeros, no days)", () => {
    expect(profileRollupNeedsFullRebuild(emptyRollup("all_time"))).toBe(false);
  });

  it("flags pre-v3 rollups that have activity but no harness/provider split", () => {
    expect(
      profileRollupNeedsFullRebuild(
        live({
          totals: { requests: 12, tokens: 4000, costUsd: 1.2 },
          dailyPoints: [{ day: "2026-09-18", tokens: 4000 }],
        }),
      ),
    ).toBe(true);
  });

  it("accepts a v3 rollup with a provider-day split", () => {
    expect(
      profileRollupNeedsFullRebuild(
        live({
          totals: { requests: 12, tokens: 4000, costUsd: 1.2 },
          dailyPoints: [{ day: "2026-09-18", tokens: 4000 }],
          dailyProviderTokens: { "2026-09-18": { anthropic: 4000 } },
        }),
      ),
    ).toBe(false);
  });

  it("accepts a v3 rollup that only has execution-source summaries", () => {
    expect(
      profileRollupNeedsFullRebuild(
        live({
          totals: { requests: 3, tokens: 900, costUsd: 0.4 },
          dailyPoints: [{ day: "2026-09-19", tokens: 900 }],
          executionSourceSummaries: [
            {
              sourceId: "cursor",
              sourceName: "Cursor",
              totalRequests: 3,
              totalTokens: 900,
              totalCost: 0.4,
            },
          ],
        }),
      ),
    ).toBe(false);
  });
});

describe("rebuildUsageErrorMessage", () => {
  it("maps circuit_open onto a paused-until sentence", () => {
    expect(
      rebuildUsageErrorMessage({
        code: "functions/unavailable",
        details: { reason: "circuit_open", retryAt: "2026-09-19T11:00:00.000Z" },
      }),
    ).toBe("Usage repair is paused until 2026-09-19T11:00:00.000Z after repeated failures.");
  });

  it("maps in_flight onto a still-running sentence", () => {
    expect(
      rebuildUsageErrorMessage({ code: "functions/aborted", details: { reason: "in_flight" } }),
    ).toBe("A usage rebuild is already running. This page fills in when it finishes.");
  });

  it("keeps waiting only for an in_flight refusal", () => {
    expect(
      rebuildUsageKeepsWaiting({ code: "functions/aborted", details: { reason: "in_flight" } }),
    ).toBe(true);
    expect(
      rebuildUsageKeepsWaiting({ code: "functions/unavailable", details: { reason: "circuit_open" } }),
    ).toBe(false);
    expect(rebuildUsageKeepsWaiting({ code: "functions/aborted" })).toBe(false);
  });

  it("maps force_cooldown onto a retry-after sentence", () => {
    expect(
      rebuildUsageErrorMessage({
        code: "functions/resource-exhausted",
        details: { reason: "force_cooldown", retryAt: "2026-09-19T10:20:00.000Z" },
      }),
    ).toBe("A full rebuild just ran. Try again after 2026-09-19T10:20:00.000Z.");
  });

  it("maps the 2026-09-19 OOM / timeout wording", () => {
    expect(
      rebuildUsageErrorMessage({
        code: "functions/internal",
        message: "Memory limit of 256 MiB exceeded with 258 MiB used.",
      }),
    ).toMatch(/time or memory/);
    expect(rebuildUsageErrorMessage({ code: "functions/deadline-exceeded" })).toMatch(/time or memory/);
  });

  it("falls back to the Error message", () => {
    expect(rebuildUsageErrorMessage(new Error("firestore denied"))).toBe("firestore denied");
  });

  it("does not treat a bare functions/unavailable as a circuit break", () => {
    expect(rebuildUsageErrorMessage({ code: "functions/unavailable", message: "UNAVAILABLE" })).toBe("UNAVAILABLE");
  });
});
