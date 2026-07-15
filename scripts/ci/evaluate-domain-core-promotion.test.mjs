#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { evaluatePromotionEvidence } from "../lib/domain-core-promotion-evidence.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, "..", "..");
const CLI = join(SCRIPT_DIR, "evaluate-domain-core-promotion.mjs");
const POLICY_PATH = join(REPO_ROOT, "config", "domain-core-promotion-policy.json");
const POLICY = JSON.parse(readFileSync(POLICY_PATH, "utf8"));
const NOW = "2020-07-16T00:00:00Z";

function validEvidence() {
  return {
    schemaVersion: 1,
    domain: "quota",
    coreVersion: "0.1.0",
    generatedAt: "2020-07-15T01:00:00Z",
    provenance: {
      collector: "domain-core-shadow-v1",
      queryRevision: "0123456789abcdef0123456789abcdef01234567",
      sourceUri: "https://github.com/openburnbar/openburnbar/actions/runs/123456",
    },
    windows: [
      {
        consumer: "apple",
        channel: "beta",
        startedAt: "2020-07-01T00:00:00Z",
        endedAt: "2020-07-15T00:00:00Z",
        sampleCount: 6000,
        mismatches: [],
        latency: {
          sampleCount: 6000,
          legacyP95Micros: 1000,
          rustP95Micros: 1050,
        },
      },
      {
        consumer: "windows",
        channel: "internal",
        startedAt: "2020-07-01T00:00:00Z",
        endedAt: "2020-07-15T00:00:00Z",
        sampleCount: 4000,
        mismatches: [],
        latency: {
          sampleCount: 4000,
          legacyP95Micros: 2000,
          rustP95Micros: 1800,
        },
      },
    ],
  };
}

function evaluate(evidence) {
  return evaluatePromotionEvidence(evidence, POLICY, { now: NOW });
}

function blockerCodes(report) {
  return report.blockers.map((blocker) => blocker.code);
}

test("exact threshold evidence is promotion-ready", () => {
  const report = evaluate(validEvidence());
  assert.equal(report.status, "ready");
  assert.equal(report.ready, true);
  assert.equal(report.summary.totalSamples, 10000);
  assert.deepEqual(report.blockers, []);
  assert.equal(report.summary.consumers[0].p95RegressionBasisPoints, 500);
});

test("every quantitative gate fails closed independently", () => {
  const cases = [
    [
      "sample count",
      (evidence) => {
        evidence.windows[0].sampleCount -= 1;
        evidence.windows[0].latency.sampleCount -= 1;
      },
      "insufficient_samples",
    ],
    [
      "coverage duration",
      (evidence) => {
        evidence.windows[0].startedAt = "2020-07-01T00:00:01Z";
      },
      "insufficient_coverage",
    ],
    [
      "required consumer",
      (evidence) => {
        evidence.windows.pop();
        evidence.windows[0].sampleCount = 10000;
        evidence.windows[0].latency.sampleCount = 10000;
      },
      "required_consumer_missing",
    ],
    [
      "eligible channel",
      (evidence) => {
        evidence.windows[0].channel = "production";
      },
      "channel_not_eligible",
    ],
    [
      "latency regression",
      (evidence) => {
        evidence.windows[0].latency.rustP95Micros = 1051;
      },
      "p95_regression_exceeded",
    ],
    [
      "unexplained mismatch",
      (evidence) => {
        evidence.windows[0].mismatches.push({
          category: "reset_rounding",
          count: 1,
          resolution: "unexplained",
        });
      },
      "unexplained_mismatches",
    ],
  ];

  for (const [label, mutate, expected] of cases) {
    const evidence = validEvidence();
    mutate(evidence);
    const report = evaluate(evidence);
    assert.equal(report.ready, false, label);
    assert.equal(report.status, "not_ready", label);
    assert.ok(blockerCodes(report).includes(expected), label);
  }
});

test("reviewed explained categories are counted without exposing review metadata", () => {
  const evidence = validEvidence();
  evidence.windows[0].mismatches.push({
    category: "legacy_precision",
    count: 3,
    resolution: "explained",
    issue: "https://github.com/openburnbar/openburnbar/issues/123",
    reviewedBy: "@reviewer",
    approvedAt: "2020-07-15T00:30:00Z",
  });
  const report = evaluate(evidence);
  assert.equal(report.ready, true);
  assert.equal(report.summary.unexplainedMismatchCount, 0);
  assert.doesNotMatch(JSON.stringify(report), /reviewer|issues\/123/u);
});

test("an explained category without independent review is invalid", () => {
  const evidence = validEvidence();
  evidence.windows[0].mismatches.push({
    category: "legacy_precision",
    count: 3,
    resolution: "explained",
  });
  const report = evaluate(evidence);
  assert.equal(report.status, "invalid");
  assert.ok(report.errors.some((error) => error.includes("reviewedBy")));
});

test("schema ambiguity and cherry-picked latency samples are invalid", () => {
  const cases = [
    (evidence) => {
      evidence.unrecognized = true;
    },
    (evidence) => {
      evidence.windows[1].consumer = "apple";
    },
    (evidence) => {
      evidence.windows[0].latency.sampleCount = 100;
    },
    (evidence) => {
      evidence.generatedAt = "2020-07-16T00:06:00Z";
    },
    (evidence) => {
      evidence.windows[0].endedAt = evidence.generatedAt;
      evidence.windows[0].startedAt = evidence.generatedAt;
    },
    (evidence) => {
      evidence.provenance.sourceUri = "https://example.com/run?token=secret";
    },
    (evidence) => {
      evidence.generatedAt = "2020-02-30T00:00:00Z";
    },
  ];
  for (const mutate of cases) {
    const evidence = validEvidence();
    mutate(evidence);
    assert.equal(evaluate(evidence).status, "invalid");
  }
});

test("invalid policy cannot weaken the gate", () => {
  const cases = [
    (policy) => {
      policy.domains.quota.minimumSamples = -1;
    },
    (policy) => {
      policy.domains.quota.requiredConsumers = [];
    },
    (policy) => {
      policy.domains.quota.maximumP95RegressionBasisPoints = 1.5;
    },
    (policy) => {
      policy.domains.quota.unreviewedOverride = true;
    },
  ];
  for (const mutate of cases) {
    const policy = structuredClone(POLICY);
    mutate(policy);
    const report = evaluatePromotionEvidence(validEvidence(), policy, { now: NOW });
    assert.equal(report.ready, false);
    assert.equal(report.status, "invalid");
  }
});

test("random malformed JSON values never throw or promote", () => {
  let state = 0x5eed1234;
  const random = () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
  const scalar = () => [null, true, false, random(), `value-${state}`][Math.floor(random() * 5)];
  const arbitrary = (depth = 0) => {
    if (depth > 2 || random() < 0.45) return scalar();
    if (random() < 0.5) {
      return Array.from({ length: Math.floor(random() * 5) }, () => arbitrary(depth + 1));
    }
    return Object.fromEntries(
      Array.from({ length: Math.floor(random() * 5) }, (_, index) => [
        `field${index}`,
        arbitrary(depth + 1),
      ]),
    );
  };

  for (let index = 0; index < 2000; index += 1) {
    const report = evaluate(arbitrary());
    assert.equal(report.ready, false);
    assert.equal(report.status, "invalid");
  }
});

test("CLI emits machine-readable reports and distinct exit codes", () => {
  const root = mkdtempSync(join(tmpdir(), "domain-core-evidence-test-"));
  try {
    const evidencePath = join(root, "evidence.json");
    const outputPath = join(root, "report.json");
    writeFileSync(evidencePath, JSON.stringify(validEvidence()));
    const ready = execFileSync(
      "node",
      [CLI, "--evidence", evidencePath, "--output", outputPath],
      { encoding: "utf8" },
    );
    assert.equal(JSON.parse(ready).status, "ready");
    assert.deepEqual(JSON.parse(readFileSync(outputPath, "utf8")), JSON.parse(ready));

    const notReady = validEvidence();
    notReady.windows[0].latency.rustP95Micros = 2000;
    writeFileSync(evidencePath, JSON.stringify(notReady));
    assert.throws(
      () => execFileSync("node", [CLI, "--evidence", evidencePath]),
      (error) => error.status === 2 && JSON.parse(error.stdout).status === "not_ready",
    );

    writeFileSync(evidencePath, "{not-json");
    assert.throws(
      () => execFileSync("node", [CLI, "--evidence", evidencePath]),
      (error) => error.status === 1 && JSON.parse(error.stdout).status === "invalid",
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
