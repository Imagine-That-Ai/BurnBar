#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
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
const POLICY = JSON.parse(readFileSync(join(REPO_ROOT, "config", "domain-core-promotion-policy.json"), "utf8"));
const NOW = "2026-07-13T00:00:00Z";

function validEvidence(domain = "quota") {
  const coverage = requiredCoverageForDomain(domain);
  const sampleCount = Math.ceil(POLICY.domains[domain].minimumSamples / coverage.length);
  return {
    schemaVersion: 2,
    domain,
    coreVersion: "0.3.0",
    generatedAt: "2026-07-12T01:00:00Z",
    provenance: {
      collector: "domain-core-shadow-exporter",
      queryRevision: "0123456789abcdef0123456789abcdef01234567",
      sourceUri: "https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples",
    },
    windows: coverage.map(({ slice, consumer }) => ({
      slice,
      consumer,
      channel: "internal",
      startedAt: "2026-06-28T00:00:00Z",
      endedAt: "2026-07-12T00:00:00Z",
      sampleCount,
      mismatches: [],
      latency: { sampleCount, legacyP95Micros: 100, rustP95Micros: 105 },
    })),
  };
}

test("every declared domain is ready only with complete V2 slice/consumer coverage", () => {
  for (const domain of ["quota", "cloudvault", "hermes", "pricing"]) {
    const report = evaluatePromotionEvidence(validEvidence(domain), POLICY, { now: NOW });
    assert.equal(report.status, "ready", domain);
    assert.deepEqual(
      report.summary.coverage.map(({ slice, consumer }) => `${slice}:${consumer}`),
      requiredCoverageForDomain(domain).map(({ slice, consumer }) => `${slice}:${consumer}`),
    );
  }
});

test("missing one required slice/consumer pair blocks promotion", () => {
  const evidence = validEvidence("cloudvault");
  evidence.windows = evidence.windows.filter((item) => !(item.slice === "search" && item.consumer === "android"));
  const report = evaluatePromotionEvidence(evidence, POLICY, { now: NOW });
  assert.equal(report.status, "not_ready");
  assert.ok(report.blockers.some((item) => item.code === "required_coverage_missing" && item.slice === "search" && item.consumer === "android"));
});

test("invented and duplicated coverage identities are invalid", () => {
  const invented = validEvidence("pricing");
  invented.windows[0].consumer = "windows";
  assert.equal(evaluatePromotionEvidence(invented, POLICY, { now: NOW }).status, "invalid");

  const duplicated = validEvidence("hermes");
  duplicated.windows.push({ ...duplicated.windows[0] });
  assert.equal(evaluatePromotionEvidence(duplicated, POLICY, { now: NOW }).status, "invalid");
});

test("V1 remains readable but can never satisfy the V2 promotion policy", () => {
  const evidence = {
    schemaVersion: 1,
    domain: "quota",
    coreVersion: "0.2.0",
    generatedAt: "2026-07-12T01:00:00Z",
    provenance: validEvidence().provenance,
    windows: [{ consumer: "apple" }],
  };
  const report = evaluatePromotionEvidence(evidence, POLICY, { now: NOW });
  assert.equal(report.status, "not_ready");
  assert.equal(report.sourceSchemaVersion, 1);
  assert.deepEqual(report.blockers, [{ code: "evidence_schema_v2_required", slice: null, consumer: null }]);
});

test("quantitative and review gates fail closed per coverage cell", () => {
  const cases = [
    ["insufficient coverage", (e) => { e.windows[0].startedAt = "2026-07-11T00:00:00Z"; }, "insufficient_coverage"],
    ["sample count", (e) => { for (const item of e.windows) item.sampleCount = item.latency.sampleCount = 1; }, "insufficient_samples"],
    ["unexplained mismatch", (e) => { e.windows[0].mismatches = [{ category: "result_mismatch", count: 1, resolution: "unexplained" }]; }, "unexplained_mismatches"],
    ["latency regression", (e) => { e.windows[0].latency.rustP95Micros = 106; }, "p95_regression_exceeded"],
    ["production channel", (e) => { e.windows[0].channel = "production"; }, "channel_not_eligible"],
  ];
  for (const [label, mutate, blocker] of cases) {
    const evidence = validEvidence();
    mutate(evidence);
    const report = evaluatePromotionEvidence(evidence, POLICY, { now: NOW });
    assert.equal(report.status, "not_ready", label);
    assert.ok(report.blockers.some((item) => item.code === blocker), label);
  }
});

test("explained mismatches require a linked issue, reviewer, and approval timestamp", () => {
  const valid = validEvidence();
  valid.windows[0].mismatches = [{
    category: "invalid_result",
    count: 2,
    resolution: "explained",
    issue: "https://github.com/Imagine-That-Ai/BurnBar/issues/123",
    reviewedBy: "@reviewer",
    approvedAt: "2026-07-11T00:00:00Z",
  }];
  assert.equal(evaluatePromotionEvidence(valid, POLICY, { now: NOW }).status, "ready");

  const invalid = validEvidence();
  invalid.windows[0].mismatches = [{ category: "invalid_result", count: 1, resolution: "explained" }];
  assert.equal(evaluatePromotionEvidence(invalid, POLICY, { now: NOW }).status, "invalid");
});

test("policy cannot omit a real consumer to weaken the gate", () => {
  const weakened = structuredClone(POLICY);
  weakened.domains.cloudvault.requiredCoverage.pop();
  const report = evaluatePromotionEvidence(validEvidence("cloudvault"), weakened, { now: NOW });
  assert.equal(report.status, "invalid");
  assert.ok(report.errors.some((item) => item.includes("omits real coverage")));
});

test("random malformed JSON values never throw or promote", () => {
  let state = 0x5eed1234;
  const random = () => ((state = (state * 1664525 + 1013904223) >>> 0) / 0x1_0000_0000);
  const scalar = () => [null, true, false, random(), `v-${state}`, Number.MAX_SAFE_INTEGER + 1][Math.floor(random() * 6)];
  for (let index = 0; index < 500; index += 1) {
    const value = random() < 0.5 ? scalar() : { [String(scalar())]: scalar(), schemaVersion: Math.floor(random() * 4) };
    let report;
    assert.doesNotThrow(() => { report = evaluatePromotionEvidence(value, POLICY, { now: NOW }); });
    assert.equal(report.ready, false);
  }
});

test("CLI requires and binds --domain with distinct exit codes", () => {
  const directory = mkdtempSync(join(tmpdir(), "domain-core-evidence-v2-"));
  try {
    const evidencePath = join(directory, "evidence.json");
    const outputPath = join(directory, "report.json");
    writeFileSync(evidencePath, JSON.stringify(validEvidence("quota")));
    const stdout = execFileSync(process.execPath, [CLI, "--domain", "quota", "--evidence", evidencePath, "--output", outputPath], { encoding: "utf8" });
    assert.equal(JSON.parse(stdout).status, "ready");
    assert.equal(JSON.parse(readFileSync(outputPath, "utf8")).domain, "quota");

    const wrong = spawnSync(process.execPath, [CLI, "--domain", "hermes", "--evidence", evidencePath], { encoding: "utf8" });
    assert.equal(wrong.status, 1);
    assert.equal(JSON.parse(wrong.stdout).status, "invalid");

    const blocked = validEvidence("quota");
    blocked.windows.pop();
    writeFileSync(evidencePath, JSON.stringify(blocked));
    const notReady = spawnSync(process.execPath, [CLI, "--domain", "quota", "--evidence", evidencePath], { encoding: "utf8" });
    assert.equal(notReady.status, 2);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
