import assert from "node:assert/strict";
import test from "node:test";

import { requiredCoverageForDomain } from "./domain-core-evidence-contract.mjs";
import { evaluatePromotionEvidence } from "./domain-core-promotion-evidence.mjs";
import {
  buildDomainCorePromotionEvidence,
  parseStoredDomainCoreShadowSample,
} from "./export-domain-core-promotion-evidence.mjs";

const START = "2026-07-01T00:00:00.000Z";
const END = "2026-07-15T00:00:00.000Z";
const REVISION = "0123456789abcdef0123456789abcdef01234567";

function operation(domain, slice) {
  if (domain === "quota") return `${slice}_quota`;
  return `${slice.replaceAll("-", "_")}_comparison`;
}

function record(domain, slice, consumer, suffix, overrides = {}) {
  return {
    schemaVersion: 2,
    sampleId: `00000000-0000-4000-8000-${suffix.toString(16).padStart(12, "0")}`,
    domain,
    slice,
    consumer,
    channel: "internal",
    operation: operation(domain, slice),
    coreVersion: "0.3.0",
    observedAt: suffix % 2 === 0 ? START : END,
    outcome: "match",
    mismatchCategory: null,
    legacyMicros: 100 + suffix,
    rustMicros: 90 + suffix,
    receivedAt: "2026-07-15T00:00:00.000Z",
    expireAt: "2026-09-13T00:00:00.000Z",
    ...overrides,
  };
}

function recordsFor(domain) {
  let suffix = 1;
  return requiredCoverageForDomain(domain).flatMap(({ slice, consumer }) => [
    record(domain, slice, consumer, suffix++),
    record(domain, slice, consumer, suffix++),
  ]);
}

function options(domain) {
  return {
    domain,
    channel: "internal",
    coreVersion: "0.3.0",
    startedAt: START,
    endedAt: END,
    generatedAt: "2026-07-15T00:01:00.000Z",
    queryRevision: REVISION,
    sourceUri: "https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples",
  };
}

function lowPolicy(domain) {
  return {
    schemaVersion: 2,
    domains: {
      [domain]: {
        requiredCoverage: requiredCoverageForDomain(domain),
        allowedChannels: ["internal", "beta"],
        minimumCoverageSeconds: 1,
        minimumSamples: 2,
        maximumP95RegressionBasisPoints: 500,
      },
    },
  };
}

test("exporter builds exact V2 evaluator input for every domain and real coverage pair", () => {
  for (const domain of ["quota", "cloudvault", "hermes", "pricing"]) {
    const evidence = buildDomainCorePromotionEvidence(recordsFor(domain), options(domain));
    const report = evaluatePromotionEvidence(evidence, lowPolicy(domain), { now: "2026-07-15T00:02:00.000Z" });
    assert.equal(report.status, "ready", domain);
    assert.deepEqual(
      evidence.windows.map(({ slice, consumer }) => `${slice}:${consumer}`),
      requiredCoverageForDomain(domain).map(({ slice, consumer }) => `${slice}:${consumer}`),
    );
  }
});

test("exporter carries mismatches as unexplained promotion blockers", () => {
  const records = recordsFor("pricing");
  records[0] = { ...records[0], outcome: "mismatch", mismatchCategory: "result_mismatch" };
  const evidence = buildDomainCorePromotionEvidence(records, options("pricing"));
  assert.deepEqual(evidence.windows[0].mismatches, [
    { category: "result_mismatch", count: 1, resolution: "unexplained" },
  ]);
});

test("stored V1 is readable but cannot be silently upgraded into promotion coverage", () => {
  const v2 = record("quota", "claude", "apple", 1);
  const { slice: _slice, ...v1 } = { ...v2, schemaVersion: 1, sampleId: "00000000-0000-4000-8000-ffffffffffff" };
  assert.equal(parseStoredDomainCoreShadowSample(v1).schemaVersion, 1);
  assert.throws(
    () => buildDomainCorePromotionEvidence([v1, ...recordsFor("quota").filter((item) => item.consumer === "apple")], options("quota")),
    /No quota\/claude\/windows V2 samples/u,
  );
});

test("exporter rejects unexpected stored fields, invalid identities, and duplicate IDs", () => {
  assert.throws(() => parseStoredDomainCoreShadowSample({ ...record("quota", "claude", "apple", 1), uid: "secret" }), /field set/u);
  assert.throws(() => parseStoredDomainCoreShadowSample(record("pricing", "legacy-kimi", "apple", 1)), /domain, slice, or consumer/u);
  assert.throws(
    () => buildDomainCorePromotionEvidence([record("quota", "claude", "apple", 1), record("quota", "claude", "apple", 1)], options("quota")),
    /duplicate sampleId/u,
  );
});

test("exporter fails closed when one policy-required coverage cell is absent", () => {
  const records = recordsFor("hermes").filter((item) => !(item.slice === "ratchet" && item.consumer === "android"));
  assert.throws(
    () => buildDomainCorePromotionEvidence(records, options("hermes")),
    /No hermes\/ratchet\/android V2 samples/u,
  );
});

test("query bounds cannot inflate densely clustered samples into rollout coverage", () => {
  const records = recordsFor("quota").map((item, index) => ({
    ...item,
    observedAt: index % 2 === 0 ? "2026-07-01T00:00:00.000Z" : "2026-07-01T01:00:00.000Z",
  }));
  const evidence = buildDomainCorePromotionEvidence(records, options("quota"));
  const policy = lowPolicy("quota");
  policy.domains.quota.minimumCoverageSeconds = 14 * 24 * 60 * 60;
  const report = evaluatePromotionEvidence(evidence, policy, { now: "2026-07-15T00:02:00.000Z" });
  assert.equal(report.status, "not_ready");
  assert.equal(report.blockers.filter((item) => item.code === "insufficient_coverage").length, 8);
});
