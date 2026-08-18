/**
 * normalizeRollup fail-soft contract for the execution-source (agent harness)
 * and combo summaries: legacy rollup docs lack both fields and must normalize
 * to empty arrays; live docs normalize, default missing names, and sort by
 * tokens. brandLogos pins the id → asset mapping and its fallbacks.
 */
import { describe, expect, it } from "vitest";

import { emptyRollup, normalizeRollup } from "../lib/usage";
import { brandKey, brandLogo } from "../lib/brandLogos";

describe("normalizeRollup execution-source fields", () => {
  it("defaults both summaries to empty arrays on legacy docs", () => {
    const rollup = normalizeRollup({ totals: { requests: 1, tokens: 10, costUsd: 0 } }, "all_time");
    expect(rollup.executionSourceSummaries).toEqual([]);
    expect(rollup.comboSummaries).toEqual([]);
  });

  it("emptyRollup carries empty summaries", () => {
    const rollup = emptyRollup("all_time");
    expect(rollup.executionSourceSummaries).toEqual([]);
    expect(rollup.comboSummaries).toEqual([]);
  });

  it("normalizes harness summaries, defaulting a missing name to the id", () => {
    const rollup = normalizeRollup(
      {
        executionSourceSummaries: [
          { sourceId: "codex", totalRequests: 4, totalTokens: 200, totalCost: 0.5 },
          { sourceId: "claude-code", sourceName: "Claude Code", totalRequests: 9, totalTokens: 900, totalCost: 1.2 },
          "garbage",
        ],
      },
      "all_time",
    );
    expect(rollup.executionSourceSummaries).toEqual([
      { sourceId: "claude-code", sourceName: "Claude Code", totalRequests: 9, totalTokens: 900, totalCost: 1.2 },
      { sourceId: "codex", sourceName: "codex", totalRequests: 4, totalTokens: 200, totalCost: 0.5 },
    ]);
  });

  it("normalizes combo summaries and sorts by tokens", () => {
    const rollup = normalizeRollup(
      {
        comboSummaries: [
          { sourceId: "codex", provider: "openai", model: "gpt-5.2", requests: 2, tokens: 50, cost: 0.1 },
          { sourceId: "cursor", sourceName: "Cursor", provider: "anthropic", model: "claude-opus-4.8", requests: 7, tokens: 800, cost: 2 },
        ],
      },
      "all_time",
    );
    expect(rollup.comboSummaries.map((c) => `${c.sourceName} × ${c.model}`)).toEqual([
      "Cursor × claude-opus-4.8",
      "codex × gpt-5.2",
    ]);
  });

  it("coerces malformed numbers to zero instead of throwing", () => {
    const rollup = normalizeRollup(
      { executionSourceSummaries: [{ sourceId: "kimi", totalTokens: "lots" }] },
      "all_time",
    );
    expect(rollup.executionSourceSummaries[0].totalTokens).toBe(0);
  });
});

describe("brandLogo", () => {
  it("maps known harness and provider ids", () => {
    expect(brandLogo("claude-code")).toBe("/brand/logos/claude-code.png");
    expect(brandLogo("openai")).toBe("/brand/logos/openai.png");
  });

  it("normalizes display names to ids", () => {
    expect(brandKey("Claude Code")).toBe("claude-code");
    expect(brandLogo("Claude Code")).toBe("/brand/logos/claude-code.png");
  });

  it("loosely matches prefixed/suffixed variants", () => {
    expect(brandLogo("factory-droid")).toBe("/brand/logos/factory.png");
  });

  it("returns null for unknown or empty ids", () => {
    expect(brandLogo("notepad++")).toBeNull();
    expect(brandLogo(undefined)).toBeNull();
    expect(brandLogo("")).toBeNull();
  });
});
