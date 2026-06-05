// Tests for the confidentiality guard's pure classification core.
// Run: node --test scripts/security/__tests__/scan-internal-content.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  classify,
  scan,
  isAllowlisted,
  matchPathRule,
  shouldContentScan,
  hasSelfDeclaredMarker,
} from "../scan-internal-content.mjs";

const noContent = () => null;
const withContent = (text) => () => text;

test("blocks pricing / COGS / financials", () => {
  for (const p of [
    "docs/pricing/4_cost_of_goods_sold_cogs_model.md",
    "docs/pricing/gpt-pro-brief/04_UNIT_ECONOMICS_AND_COGS.md",
    "docs/pricing/5_pricing_strategy_and_recommendations.md",
  ]) {
    const v = classify(p, noContent);
    assert.ok(v, `${p} should be flagged`);
    assert.equal(v.severity, "block");
    assert.equal(v.ruleId, "pricing-financials");
  }
});

test("blocks GTM master plan (case + separator variants)", () => {
  for (const p of ["GTMMasterPlan.MD", "docs/GTM-Master-Plan-v2.md"]) {
    const v = classify(p, noContent);
    assert.ok(v, `${p} should be flagged`);
    assert.equal(v.severity, "block");
    assert.equal(v.ruleId, "gtm-strategy");
  }
});

test("blocks open-vuln working notes and remediation/audit docs", () => {
  for (const p of [
    ".agent/runs/privacy-leak-remediation-2026-06-02/evidence/recon-gateway-architecture.md",
    ".agent/runs/hermes-gateway-e2ee-remediation-20260603/GOAL.md",
    "docs/pensieve-leakage-analysis.md",
    "docs/searchable-index-leakage.md",
    "docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md",
    "docs/SOTA_REMEDIATION_PLAN.md",
    "docs/security/DETECTION_MATRIX.md",
    "OpenBurnBar SOTA Remediation Plan.md",
    "plans/2026-06-01-sota-10-10-security-remediation.md",
    "docs/plans/HOSTED_REMOTE_MCP_WAVE8_AUDIT_REPORT.md",
  ]) {
    const v = classify(p, noContent);
    assert.ok(v, `${p} should be flagged`);
    assert.equal(v.severity, "block", `${p} should block`);
    assert.equal(v.ruleId, "open-vuln-working-notes");
  }
});

test("blocks agent working memory (.agent/runs, .factory/goals)", () => {
  for (const p of [
    ".agent/runs/signalification-phases-3to8-20260604/implementation-notes.html",
    ".agent/runs/pensieve-mnemo-2026-06-02/GOAL.md",
    ".factory/goals/insights-2.0-implementation.md",
  ]) {
    const v = classify(p, noContent);
    assert.ok(v, `${p} should be flagged`);
    assert.equal(v.severity, "block");
    assert.equal(v.ruleId, "agent-working-memory");
  }
});

test("allowlist wins over internal rules and over self-declared banner", () => {
  // Threat models / privacy / security policy stay public.
  for (const p of [
    "docs/THREAT_MODEL.md",
    "docs/REMOTE_MCP_THREAT_MODEL.md",
    "docs/PRIVACY.md",
    ".github/SECURITY.md",
    "docs/signalification/SIGNAL_ENVELOPE_V1.md",
  ]) {
    assert.equal(isAllowlisted(p), true, `${p} should be allowlisted`);
    assert.equal(classify(p, noContent), null, `${p} should not be flagged`);
  }
  // Even a banner inside an allowlisted file does not flag it.
  assert.equal(
    classify("docs/PRIVACY.md", withContent("BurnBar-Confidential: internal")),
    null,
  );
});

test("self-declared banner blocks any non-exempt path", () => {
  const banners = [
    "BurnBar-Confidential: internal",
    "<!-- burnbar:confidential -->",
    "CONFIDENTIAL — DO NOT PUBLISH",
    "INTERNAL ONLY — NOT FOR PUBLIC RELEASE",
  ];
  for (const banner of banners) {
    const v = classify("docs/some-new-note.md", withContent(`# Note\n${banner}\n`));
    assert.ok(v, `banner "${banner}" should flag`);
    assert.equal(v.severity, "block");
    assert.equal(v.ruleId, "self-declared");
    assert.equal(v.matchedOn, "content");
  }
});

test("the guard's own files are exempt from the content scan", () => {
  // These literally contain the markers as examples; must not self-flag.
  for (const p of [
    "scripts/security/internal-content-policy.mjs",
    "scripts/security/scan-internal-content.mjs",
    "docs/security/CONFIDENTIALITY_POLICY.md",
    ".github/workflows/confidentiality-guard.yml", // CI file mentions the marker
    ".pre-commit-config.yaml",
  ]) {
    assert.equal(shouldContentScan(p), false, `${p} should be content-exempt`);
    assert.equal(
      classify(p, withContent("BurnBar-Confidential: internal")),
      null,
    );
  }
});

test("does NOT flag legitimately public files (no false positives)", () => {
  for (const p of [
    "README.md",
    "AGENTS.md",
    "AgentLens/Services/ModelPricing.swift", // code that mentions 'pricing'
    "website/src/data/capabilities.ts",
    "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AgentTier.swift",
    "docs/architecture/region-strategy.md",
    ".deepsec/data/BurnBar/INFO.md",
  ]) {
    assert.equal(classify(p, noContent), null, `${p} should be clean`);
  }
});

test("binary / lockfile paths are not content-scanned", () => {
  for (const p of [
    "AgentLens/Resources/Assets.xcassets/CloudTierCrest.imageset/crest.png",
    "functions/package-lock.json",
    "OpenBurnBarCore/Package.resolved",
  ]) {
    assert.equal(shouldContentScan(p), false);
  }
});

test("hasSelfDeclaredMarker matches all marker variants and ignores benign text", () => {
  assert.equal(hasSelfDeclaredMarker("nothing to see here"), false);
  assert.equal(hasSelfDeclaredMarker("we discuss confidential data handling"), false);
  assert.equal(hasSelfDeclaredMarker("burnbar-confidential: INTERNAL"), true);
});

test("matchPathRule returns first matching rule or null", () => {
  assert.equal(matchPathRule("docs/pricing/x.md").id, "pricing-financials");
  assert.equal(matchPathRule("src/main.ts"), null);
});

test("scan() aggregates blocking vs warnings (severity field is honored)", () => {
  const files = [
    "docs/pricing/4_cogs.md", // block (pricing)
    "GTMMasterPlan.MD", // block (gtm)
    ".agent/runs/signalification/notes.html", // block (agent-working-memory)
    "README.md", // clean
  ];
  const res = scan(files, noContent);
  assert.equal(res.violations.length, 3);
  assert.equal(res.blocking.length, 3);
  assert.equal(res.warnings.length, 0);
  // The warn code path still exists for future rules even though none are warn now.
  assert.ok(Array.isArray(res.warnings));
});
