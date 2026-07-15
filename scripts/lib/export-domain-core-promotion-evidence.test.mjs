import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { requiredCoverageForDomain } from "./domain-core-evidence-contract.mjs";
import { evaluatePromotionEvidence } from "./domain-core-promotion-evidence.mjs";
import {
  buildDomainCorePromotionEvidence,
  parseStoredDomainCoreShadowSample,
} from "./export-domain-core-promotion-evidence.mjs";

const START = "2026-07-01T00:00:00.000Z";
const END = "2026-07-15T00:00:00.000Z";
const CANDIDATE = "0123456789abcdef0123456789abcdef01234567";
const OTHER_CANDIDATE = "89abcdef0123456789abcdef0123456789abcdef";
const SOURCE_SHA = "a".repeat(64);
const OTHER_SOURCE_SHA = "b".repeat(64);
const DIAGNOSTIC_POLICY = JSON.parse(
  readFileSync(
    new URL("../../config/domain-core-shadow-diagnostic-policy.json", import.meta.url),
    "utf8",
  ),
);

const SLICE_OPERATION = {
  "quota/claude": "claude_quota",
  "quota/codex": "codex_quota",
  "quota/cursor": "cursor_quota",
  "quota/anthropic": "anthropic_quota",
  "cloudvault/foundation": "aad_v2",
  "cloudvault/aes": "aes_gcm_open_combined",
  "cloudvault/recovery": "recovery_open_vault_key",
  "cloudvault/escrow": "escrow_open",
  "cloudvault/document-rewrap": "document_rewrap",
  "cloudvault/search": "token",
  "cloudvault/opaque-identifiers": "project_memory_doc_id",
  "hermes/aad": "aad",
  "hermes/payload-keywrap": "seal",
  "hermes/hpke-info": "hpke_v3_info",
  "hermes/ratchet": "ratchet_open",
  "pricing/token-cost": "calculate_token_cost",
  "pricing/legacy-kimi": "price_legacy_kimi",
};

const CONSUMER_OPERATION = {
  "cloudvault/opaque-identifiers/remote-mcp": "pensieve_dedup_hash",
};

function dayTimestamp(day) {
  return `2026-07-${String(day).padStart(2, "0")}T12:00:00.000Z`;
}

function operation(domain, slice, consumer) {
  const value =
    CONSUMER_OPERATION[`${domain}/${slice}/${consumer}`] ??
    SLICE_OPERATION[`${domain}/${slice}`];
  assert.ok(value, `test operation missing for ${domain}/${slice}`);
  return value;
}

function record(domain, slice, consumer, suffix, overrides = {}) {
  const receivedAt = dayTimestamp(((suffix - 1) % 14) + 1);
  return {
    schemaVersion: 3,
    sampleId: `00000000-0000-4000-8000-${suffix.toString(16).padStart(12, "0")}`,
    domain,
    slice,
    consumer,
    channel: "internal",
    operation: operation(domain, slice, consumer),
    candidateCommit: CANDIDATE,
    expectedCoreVersion: "0.3.0",
    expectedCoreAbiVersion: 3,
    expectedCoreSourceSha256: SOURCE_SHA,
    loadedCoreVersion: "0.3.0",
    loadedCoreAbiVersion: 3,
    loadedCoreSourceSha256: SOURCE_SHA,
    observedAt: receivedAt,
    outcome: "match",
    mismatchCategory: null,
    legacyMicros: 100 + suffix,
    rustMicros: 90 + suffix,
    promotionEligible: true,
    receivedAt,
    expireAt: "2026-09-13T00:00:00.000Z",
    ...overrides,
  };
}

function recordsFor(domain, overrides = {}) {
  let suffix = 1;
  return requiredCoverageForDomain(domain).flatMap(({ slice, consumer }) =>
    Array.from({ length: 14 }, () =>
      record(domain, slice, consumer, suffix++, overrides),
    ),
  );
}

function options(domain, overrides = {}) {
  return {
    domain,
    channel: "internal",
    candidateCommit: CANDIDATE,
    expectedCoreVersion: "0.3.0",
    expectedCoreAbiVersion: 3,
    expectedCoreSourceSha256: SOURCE_SHA,
    startedAt: START,
    endedAt: END,
    generatedAt: "2026-07-15T00:01:00.000Z",
    sourceUri:
      "https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples",
    ...overrides,
  };
}

function diagnosticPolicy() {
  return structuredClone(DIAGNOSTIC_POLICY);
}

test("exporter builds exact candidate-bound V3 evaluator input for every domain", () => {
  for (const domain of ["quota", "cloudvault", "hermes", "pricing"]) {
    const evidence = buildDomainCorePromotionEvidence(
      recordsFor(domain),
      options(domain),
    );
    const report = evaluatePromotionEvidence(evidence, diagnosticPolicy(), {
      now: "2026-07-15T00:02:00.000Z",
    });
    assert.equal(report.status, "diagnostic", domain);
    assert.equal(report.ready, false, domain);
    assert.equal(evidence.candidateCommit, CANDIDATE);
    assert.equal(evidence.expectedCoreSourceSha256, SOURCE_SHA);
    assert.equal(evidence.provenance.candidateCommit, CANDIDATE);
    assert.equal(evidence.provenance.expectedCoreSourceSha256, SOURCE_SHA);
    assert.equal(evidence.windows[0].dailySampleCounts.length, 14);
  }
});

test("mismatches remain unexplained diagnostic alerts", () => {
  const records = recordsFor("pricing");
  records[0] = {
    ...records[0],
    outcome: "mismatch",
    mismatchCategory: "result_mismatch",
  };
  const evidence = buildDomainCorePromotionEvidence(
    records,
    options("pricing"),
  );
  assert.deepEqual(evidence.windows[0].mismatches, [
    { category: "result_mismatch", count: 1, resolution: "unexplained" },
  ]);
  assert.equal(
    evaluatePromotionEvidence(evidence, diagnosticPolicy(), {
      now: "2026-07-15T00:02:00.000Z",
    }).status,
    "diagnostic",
  );
});

test("V1 and V2 records can drain but cannot be exported as promotion evidence", () => {
  const v2 = record("quota", "claude", "apple", 1);
  for (const field of [
    "candidateCommit",
    "expectedCoreVersion",
    "expectedCoreAbiVersion",
    "expectedCoreSourceSha256",
    "loadedCoreVersion",
    "loadedCoreAbiVersion",
    "loadedCoreSourceSha256",
  ]) {
    delete v2[field];
  }
  v2.schemaVersion = 2;
  v2.coreVersion = "0.3.0";
  v2.promotionEligible = false;
  assert.equal(parseStoredDomainCoreShadowSample(v2).schemaVersion, 2);
  assert.throws(
    () => buildDomainCorePromotionEvidence([v2], options("quota")),
    /evidence_schema_v3_required/u,
  );
});

test("exact candidate selection defeats mixed-commit relabeling", () => {
  const records = recordsFor("quota");
  assert.throws(
    () =>
      buildDomainCorePromotionEvidence(
        records,
        options("quota", { candidateCommit: OTHER_CANDIDATE }),
      ),
    /No V3 samples matched the exact candidate tuple/u,
  );
  assert.throws(
    () =>
      buildDomainCorePromotionEvidence(records, {
        ...options("quota"),
        queryRevision: OTHER_CANDIDATE,
      }),
    /invalid field set/u,
  );
});

test("operator CLI rejects the removed relabeling flags before Firebase access", () => {
  for (const flag of ["--query-revision", "--core-version"]) {
    const result = spawnSync(
      process.execPath,
      [
        fileURLToPath(
          new URL(
            "../ops/export-domain-core-promotion-evidence.mjs",
            import.meta.url,
          ),
        ),
        flag,
        CANDIDATE,
      ],
      { encoding: "utf8" },
    );
    assert.equal(result.status, 1, flag);
    assert.match(
      result.stderr,
      new RegExp(`Unknown argument ${flag}`, "u"),
      flag,
    );
  }
});

test("operator CLI validates the exact candidate tuple before Firebase access", () => {
  const cli = fileURLToPath(
    new URL(
      "../ops/export-domain-core-promotion-evidence.mjs",
      import.meta.url,
    ),
  );
  const base = [
    "--project",
    "burnbar",
    "--domain",
    "quota",
    "--start",
    START,
    "--end",
    END,
    "--channel",
    "internal",
    "--candidate-commit",
    CANDIDATE,
    "--expected-core-version",
    "0.3.0",
    "--expected-core-abi-version",
    "3",
    "--expected-core-source-sha256",
    SOURCE_SHA,
    "--source-uri",
    "https://console.cloud.google.com/firestore/databases/-default-/data/panel/domain_core_shadow_samples",
    "--output",
    "/tmp/domain-core-evidence.json",
  ];
  for (const [flag, invalid, message] of [
    ["--candidate-commit", "abc", /full lowercase Git SHA/u],
    ["--expected-core-version", "01.2.3", /available semantic version/u],
    ["--expected-core-abi-version", "0", /unsigned 32-bit integer/u],
    ["--expected-core-source-sha256", "abc", /lowercase SHA-256/u],
    ["--start", "not-a-date", /must be a timestamp/u],
  ]) {
    const args = [...base];
    args[args.indexOf(flag) + 1] = invalid;
    const result = spawnSync(process.execPath, [cli, ...args], {
      encoding: "utf8",
    });
    assert.equal(result.status, 1, flag);
    assert.match(result.stderr, message, flag);
    assert.doesNotMatch(
      result.stderr,
      /credential|firebase|application default/iu,
      flag,
    );
  }
});

test("same semver with a different source fingerprint cannot enter the cohort", () => {
  const exact = recordsFor("hermes");
  const wrong = recordsFor("hermes", {
    expectedCoreSourceSha256: OTHER_SOURCE_SHA,
    loadedCoreSourceSha256: OTHER_SOURCE_SHA,
  }).map((item, index) => ({
    ...item,
    sampleId: `10000000-0000-4000-8000-${(index + 1).toString(16).padStart(12, "0")}`,
  }));
  const evidence = buildDomainCorePromotionEvidence(
    [...exact, ...wrong],
    options("hermes"),
  );
  assert.equal(evidence.windows[0].sampleCount, 14);
  assert.equal(evidence.expectedCoreSourceSha256, SOURCE_SHA);
});

test("every required coverage cell must have a server-received sample on every UTC day", () => {
  const records = recordsFor("cloudvault").filter(
    (item) =>
      !(
        item.slice === "search" &&
        item.consumer === "android" &&
        item.receivedAt.startsWith("2026-07-08")
      ),
  );
  assert.throws(
    () => buildDomainCorePromotionEvidence(records, options("cloudvault")),
    /missing server-received V3 samples for UTC days: 2026-07-08/u,
  );
});

test("client observedAt cannot spoof or exclude server-received coverage", () => {
  const spoofed = recordsFor("pricing").map((item) => ({
    ...item,
    observedAt: "2030-01-01T00:00:00.000Z",
  }));
  assert.doesNotThrow(() =>
    buildDomainCorePromotionEvidence(spoofed, options("pricing")),
  );

  const outsideReceipt = recordsFor("pricing");
  outsideReceipt[0] = {
    ...outsideReceipt[0],
    observedAt: dayTimestamp(1),
    receivedAt: "2026-06-30T23:59:59.999Z",
  };
  assert.throws(
    () => buildDomainCorePromotionEvidence(outsideReceipt, options("pricing")),
    /missing server-received V3 samples for UTC days: 2026-07-01/u,
  );
});

test("unavailable, partial, or mismatched loaded core identities fail closed", () => {
  assert.throws(
    () =>
      buildDomainCorePromotionEvidence(
        recordsFor("quota"),
        options("quota", {
          expectedCoreVersion: "0.0.0-native-unavailable",
        }),
      ),
    /available semantic version/u,
  );
  assert.throws(
    () =>
      buildDomainCorePromotionEvidence(
        recordsFor("quota"),
        options("quota", { expectedCoreAbiVersion: 0x1_0000_0000 }),
      ),
    /unsigned 32-bit integer/u,
  );
  assert.throws(
    () =>
      parseStoredDomainCoreShadowSample(
        record("quota", "claude", "apple", 1, {
          loadedCoreVersion: null,
        }),
      ),
    /partial loaded core identity/u,
  );
  assert.throws(
    () =>
      parseStoredDomainCoreShadowSample(
        record("quota", "claude", "apple", 1, {
          loadedCoreSourceSha256: OTHER_SOURCE_SHA,
        }),
      ),
    /does not match the expected candidate/u,
  );
});

test("candidate core versions use canonical SemVer", () => {
  for (const invalid of ["01.2.3", "1.02.3", "1.2.03", "1.2.3-01"]) {
    assert.throws(
      () =>
        buildDomainCorePromotionEvidence(
          recordsFor("pricing"),
          options("pricing", { expectedCoreVersion: invalid }),
        ),
      /available semantic version/u,
      invalid,
    );
  }
  const canonical = "1.2.3-alpha.1+build.5";
  assert.doesNotThrow(() =>
    buildDomainCorePromotionEvidence(
      recordsFor("pricing", {
        expectedCoreVersion: canonical,
        loadedCoreVersion: canonical,
      }),
      options("pricing", { expectedCoreVersion: canonical }),
    ),
  );
});

test("an explicitly reported loaded identity mismatch is retained as a hard blocker", () => {
  const records = recordsFor("quota");
  records[0] = {
    ...records[0],
    outcome: "mismatch",
    mismatchCategory: "loaded_identity_mismatch",
    loadedCoreSourceSha256: OTHER_SOURCE_SHA,
  };
  const evidence = buildDomainCorePromotionEvidence(records, options("quota"));
  assert.deepEqual(evidence.windows[0].mismatches, [
    {
      category: "loaded_identity_mismatch",
      count: 1,
      resolution: "unexplained",
    },
  ]);
  const report = evaluatePromotionEvidence(evidence, diagnosticPolicy(), {
    now: "2026-07-15T00:02:00.000Z",
  });
  assert.equal(report.status, "diagnostic");
  assert.ok(report.blockers.some((item) => item.code === "hard_mismatches"));

  evidence.windows[0].mismatches[0] = {
    ...evidence.windows[0].mismatches[0],
    resolution: "explained",
    issue: "https://github.com/Imagine-That-Ai/BurnBar/issues/123",
    reviewedBy: "@reviewer",
    approvedAt: "2026-07-14T00:00:00.000Z",
  };
  const explained = evaluatePromotionEvidence(evidence, diagnosticPolicy(), {
    now: "2026-07-15T00:02:00.000Z",
  });
  assert.equal(explained.status, "invalid");
  assert.ok(
    explained.errors.some((item) =>
      item.includes("loaded_identity_mismatch cannot be explained away"),
    ),
  );

  assert.throws(
    () =>
      parseStoredDomainCoreShadowSample(
        record("quota", "claude", "apple", 1, {
          outcome: "mismatch",
          mismatchCategory: "loaded_identity_mismatch",
        }),
      ),
    /requires a different loaded core identity/u,
  );
});

test("operation-to-slice identity is exhaustive and fail closed", () => {
  for (const realProducerOperation of [
    "initialize",
    "expected_session_body_hash_v0",
    "expected_session_body_hash_v1",
  ]) {
    assert.doesNotThrow(() =>
      parseStoredDomainCoreShadowSample(
        record("cloudvault", "foundation", "apple", 9_000, {
          operation: realProducerOperation,
        }),
      ),
    );
  }
  assert.throws(
    () =>
      parseStoredDomainCoreShadowSample(
        record("cloudvault", "aes", "apple", 1, {
          operation: "aad_v2",
        }),
      ),
    /inconsistent operation, domain, or slice/u,
  );
  assert.throws(
    () =>
      parseStoredDomainCoreShadowSample(
        record("cloudvault", "foundation", "apple", 1, {
          operation: "future_unreviewed_operation",
        }),
      ),
    /inconsistent operation, domain, or slice/u,
  );
});

test("exporter accepts every operation identity declared by the canonical V3 schema", () => {
  const schema = JSON.parse(
    readFileSync(
      new URL(
        "../../docs/contracts/domain-core-shadow-sample-v3.schema.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const operationUnion = schema.allOf.find((entry) =>
    entry.oneOf?.every((variant) => variant.properties?.operation),
  );
  assert.ok(operationUnion);
  let suffix = 10_000;
  for (const variant of operationUnion.oneOf) {
    const properties = variant.properties;
    const domain = properties.domain.const;
    const slice = properties.slice.const;
    const consumer = properties.consumer.const ?? properties.consumer.enum[0];
    const operations = properties.operation.enum ?? [
      properties.operation.const,
    ];
    for (const operationName of operations) {
      assert.doesNotThrow(
        () =>
          parseStoredDomainCoreShadowSample(
            record(domain, slice, consumer, suffix++, {
              operation: operationName,
            }),
          ),
        `${domain}/${slice}/${operationName}`,
      );
    }
  }
});

test("exporter rejects unexpected stored fields and duplicate IDs", () => {
  assert.throws(
    () =>
      parseStoredDomainCoreShadowSample({
        ...record("quota", "claude", "apple", 1),
        uid: "secret",
      }),
    /field set/u,
  );
  const duplicate = record("quota", "claude", "apple", 1);
  assert.throws(
    () =>
      buildDomainCorePromotionEvidence(
        [duplicate, duplicate],
        options("quota"),
      ),
    /duplicate sampleId/u,
  );
});
