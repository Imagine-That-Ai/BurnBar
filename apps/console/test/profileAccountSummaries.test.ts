/**
 * Rollup contract addition for the mineable /profile explorer:
 * `normalizeRollup` keeps `accountSummaries` (raw `providerAccountID` id,
 * `${providerID}:unattributed` fallback, token-desc sort) instead of
 * dropping them like the old normalizer did.
 */
import { describe, expect, it } from "vitest";

import { emptyRollup, normalizeRollup } from "../lib/usage";

describe("normalizeRollup accountSummaries", () => {
  it("defaults to an empty array on legacy docs", () => {
    expect(normalizeRollup({ totals: {} }, "all_time").accountSummaries).toEqual([]);
    expect(emptyRollup("all_time").accountSummaries).toEqual([]);
  });

  it("keeps account ids, labels, and all three metrics", () => {
    const rollup = normalizeRollup(
      {
        accountSummaries: [
          {
            id: "acct-9",
            providerID: "codex",
            accountID: "acct-9",
            accountLabel: "personal",
            totalRequests: 3,
            totalTokens: 900,
            totalCost: 1.2,
          },
        ],
      },
      "all_time",
    );
    expect(rollup.accountSummaries).toEqual([
      {
        id: "acct-9",
        providerID: "codex",
        accountID: "acct-9",
        accountLabel: "personal",
        totalRequests: 3,
        totalTokens: 900,
        totalCost: 1.2,
      },
    ]);
  });

  it("falls back to the raw account id, then providerID:unattributed", () => {
    const rollup = normalizeRollup(
      {
        accountSummaries: [
          { accountID: "raw-acct", providerID: "codex", totalTokens: 5 },
          { providerID: "codex", totalTokens: 7 },
          { totalTokens: 1 },
          "garbage",
        ],
      },
      "all_time",
    );
    expect(rollup.accountSummaries.map((a) => a.id)).toEqual([
      "codex:unattributed",
      "raw-acct",
      "unknown:unattributed",
    ]);
  });

  it("coerces malformed numbers to zero instead of throwing", () => {
    const rollup = normalizeRollup(
      { accountSummaries: [{ id: "a", totalTokens: "lots" }] },
      "all_time",
    );
    expect(rollup.accountSummaries[0]).toMatchObject({ id: "a", totalTokens: 0 });
  });
});
