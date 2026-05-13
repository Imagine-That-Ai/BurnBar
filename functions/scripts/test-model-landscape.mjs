import assert from "node:assert/strict";

const {
  normalizeArtificialAnalysisModels,
  normalizeDesignArenaFixture,
  normalizeHuggingFaceLeaderboard,
} = await import("../lib/modelLandscape.js");

const fetchedAt = "2026-05-12T12:00:00.000Z";

const aa = normalizeArtificialAnalysisModels({
  data: [{
    id: "aa-1",
    name: "GPT-5.4",
    slug: "gpt-5.4",
    model_creator: { slug: "openai", name: "OpenAI" },
    evaluations: {
      artificial_analysis_intelligence_index: 82,
      artificial_analysis_coding_index: 77,
    },
    pricing: {
      price_1m_input_tokens: 2,
      price_1m_output_tokens: 10,
      price_1m_blended_3_to_1: 4,
    },
    median_output_tokens_per_second: 120,
    median_time_to_first_token_seconds: 2,
  }],
}, fetchedAt);

assert.equal(aa.length, 2);
assert.equal(aa[0].source, "artificial_analysis");
assert.equal(aa[0].providerID, "openai");
assert.equal(aa[0].freshness, "fresh");
assert.ok(aa.every((row) => row.costSignal > 0 && row.costSignal <= 1));
assert.ok(aa.every((row) => row.latencySignal > 0 && row.latencySignal <= 1));

const terminal = normalizeHuggingFaceLeaderboard([
  { rank: 1, model_id: "zai-org/GLM-5.1", value: 69, verified: true },
], fetchedAt);
assert.equal(terminal.length, 1);
assert.equal(terminal[0].source, "terminal_bench");
assert.equal(terminal[0].taskCategory, "terminal");
assert.equal(terminal[0].rank, 1);
assert.equal(terminal[0].reliabilitySignal, 0.9);

const design = normalizeDesignArenaFixture({
  data: [{
    modelID: "claude-opus-4.7",
    provider: "Anthropic",
    taskCategory: "design",
    score: 91,
    rank: 2,
  }],
}, fetchedAt);
assert.equal(design.length, 1);
assert.equal(design[0].source, "design_arena");
assert.equal(design[0].providerID, "anthropic");
assert.equal(design[0].freshness, "manual");

const encoded = JSON.stringify([...aa, ...terminal, ...design]);
assert.equal(/api[_-]?key|bearer|cookie|secretVersionName/i.test(encoded), false);

console.log("model landscape normalization ok");
