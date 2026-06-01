#!/usr/bin/env node
/**
 * Validate T32 refund, chargeback, cancellation, and abuse-handling evidence.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import process from "node:process";

const DEFAULT_REPORT_PATH = "launch-evidence/refund-abuse-report.json";

const REQUIRED_REFUND_CASES = Object.freeze([
  "stripe_subscription_deleted",
  "stripe_chargeback",
  "apple_refund_revocation",
  "apple_expiration",
  "google_play_refund_revocation",
  "google_play_expiration",
]);

const REQUIRED_DENIED_SURFACES = Object.freeze([
  "hosted_quota",
  "remote_mcp",
  "floo_relay",
  "hosted_agent_control",
]);

const REQUIRED_SUPPORT_MACROS = Object.freeze([
  "refund",
  "chargeback",
  "cancellation",
  "top-up-exhausted",
  "grandfathered-subscriber",
]);

function usage() {
  return `Usage:
  scripts/validate-refund-abuse-report.mjs [refund-abuse-report.json]
  scripts/validate-refund-abuse-report.mjs --template

Default report path: ${DEFAULT_REPORT_PATH}
`;
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function fail(errors, message) {
  errors.push(message);
}

function includesAll(values, required) {
  const set = new Set(Array.isArray(values) ? values : []);
  return required.every((value) => set.has(value));
}

function hasEvidence(value) {
  return (
    Array.isArray(value) &&
    value.some(
      (item) =>
        isRecord(item) &&
        typeof item.kind === "string" &&
        typeof item.path === "string" &&
        item.path.length > 0,
    )
  );
}

export function validateRefundAbuseReport(report) {
  const errors = [];
  if (!isRecord(report)) return { ok: false, errors: ["refund abuse report must be a JSON object"] };
  if (report.schemaVersion !== 1) fail(errors, "schemaVersion must be 1");
  if (report.ok !== true) fail(errors, "ok must be true");
  if (typeof report.generatedAt !== "string" || Number.isNaN(Date.parse(report.generatedAt))) {
    fail(errors, "generatedAt must be an ISO timestamp string");
  }

  if (!includesAll(report.refundCasesCovered, REQUIRED_REFUND_CASES)) {
    fail(errors, `refundCasesCovered must include ${REQUIRED_REFUND_CASES.join(", ")}`);
  }
  if (!includesAll(report.suspendedUserDeniedSurfaces, REQUIRED_DENIED_SURFACES)) {
    fail(errors, `suspendedUserDeniedSurfaces must include ${REQUIRED_DENIED_SURFACES.join(", ")}`);
  }
  if (!includesAll(report.supportMacrosCovered, REQUIRED_SUPPORT_MACROS)) {
    fail(errors, `supportMacrosCovered must include ${REQUIRED_SUPPORT_MACROS.join(", ")}`);
  }

  if (report.entitlementRemovedWithinReconciliationWindow !== true) {
    fail(errors, "entitlementRemovedWithinReconciliationWindow must be true");
  }
  if (report.revocationAuditEventPresent !== true) {
    fail(errors, "revocationAuditEventPresent must be true");
  }
  if (report.topUpConsumedNonRefundableDocumented !== true) {
    fail(errors, "topUpConsumedNonRefundableDocumented must be true");
  }
  if (report.abuseOverridePath !== "users/{uid}/ops/suspensions/cloudFeatures") {
    fail(errors, "abuseOverridePath must be users/{uid}/ops/suspensions/cloudFeatures");
  }
  if (String(report.userQuotaDailyRefreshLimit) !== "5") {
    fail(errors, "userQuotaDailyRefreshLimit must be 5");
  }
  if (report.remoteMcpGrantsRevoked !== true) {
    fail(errors, "remoteMcpGrantsRevoked must be true");
  }
  if (!hasEvidence(report.evidence)) {
    fail(errors, "evidence must include at least one {kind,path}");
  }

  return { ok: errors.length === 0, errors };
}

export function templateRefundAbuseReport() {
  return {
    schemaVersion: 1,
    ok: true,
    generatedAt: new Date(0).toISOString(),
    refundCasesCovered: REQUIRED_REFUND_CASES,
    entitlementRemovedWithinReconciliationWindow: true,
    revocationAuditEventPresent: true,
    topUpConsumedNonRefundableDocumented: true,
    supportMacrosCovered: REQUIRED_SUPPORT_MACROS,
    abuseOverridePath: "users/{uid}/ops/suspensions/cloudFeatures",
    userQuotaDailyRefreshLimit: "5",
    remoteMcpGrantsRevoked: true,
    suspendedUserDeniedSurfaces: REQUIRED_DENIED_SURFACES,
    evidence: [
      { kind: "refund-reconciliation", path: "launch-evidence/refund-reconciliation.json" },
      { kind: "abuse-denial", path: "launch-evidence/abuse-denial.json" },
      { kind: "support-macros", path: "website/src/data/supportMacros.ts" },
    ],
  };
}

function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage());
    return 0;
  }
  if (argv.includes("--template")) {
    console.log(JSON.stringify(templateRefundAbuseReport(), null, 2));
    return 0;
  }
  const reportPath = argv[0] || DEFAULT_REPORT_PATH;
  const report = JSON.parse(readFileSync(reportPath, "utf8"));
  const result = validateRefundAbuseReport(report);
  if (!result.ok) {
    console.error(JSON.stringify(result, null, 2));
    return 1;
  }
  console.log(JSON.stringify({ ok: true, path: reportPath }, null, 2));
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exitCode = main(process.argv.slice(2));
}
