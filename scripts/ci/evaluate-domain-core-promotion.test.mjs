#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { requiredCoverageForDomain } from "../lib/domain-core-evidence-contract.mjs";
import { evaluatePromotionEvidence } from "../lib/domain-core-promotion-evidence.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, "..", "..");
const CLI = join(SCRIPT_DIR, "evaluate-domain-core-promotion.mjs");
const POLICY = JSON.parse(
  readFileSync(
    join(REPO_ROOT, "config", "domain-core-shadow-diagnostic-policy.json"),
    "utf8",
  ),
);
const NOW = "2026-07-13T00:00:00Z";
const START = "2026-06-28T00:00:00Z";
const END = "2026-07-12T00:00:00Z";
const CANDIDATE = "0123456789abcdef0123456789abcdef01234567";
const SOURCE_SHA = "a".repeat(64);

function utcDays(startedAt, endedAt) {
  const days = [];
  let cursor = Date.parse(startedAt);
  while (cursor < Date.parse(endedAt)) {
    days.push(new Date(cursor).toISOString().slice(0, 10));
    cursor += 24 * 60 * 60 * 1_000;
  }
  return days;
}

function dailySampleCounts(total) {
  const days = utcDays(START, END);
  const base = Math.floor(total / days.length);
  let remainder = total % days.length;
  return days.map((date) => ({
    date,
    sampleCount: base + (remainder-- > 0 ? 1 : 0),
  }));
}

function validEvidence(domain = "quota") {
  const coverage = requiredCoverageForDomain(domain);
  const sampleCount = 14;
  const candidate = {
    candidateCommit: CANDIDATE,
    expectedCoreVersion: "0.3.0",
    expectedCoreAbiVersion: 3,
    expectedCoreSourceSha256: SOURCE_SHA,
  };
  return {
    schemaVersion: 3,
    domain,
    ...candidate,
    generatedAt: "2026-07-12T01:00:00Z",
    provenance: {
      collector: "domain-core-shadow-exporter",
      ...candidate,
      sourceUri:
        "https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples",
    },
    windows: coverage.map(({ slice, consumer }) => ({
      slice,
      consumer,
      channel: "internal",
      startedAt: START,
      endedAt: END,
      sampleCount,
      dailySampleCounts: dailySampleCounts(sampleCount),
      mismatches: [],
      latency: { sampleCount, legacyP95Micros: 100, rustP95Micros: 105 },
    })),
  };
}

test("complete candidate-bound V3 coverage remains diagnostic-only", () => {
  for (const domain of ["quota", "cloudvault", "hermes", "pricing"]) {
    const report = evaluatePromotionEvidence(validEvidence(domain), POLICY, {
      now: NOW,
    });
    assert.equal(report.status, "diagnostic", domain);
    assert.equal(report.ready, false, domain);
    assert.equal(report.authority, "diagnostic-only", domain);
    assert.ok(
      report.blockers.some(
        (item) => item.code === "deterministic_proof_required",
      ),
      domain,
    );
    assert.equal(report.candidateCommit, CANDIDATE);
    assert.equal(report.expectedCoreSourceSha256, SOURCE_SHA);
    assert.equal(report.provenance.candidateCommit, CANDIDATE);
    assert.deepEqual(
      report.summary.coverage.map(
        ({ slice, consumer }) => `${slice}:${consumer}`,
      ),
      requiredCoverageForDomain(domain).map(
        ({ slice, consumer }) => `${slice}:${consumer}`,
      ),
    );
  }
});

test("V1 and V2 are readable drain formats but never promotion evidence", () => {
  for (const schemaVersion of [1, 2]) {
    const evidence = {
      schemaVersion,
      domain: "quota",
      coreVersion: "0.2.0",
      generatedAt: "2026-07-12T01:00:00Z",
      windows: [],
    };
    const report = evaluatePromotionEvidence(evidence, POLICY, { now: NOW });
    assert.equal(report.status, "not_ready");
    assert.equal(report.sourceSchemaVersion, schemaVersion);
    assert.deepEqual(report.blockers, [
      { code: "evidence_schema_v3_required", slice: null, consumer: null },
    ]);
  }
});

test("candidate tuple must be internally consistent with signed provenance", () => {
  for (const [field, value] of [
    ["candidateCommit", "89abcdef0123456789abcdef0123456789abcdef"],
    ["expectedCoreVersion", "0.3.1"],
    ["expectedCoreAbiVersion", 4],
    ["expectedCoreSourceSha256", "b".repeat(64)],
  ]) {
    const evidence = validEvidence();
    evidence.provenance[field] = value;
    const report = evaluatePromotionEvidence(evidence, POLICY, { now: NOW });
    assert.equal(report.status, "invalid", field);
    assert.ok(
      report.errors.some((error) => error.includes(`provenance.${field}`)),
      field,
    );
  }
});

test("candidate core version must be canonical SemVer", () => {
  for (const invalid of ["01.2.3", "1.02.3", "1.2.03", "1.2.3-01"]) {
    const evidence = validEvidence();
    evidence.expectedCoreVersion = invalid;
    evidence.provenance.expectedCoreVersion = invalid;
    assert.equal(
      evaluatePromotionEvidence(evidence, POLICY, { now: NOW }).status,
      "invalid",
      invalid,
    );
  }
});

test("missing one required slice/consumer pair remains a diagnostic alert", () => {
  const evidence = validEvidence("cloudvault");
  evidence.windows = evidence.windows.filter(
    (item) => !(item.slice === "search" && item.consumer === "android"),
  );
  const report = evaluatePromotionEvidence(evidence, POLICY, { now: NOW });
  assert.equal(report.status, "diagnostic");
  assert.equal(report.ready, false);
  assert.ok(
    report.blockers.some(
      (item) =>
        item.code === "required_coverage_missing" &&
        item.slice === "search" &&
        item.consumer === "android",
    ),
  );
});

test("UTC daily continuity is structural evidence, not a min/max approximation", () => {
  const missing = validEvidence();
  missing.windows[0].dailySampleCounts.splice(5, 1);
  assert.equal(
    evaluatePromotionEvidence(missing, POLICY, { now: NOW }).status,
    "invalid",
  );

  const duplicate = validEvidence();
  duplicate.windows[0].dailySampleCounts[1].date =
    duplicate.windows[0].dailySampleCounts[0].date;
  assert.equal(
    evaluatePromotionEvidence(duplicate, POLICY, { now: NOW }).status,
    "invalid",
  );

  const staggered = validEvidence();
  staggered.windows[1].startedAt = "2026-06-27T00:00:00Z";
  staggered.windows[1].dailySampleCounts = [
    { date: "2026-06-27", sampleCount: 1 },
    ...staggered.windows[1].dailySampleCounts,
  ];
  staggered.windows[1].sampleCount += 1;
  staggered.windows[1].latency.sampleCount += 1;
  assert.equal(
    evaluatePromotionEvidence(staggered, POLICY, { now: NOW }).status,
    "invalid",
  );
});

test("mismatch, performance, and channel alerts remain diagnostic-only", () => {
  const cases = [
    [
      "unexplained mismatch",
      (e) => {
        e.windows[0].mismatches = [
          { category: "result_mismatch", count: 1, resolution: "unexplained" },
        ];
      },
      "unexplained_mismatches",
    ],
    [
      "latency regression",
      (e) => {
        e.windows[0].latency.rustP95Micros = 106;
      },
      "p95_regression_exceeded",
    ],
    [
      "production channel",
      (e) => {
        e.windows[0].channel = "production";
      },
      "channel_not_eligible",
    ],
  ];
  for (const [label, mutate, blocker] of cases) {
    const evidence = validEvidence();
    mutate(evidence);
    const report = evaluatePromotionEvidence(evidence, POLICY, { now: NOW });
    assert.equal(report.status, "diagnostic", label);
    assert.equal(report.ready, false, label);
    assert.ok(
      report.blockers.some((item) => item.code === blocker),
      label,
    );
  }
});

test("explained mismatches require a linked issue, reviewer, and approval timestamp", () => {
  const valid = validEvidence();
  valid.windows[0].mismatches = [
    {
      category: "invalid_result",
      count: 2,
      resolution: "explained",
      issue: "https://github.com/Imagine-That-Ai/BurnBar/issues/123",
      reviewedBy: "@reviewer",
      approvedAt: "2026-07-11T00:00:00Z",
    },
  ];
  assert.equal(
    evaluatePromotionEvidence(valid, POLICY, { now: NOW }).status,
    "diagnostic",
  );

  const invalid = validEvidence();
  invalid.windows[0].mismatches = [
    { category: "invalid_result", count: 1, resolution: "explained" },
  ];
  assert.equal(
    evaluatePromotionEvidence(invalid, POLICY, { now: NOW }).status,
    "invalid",
  );
});

test("policy cannot omit a real consumer to weaken the gate", () => {
  const weakened = structuredClone(POLICY);
  weakened.domains.cloudvault.requiredCoverage.pop();
  const report = evaluatePromotionEvidence(
    validEvidence("cloudvault"),
    weakened,
    { now: NOW },
  );
  assert.equal(report.status, "invalid");
  assert.ok(report.errors.some((item) => item.includes("omits real coverage")));
});

test("random malformed JSON values never throw or promote", () => {
  let state = 0x5eed1234;
  const random = () =>
    (state = (state * 1664525 + 1013904223) >>> 0) / 0x1_0000_0000;
  const scalar = () =>
    [null, true, false, random(), `v-${state}`, Number.MAX_SAFE_INTEGER + 1][
      Math.floor(random() * 6)
    ];
  for (let index = 0; index < 500; index += 1) {
    const value =
      random() < 0.5
        ? scalar()
        : {
            [String(scalar())]: scalar(),
            schemaVersion: Math.floor(random() * 5),
          };
    let report;
    assert.doesNotThrow(() => {
      report = evaluatePromotionEvidence(value, POLICY, { now: NOW });
    });
    assert.equal(report.ready, false);
  }
});

test("CLI requires and binds --domain with distinct exit codes", () => {
  const directory = mkdtempSync(join(tmpdir(), "domain-core-evidence-v3-"));
  try {
    const evidencePath = join(directory, "evidence.json");
    const outputPath = join(directory, "report.json");
    writeFileSync(evidencePath, JSON.stringify(validEvidence("quota")));
    const diagnostic = spawnSync(
      process.execPath,
      [
        CLI,
        "--domain",
        "quota",
        "--evidence",
        evidencePath,
        "--output",
        outputPath,
      ],
      { encoding: "utf8" },
    );
    assert.equal(diagnostic.status, 2);
    assert.equal(JSON.parse(diagnostic.stdout).status, "diagnostic");
    assert.equal(
      JSON.parse(readFileSync(outputPath, "utf8")).candidateCommit,
      CANDIDATE,
    );

    const wrong = spawnSync(
      process.execPath,
      [CLI, "--domain", "hermes", "--evidence", evidencePath],
      { encoding: "utf8" },
    );
    assert.equal(wrong.status, 1);
    assert.equal(JSON.parse(wrong.stdout).schemaVersion, 3);

    const missing = spawnSync(
      process.execPath,
      [CLI, "--domain", "quota", "--evidence", join(directory, "missing.json")],
      { encoding: "utf8" },
    );
    assert.equal(missing.status, 1);
    assert.equal(JSON.parse(missing.stdout).schemaVersion, 3);

    const duplicate = spawnSync(
      process.execPath,
      [
        CLI,
        "--domain",
        "quota",
        "--domain",
        "hermes",
        "--evidence",
        evidencePath,
      ],
      { encoding: "utf8" },
    );
    assert.equal(duplicate.status, 1);
    assert.match(duplicate.stderr, /duplicate argument: --domain/u);

    const blocked = validEvidence("quota");
    blocked.windows.pop();
    writeFileSync(evidencePath, JSON.stringify(blocked));
    const notReady = spawnSync(
      process.execPath,
      [CLI, "--domain", "quota", "--evidence", evidencePath],
      { encoding: "utf8" },
    );
    assert.equal(notReady.status, 2);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
