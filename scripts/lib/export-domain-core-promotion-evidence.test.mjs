import assert from "node:assert/strict";
import test from "node:test";

import { evaluatePromotionEvidence } from "./domain-core-promotion-evidence.mjs";
import {
  buildDomainCorePromotionEvidence,
  parseStoredDomainCoreShadowSample,
} from "./export-domain-core-promotion-evidence.mjs";

const START = "2026-06-29T00:00:00.000Z";
const END = "2026-07-13T00:00:00.000Z";
const REVISION = "a".repeat(40);

function record(consumer, suffix, overrides = {}) {
  return {
    schemaVersion: 1,
    sampleId: `00000000-0000-4000-8000-${suffix.toString().padStart(12, "0")}`,
    domain: "quota",
    consumer,
    channel: "internal",
    operation: "claude_quota",
    coreVersion: "0.3.0",
    observedAt: `2026-07-${String(1 + (suffix % 12)).padStart(2, "0")}T00:00:00.000Z`,
    outcome: "match",
    mismatchCategory: null,
    legacyMicros: 100 + suffix,
    rustMicros: 90 + suffix,
    receivedAt: "2026-07-13T00:00:00.000Z",
    expireAt: "2026-09-11T00:00:00.000Z",
    ...overrides,
  };
}

function options() {
  return {
    channel: "internal",
    coreVersion: "0.3.0",
    startedAt: START,
    endedAt: END,
    generatedAt: "2026-07-13T00:01:00.000Z",
    queryRevision: REVISION,
    sourceUri: "https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples",
  };
}

test("exporter builds exact evaluator input for both required consumers", () => {
  const records = [
    ...Array.from({ length: 20 }, (_, index) => record("apple", index + 1)),
    ...Array.from({ length: 20 }, (_, index) => record("windows", index + 101)),
  ];
  const evidence = buildDomainCorePromotionEvidence(records, options());
  const report = evaluatePromotionEvidence(
    evidence,
    {
      schemaVersion: 1,
      domains: {
        quota: {
          requiredConsumers: ["apple", "windows"],
          allowedChannels: ["internal", "beta"],
          minimumCoverageSeconds: 1,
          minimumSamples: 2,
          maximumP95RegressionBasisPoints: 500,
        },
      },
    },
    { now: "2026-07-13T00:02:00.000Z" },
  );

  assert.equal(report.status, "ready");
  assert.deepEqual(evidence.windows.map((window) => window.consumer), ["apple", "windows"]);
  assert.equal(evidence.windows[0].latency.sampleCount, 20);
});

test("exporter carries mismatches as unexplained promotion blockers", () => {
  const evidence = buildDomainCorePromotionEvidence(
    [
      record("apple", 1, { outcome: "mismatch", mismatchCategory: "result_mismatch" }),
      record("apple", 2),
      record("windows", 3),
      record("windows", 4),
    ],
    options(),
  );

  assert.deepEqual(evidence.windows[0].mismatches, [
    { category: "result_mismatch", count: 1, resolution: "unexplained" },
  ]);
});

test("exporter rejects unexpected stored fields and duplicate IDs", () => {
  assert.throws(() => parseStoredDomainCoreShadowSample({ ...record("apple", 1), uid: "secret" }), /field set/u);
  assert.throws(
    () => buildDomainCorePromotionEvidence([record("apple", 1), record("apple", 1)], options()),
    /duplicate sampleId/u,
  );
});

test("exporter fails closed when either consumer has no samples", () => {
  assert.throws(
    () => buildDomainCorePromotionEvidence([record("apple", 1), record("apple", 2)], options()),
    /No windows samples/u,
  );
});

test("query bounds cannot inflate densely clustered samples into rollout coverage", () => {
  const dense = [
    record("apple", 1, { observedAt: "2026-07-01T00:00:00.000Z" }),
    record("apple", 2, { observedAt: "2026-07-01T01:00:00.000Z" }),
    record("windows", 3, { observedAt: "2026-07-01T00:00:00.000Z" }),
    record("windows", 4, { observedAt: "2026-07-01T01:00:00.000Z" }),
  ];
  const evidence = buildDomainCorePromotionEvidence(dense, options());
  const report = evaluatePromotionEvidence(
    evidence,
    {
      schemaVersion: 1,
      domains: {
        quota: {
          requiredConsumers: ["apple", "windows"],
          allowedChannels: ["internal", "beta"],
          minimumCoverageSeconds: 14 * 24 * 60 * 60,
          minimumSamples: 4,
          maximumP95RegressionBasisPoints: 500,
        },
      },
    },
    { now: "2026-07-13T00:02:00.000Z" },
  );

  assert.equal(report.status, "not_ready");
  assert.equal(report.ready, false);
  assert.deepEqual(
    report.blockers.filter((blocker) => blocker.code === "insufficient_coverage").map((blocker) => blocker.consumer),
    ["apple", "windows"],
  );
});
