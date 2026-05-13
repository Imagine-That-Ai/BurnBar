import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const {
  buildRouterRundown,
  FAVORITE_POLICY_VERSION,
} = await import("../lib/routerRundown.js");

const now = "2026-05-13T12:00:00.000Z";

const models = [
  {
    modelID: "gpt-5-5",
    modelDisplay: "GPT-5.5",
    selectionDisplayName: "GPT-5.5 xhigh",
    preferredReasoningEffort: "xhigh",
    operatorPreferenceRank: 1,
    providerID: "openai",
    providerDisplay: "OpenAI",
    providerFamily: "openai_compat",
    providerLogo: "/brand/providers/openai.png",
    tier: "flagship",
    contextWindowTokens: 400000,
    costSignal: 0.22,
  },
  {
    modelID: "claude-opus-4-7",
    modelDisplay: "Claude Opus 4.7",
    operatorPreferenceRank: 2,
    providerID: "anthropic",
    providerDisplay: "Anthropic",
    providerFamily: "anthropic",
    providerLogo: "/brand/providers/anthropic.png",
    tier: "flagship",
    contextWindowTokens: 1000000,
    costSignal: 0.18,
  },
  {
    modelID: "glm-5-1",
    modelDisplay: "GLM 5.1",
    operatorPreferenceRank: 3,
    providerID: "zai",
    providerDisplay: "Z.ai",
    providerFamily: "openai_compat",
    providerLogo: "/brand/providers/zai.png",
    tier: "flagship",
    contextWindowTokens: 256000,
    costSignal: 0.66,
  },
  {
    modelID: "gemini-3-1-pro-preview",
    modelDisplay: "Gemini 3.1 Pro",
    providerID: "google",
    providerDisplay: "Google",
    providerFamily: "openai_compat",
    providerLogo: "/brand/providers/google.svg",
    tier: "flagship",
    contextWindowTokens: 2000000,
    costSignal: 0.3,
  },
];

const runtime = Object.fromEntries(models.map((m) => [
  m.modelID,
  { availability: "common", routable: true, reliability: 0.88, latencySignal: 0.62 },
]));

const statuses = [
  { source: "artificial_analysis", status: "fresh", message: "ok", fetchedAt: "2026-05-13T08:00:00.000Z" },
];

{
  const rundown = buildRouterRundown({
    date: "2026-05-13",
    generatedAt: now,
    models,
    snapshots: [
      { source: "artificial_analysis", modelID: "openai/gpt-5.5-xhigh", taskCategory: "coding", score: 0.86, freshness: "fresh", confidence: 0.9, fetchedAt: "2026-05-13T08:00:00.000Z" },
      { source: "artificial_analysis", modelID: "anthropic/claude-opus-4-7", taskCategory: "coding", score: 0.90, freshness: "fresh", confidence: 0.9, fetchedAt: "2026-05-13T08:00:00.000Z" },
      { source: "artificial_analysis", modelID: "zai-org/GLM-5.1", taskCategory: "coding", score: 0.84, freshness: "fresh", confidence: 0.9, fetchedAt: "2026-05-13T08:00:00.000Z" },
      { source: "artificial_analysis", modelID: "gemini-3-1-pro-preview", taskCategory: "coding", score: 0.95, freshness: "fresh", confidence: 0.9, fetchedAt: "2026-05-13T08:00:00.000Z" },
    ],
    statuses,
    runtime,
  });

  const coding = rundown.taskRankings.find((task) => task.taskID === "coding");
  assert.deepEqual(coding.recommendations.map((rec) => rec.modelID), ["gpt-5-5", "claude-opus-4-7", "glm-5-1"]);
  assert.equal(coding.recommendations[0].modelDisplay, "GPT-5.5 xhigh");
  assert.equal(coding.recommendations[0].preferredReasoningEffort, "xhigh");
  assert.equal(coding.recommendations[0].favoritePolicyVersion, FAVORITE_POLICY_VERSION);
  assert.ok(coding.recommendations[0].selectionScore > coding.recommendations[0].score);
  assert.ok(coding.recommendations[0].selectionScore > coding.recommendations[1].selectionScore);
  assert.ok(coding.topPickRationale.includes("stable favorite rank #1"));
}

{
  const previousRundown = {
    taskRankings: [{
      taskID: "coding",
      recommendations: [
        { modelID: "gpt-5-5", score: 0.64, signals: { benchmarkScore: 0.70 } },
        { modelID: "gemini-3-1-pro-preview", score: 0.82, signals: { benchmarkScore: 0.98 } },
      ],
      rejectedAlternatives: [],
    }],
  };
  const rundown = buildRouterRundown({
    date: "2026-05-13",
    generatedAt: now,
    models,
    snapshots: [
      { source: "artificial_analysis", modelID: "gpt-5-5", taskCategory: "coding", score: 0.70, freshness: "fresh", confidence: 0.9, fetchedAt: "2026-05-13T08:00:00.000Z" },
      { source: "artificial_analysis", modelID: "gemini-3-1-pro-preview", taskCategory: "coding", score: 0.99, freshness: "fresh", confidence: 0.9, fetchedAt: "2026-05-13T08:00:00.000Z" },
    ],
    statuses,
    runtime,
    previousRundown,
  });

  const coding = rundown.taskRankings.find((task) => task.taskID === "coding");
  assert.equal(coding.recommendations[0].modelID, "gemini-3-1-pro-preview");
}

{
  const source = await readFile(new URL("../src/scheduled.ts", import.meta.url), "utf8");
  assert.match(source, /buildAndPersistRouterRundown/);
  assert.match(source, /await buildAndPersistRouterRundown\(db, now\)/);
}

console.log("router rundown policy ok");
