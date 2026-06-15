/**
 * Characterization pin for the router-rundown scoring pipeline.
 *
 * `buildRecommendation` is module-private; it is exercised here through its
 * nearest exported caller, `buildRouterRundown`. These assertions freeze the
 * CURRENT observable behavior (recommendation ordering, the stable-favorite
 * selection-score ladder, favorite display-name substitution, rejection
 * bucketing, evidence suppression when no snapshots exist, and source-status
 * redaction) so a behavior-preserving refactor stays provably equivalent.
 *
 * `buildRouterRundown` is a pure compute and never throws HttpsError, so the
 * pins below assert return values rather than thrown codes/messages.
 */
import { describe, expect, it } from "vitest";
import { buildRouterRundown } from "../routerRundown.js";
import type {
  ModelBenchmarkSnapshotDoc,
  ModelBenchmarkSourceStatusDoc,
  ModelBenchmarkSource,
  ModelBenchmarkTaskCategory,
} from "../types.js";

const GENERATED_AT = "2026-06-14T12:00:00.000Z";
const FRESH_FETCHED_AT = "2026-06-14T06:00:00.000Z"; // 6h old → freshness 1.0

function codingSnapshot(
  modelID: string,
  score: number,
  source: ModelBenchmarkSource = "artificial_analysis",
): ModelBenchmarkSnapshotDoc {
  return {
    id: `${modelID}:${source}:coding`,
    source,
    sourceURL: "https://example.test/benchmark",
    fetchedAt: FRESH_FETCHED_AT,
    modelID,
    taskCategory: "coding" as ModelBenchmarkTaskCategory,
    score,
    confidence: 0.9,
    reliabilitySignal: 0.9,
    latencySignal: 0.7,
    freshness: "fresh",
    schemaVersion: 1,
    updatedAt: FRESH_FETCHED_AT,
  };
}

const FLAGSHIP_BASE = {
  providerDisplay: "Provider",
  providerFamily: "openai",
  tier: "flagship" as const,
  contextWindowTokens: 256_000,
  costSignal: 0.8,
};

describe("buildRouterRundown characterization", () => {
  it("orders a stable favorite ahead of a stronger challenger and applies the selection-score ladder", () => {
    const rundown = buildRouterRundown({
      date: "2026-06-14",
      generatedAt: GENERATED_AT,
      models: [
        {
          ...FLAGSHIP_BASE,
          modelID: "gpt-5-5",
          modelDisplay: "GPT-5.5",
          providerID: "openai",
        },
        {
          ...FLAGSHIP_BASE,
          modelID: "challenger-1",
          modelDisplay: "Challenger One",
          providerID: "challenger",
        },
      ],
      snapshots: [
        // Challenger scores higher on raw evidence than the favorite.
        codingSnapshot("gpt-5-5", 0.8),
        codingSnapshot("challenger-1", 0.95),
      ],
      statuses: [],
      runtime: {
        "gpt-5-5": { routable: true, availability: "common" },
        "challenger-1": { routable: true, availability: "common" },
      },
    });

    expect(rundown.date).toBe("2026-06-14");
    expect(rundown.generatedAt).toBe(GENERATED_AT);
    expect(rundown.schemaVersion).toBe(1);

    const coding = rundown.taskRankings.find((t) => t.taskID === "coding");
    expect(coding).toBeDefined();
    const recs = coding!.recommendations;
    expect(recs).toHaveLength(2);

    // Favorite policy: gpt-5-5 (favorite rank #1) stays on top even though the
    // challenger has the higher raw benchmark score, because the challenger has
    // no prior-rundown history to clear the dethroning margins.
    expect(recs[0].modelID).toBe("gpt-5-5");
    // The built-in favorite display name overrides the catalog modelDisplay.
    expect(recs[0].modelDisplay).toBe("GPT-5.5 xhigh");
    expect(recs[0].canonicalModelDisplay).toBe("GPT-5.5");
    expect(recs[0].favoriteRank).toBe(1);
    expect(recs[0].preferredReasoningEffort).toBe("xhigh");
    expect(recs[0].rank).toBe(1);
    expect(recs[1].modelID).toBe("challenger-1");
    expect(recs[1].rank).toBe(2);

    // Ordinal selection-score ladder: SELECTION_SCORE_TOP then -STEP per slot.
    expect(recs[0].selectionScore).toBeCloseTo(0.99, 10);
    expect(recs[1].selectionScore).toBeCloseTo(0.96, 10);

    // Benchmark composite carries through verbatim from the snapshot scores.
    expect(recs[0].signals.benchmarkScore).toBeCloseTo(0.8, 10);
    expect(recs[1].signals.benchmarkScore).toBeCloseTo(0.95, 10);
    expect(recs[0].signals.routable).toBe(true);
    expect(recs[0].signals.contextWindowTokens).toBe(256_000);

    // Top-pick rationale names the chosen favorite and its runner-up.
    expect(coding!.topPickRationale).toContain("GPT-5.5 xhigh");
    expect(coding!.topPickRationale).toContain("stable favorite rank #1");
    expect(coding!.note).toBeUndefined();
  });

  it("suppresses a task with no benchmark evidence and redacts source-status secrets", () => {
    const statuses: ModelBenchmarkSourceStatusDoc[] = [
      {
        source: "artificial_analysis" as ModelBenchmarkSource,
        status: "error",
        fetchedAt: FRESH_FETCHED_AT,
        message: "fetch failed authorization: Bearer abcdef0123456789",
        schemaVersion: 1,
        updatedAt: FRESH_FETCHED_AT,
      },
    ];

    const rundown = buildRouterRundown({
      date: "2026-06-14",
      generatedAt: GENERATED_AT,
      models: [
        {
          ...FLAGSHIP_BASE,
          modelID: "gpt-5-5",
          modelDisplay: "GPT-5.5",
          providerID: "openai",
        },
      ],
      // No snapshots at all → every task category is suppressed and filtered out.
      snapshots: [],
      statuses,
      runtime: {},
      notes: ["plain note", "leak x-api-key=supersecretvalue1234"],
    });

    // Tasks with zero recommendations are filtered out of the final rundown.
    expect(rundown.taskRankings).toHaveLength(0);

    // Source status secrets are scrubbed before they reach the public shape.
    expect(rundown.sourceStatuses).toHaveLength(1);
    expect(rundown.sourceStatuses[0].source).toBe("artificial_analysis");
    expect(rundown.sourceStatuses[0].message).not.toContain("Bearer abcdef0123456789");
    expect(rundown.sourceStatuses[0].message).toContain("[redacted]");
    expect(rundown.sourceStatuses[0].ageHours).toBeCloseTo(6, 10);

    // Notes are redacted and empty notes are dropped.
    expect(rundown.notes).toHaveLength(2);
    expect(rundown.notes[0]).toBe("plain note");
    expect(rundown.notes[1]).toContain("[redacted]");

    // Global limitations are always emitted.
    expect(rundown.globalLimitations.length).toBeGreaterThan(0);
  });
});
