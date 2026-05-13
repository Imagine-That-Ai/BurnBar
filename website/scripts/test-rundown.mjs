#!/usr/bin/env node
/**
 * @fileoverview Focused tests for the rundown generator.
 *
 * Run via:  node scripts/test-rundown.mjs
 *
 * Covers (matches the task spec):
 *   1. Fresh benchmark data produces ordered recommendations.
 *   2. Stale benchmark data lowers confidence safely.
 *   3. Missing source data shows a graceful source-status warning.
 *   4. Missing cost/latency/context does not crash rendering.
 *   5. Explanations do not include secrets or raw auth material.
 *   6. The committed daily history files render shape-correctly for
 *      multiple dates (smoke test against the actual archive).
 */

import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  buildRundown,
  buildTaskRanking,
  redactExplanation,
  WEIGHTS,
} from "./lib/rundown-generator.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const HISTORY_DIR = path.resolve(__dirname, "..", "src", "data", "router-rundown-history");

const baseModels = [
  {
    modelID: "anthropic/claude-opus-4-7",
    modelDisplay: "Claude Opus 4.7",
    providerID: "anthropic",
    providerDisplay: "Anthropic",
    providerFamily: "anthropic",
    providerLogo: "/brand/providers/anthropic.png",
    contextWindowTokens: 1000000,
    costSignal: 0.4,
  },
  {
    modelID: "openai/gpt-5",
    modelDisplay: "GPT-5",
    providerID: "openai",
    providerDisplay: "OpenAI",
    providerFamily: "openai_compat",
    providerLogo: "/brand/providers/openai.png",
    contextWindowTokens: 400000,
    costSignal: 0.5,
  },
  {
    modelID: "zai/glm-5",
    modelDisplay: "GLM 5",
    providerID: "zai",
    providerDisplay: "Z.ai",
    providerFamily: "openai_compat",
    providerLogo: "/brand/providers/zai.png",
    contextWindowTokens: 256000,
    costSignal: 0.7,
  },
];

const runtime = {
  "anthropic/claude-opus-4-7": { availability: "common", routable: true, reliability: 0.86 },
  "openai/gpt-5": { availability: "common", routable: true, reliability: 0.88 },
  "zai/glm-5": { availability: "common", routable: true, reliability: 0.8 },
};

// ───────────────────────── 1. Fresh benchmark data → ordered recs ──────────

{
  const now = "2026-05-13T12:00:00.000Z";
  const snapshots = [
    { source: "artificial_analysis", modelID: "openai/gpt-5", taskCategory: "coding", score: 0.9, rank: 1, confidence: 0.9, freshness: "fresh", reliabilitySignal: 0.92, latencySignal: 0.6, fetchedAt: "2026-05-13T08:00:00.000Z" },
    { source: "artificial_analysis", modelID: "anthropic/claude-opus-4-7", taskCategory: "coding", score: 0.86, rank: 2, confidence: 0.9, freshness: "fresh", reliabilitySignal: 0.88, latencySignal: 0.46, fetchedAt: "2026-05-13T08:00:00.000Z" },
    { source: "artificial_analysis", modelID: "zai/glm-5", taskCategory: "coding", score: 0.78, rank: 3, confidence: 0.9, freshness: "fresh", reliabilitySignal: 0.8, fetchedAt: "2026-05-13T08:00:00.000Z" },
  ];
  const statuses = [
    { source: "artificial_analysis", status: "fresh", message: "ok", fetchedAt: "2026-05-13T08:00:00.000Z" },
  ];

  const ranking = buildTaskRanking({
    taskID: "coding",
    models: baseModels,
    snapshots,
    statuses,
    runtime,
    now,
  });

  assert.equal(ranking.taskID, "coding");
  assert.equal(ranking.recommendations.length, 3, "expects top + 2 alternatives");
  assert.equal(ranking.recommendations[0].modelID, "openai/gpt-5", "highest score wins");
  assert.equal(ranking.recommendations[1].modelID, "anthropic/claude-opus-4-7");
  assert.equal(ranking.recommendations[2].modelID, "zai/glm-5");
  assert.equal(ranking.recommendations[0].rank, 1);
  assert.equal(ranking.recommendations[1].rank, 2);
  assert.ok(ranking.recommendations[0].score > ranking.recommendations[1].score, "ordering is by score desc");
  assert.ok(ranking.recommendations[0].score > 0.4, "fresh data lifts composite score");
  assert.ok(ranking.recommendations[0].signals.benchmarkFreshness >= 0.99, "same-day data is fresh = 1.0");
  assert.ok(Array.isArray(ranking.recommendations[0].citations), "citations present");
  assert.equal(ranking.recommendations[0].citations[0].attribution, "Artificial Analysis");
  assert.equal(ranking.recommendations[0].citations[0].logo, "/brand/sources/artificial-analysis.svg");
  assert.ok(ranking.topPickRationale.includes("GPT-5"), "rationale names the pick");
}

// ───────────────────────── 2. Stale benchmark data → lower confidence ──────

{
  const now = "2026-05-13T12:00:00.000Z";
  // Same scores as test 1, but the snapshots are 25 days old.
  const snapshots = [
    { source: "artificial_analysis", modelID: "openai/gpt-5", taskCategory: "coding", score: 0.9, freshness: "stale", confidence: 0.6, fetchedAt: "2026-04-18T08:00:00.000Z" },
    { source: "artificial_analysis", modelID: "anthropic/claude-opus-4-7", taskCategory: "coding", score: 0.86, freshness: "stale", confidence: 0.6, fetchedAt: "2026-04-18T08:00:00.000Z" },
  ];
  const statuses = [
    { source: "artificial_analysis", status: "stale", message: "data is older than 14 days", fetchedAt: "2026-04-18T08:00:00.000Z" },
  ];

  const ranking = buildTaskRanking({
    taskID: "coding",
    models: baseModels,
    snapshots,
    statuses,
    runtime,
    now,
  });

  const top = ranking.recommendations[0];
  assert.equal(top.modelID, "openai/gpt-5");
  assert.ok(top.signals.benchmarkFreshness <= 0.2, `stale data should produce low freshness signal, got ${top.signals.benchmarkFreshness}`);
  assert.ok(top.limitations.some((l) => /older than a week|too old/i.test(l)), "limitations call out staleness");
  assert.ok(top.score < 0.75, `stale-only evidence should not produce a fresh-quality composite, got ${top.score}`);
  assert.ok(ranking.note, "task-level note appears when no fresh evidence is available");
}

// ───────────────── 3. Missing source data → graceful source-status warning ──

{
  const now = "2026-05-13T12:00:00.000Z";
  const rundown = buildRundown({
    date: "2026-05-13",
    generatedAt: now,
    models: baseModels,
    snapshots: [],
    statuses: [
      { source: "artificial_analysis", status: "unavailable", message: "ARTIFICIAL_ANALYSIS_API_KEY not configured.", fetchedAt: null },
      { source: "terminal_bench", status: "error", message: "HF returned HTTP 502", fetchedAt: null },
    ],
    runtime,
  });

  assert.ok(rundown.sourceStatuses.length >= 2);
  const aa = rundown.sourceStatuses.find((s) => s.source === "artificial_analysis");
  assert.equal(aa.status, "unavailable");
  assert.equal(aa.attribution, "Artificial Analysis");
  assert.equal(aa.logo, "/brand/sources/artificial-analysis.svg");
  assert.ok(aa.message.length > 0);
  assert.equal(rundown.taskRankings.length, 0, "no benchmarks → no task rankings");
  assert.ok(rundown.globalLimitations.some((l) => /unavailable/i.test(l) || /never/i.test(l)));
}

// ─────────── 4. Missing cost / latency / context does not crash rendering ──

{
  const now = "2026-05-13T12:00:00.000Z";
  const sparseModels = baseModels.map((m) => ({
    ...m,
    contextWindowTokens: undefined,
    costSignal: undefined,
  }));
  const ranking = buildTaskRanking({
    taskID: "coding",
    models: sparseModels,
    snapshots: [
      { source: "artificial_analysis", modelID: "openai/gpt-5", taskCategory: "coding", score: 0.9, freshness: "fresh", confidence: 0.9, fetchedAt: "2026-05-13T08:00:00.000Z" },
    ],
    statuses: [{ source: "artificial_analysis", status: "fresh", message: "ok", fetchedAt: "2026-05-13T08:00:00.000Z" }],
    runtime: {},
    now,
  });
  const top = ranking.recommendations[0];
  assert.equal(top.modelID, "openai/gpt-5");
  assert.ok(top.score > 0, "score still produced from partial signals");
  assert.ok(top.limitations.length >= 2, "limitations explicitly call out missing fields");
  assert.ok(top.limitations.some((l) => /cost not reported/i.test(l)));
  assert.ok(top.limitations.some((l) => /context window not reported/i.test(l)));
  assert.equal(top.signals.contextWindowTokens, undefined);
  assert.equal(top.signals.cost, undefined);
}

// ────────── 5. Explanations / source statuses scrub secret material ────────

{
  const cleaned = redactExplanation(
    "Bearer sk-ant-api03-abcdef0123456789 AIzaSyA1234567890_AbcdEFghIJklMNopQR Authorization: sk-ant-leaked-key"
  );
  assert.ok(!/sk-ant/.test(cleaned), `expected sk-ant to be redacted, got ${cleaned}`);
  assert.ok(!/AIzaSy/.test(cleaned), `expected AIza* key to be redacted, got ${cleaned}`);
  assert.ok(/redacted/.test(cleaned));

  const now = "2026-05-13T12:00:00.000Z";
  const rundown = buildRundown({
    date: "2026-05-13",
    generatedAt: now,
    models: baseModels,
    snapshots: [
      { source: "artificial_analysis", modelID: "openai/gpt-5", taskCategory: "coding", score: 0.9, freshness: "fresh", confidence: 0.9, fetchedAt: "2026-05-13T08:00:00.000Z" },
    ],
    statuses: [
      { source: "artificial_analysis", status: "fresh", message: "Authorization: Bearer sk-ant-leaked-key", fetchedAt: "2026-05-13T08:00:00.000Z" },
    ],
    runtime,
    notes: ["sk-ant-api03-leaked-secret-should-not-render"],
  });
  const encoded = JSON.stringify(rundown);
  assert.ok(!/sk-ant/.test(encoded), `expected sk-ant tokens redacted in rundown, got ${encoded.slice(0, 400)}`);
  assert.ok(!/AIzaSy/.test(encoded));
}

// ────────────────── 6. Archive pages render for multiple dates ─────────────

{
  const files = await readdir(HISTORY_DIR).catch(() => []);
  const dateFiles = files.filter((f) => /^\d{4}-\d{2}-\d{2}\.json$/.test(f));
  // Archive starts at the first real research run. Historical days are
  // only present when a real run produced them; we don't pad with fixtures.
  assert.ok(dateFiles.length >= 1, `expected ≥1 archived rundown file, found ${dateFiles.length}`);
  for (const fileName of dateFiles) {
    const text = await readFile(path.join(HISTORY_DIR, fileName), "utf8");
    const parsed = JSON.parse(text);
    assert.equal(parsed.schemaVersion, 1);
    assert.ok(/^\d{4}-\d{2}-\d{2}$/.test(parsed.date));
    assert.ok(Array.isArray(parsed.sourceStatuses));
    assert.ok(Array.isArray(parsed.taskRankings));
    assert.ok(Array.isArray(parsed.globalLimitations));
    assert.ok(!/sk-ant|AIzaSy|Bearer\s+ey/i.test(text), `archive file ${fileName} must not contain secret-shaped strings`);
    for (const task of parsed.taskRankings) {
      assert.ok(task.recommendations.length >= 1);
      for (const rec of task.recommendations) {
        assert.ok(rec.modelDisplay && rec.providerDisplay);
        assert.ok(Array.isArray(rec.citations));
        assert.ok(Array.isArray(rec.explanation));
        assert.ok(Array.isArray(rec.limitations));
      }
    }
  }
}

// ────────────── 7. Weighting sanity check (composite math is sane) ─────────

{
  const totalWeight = Object.values(WEIGHTS).reduce((a, b) => a + b, 0);
  assert.ok(totalWeight > 0.99 && totalWeight < 1.01, `weights should approximately sum to 1.0, got ${totalWeight}`);
}

console.log("router-rundown generator: 7 test groups passed");
