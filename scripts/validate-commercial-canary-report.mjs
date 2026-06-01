#!/usr/bin/env node
/**
 * Validate T30 commercial canary evidence.
 *
 * The canary report proves the monitored public-launch window, not just that a
 * screenshot exists. Thresholds come from GTMMasterPlan.MD T30.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import process from "node:process";

const DEFAULT_CANARY_PATH = "launch-evidence/canary-report.json";

const REQUIRED_REMOTE_CONFIG = Object.freeze({
  public_paid_launch: "false",
  paid_canary_percent: "10",
  cloud_pro_enabled: "true",
  cloud_pro_monthly_hosted_action_cap: "2000",
});

const REQUIRED_EVIDENCE_KINDS = Object.freeze(["dashboard", "cogs-report", "incident-log"]);

function usage() {
  return `Usage:
  scripts/validate-commercial-canary-report.mjs [canary-report.json]
  scripts/validate-commercial-canary-report.mjs --template

Default canary path: ${DEFAULT_CANARY_PATH}
`;
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function fail(errors, message) {
  errors.push(message);
}

function hasEvidenceKind(evidence, kind) {
  return (
    Array.isArray(evidence) &&
    evidence.some(
      (item) =>
        isRecord(item) &&
        item.kind === kind &&
        typeof item.path === "string" &&
        item.path.length > 0,
    )
  );
}

function numberAtMost(value, threshold) {
  return typeof value === "number" && Number.isFinite(value) && value <= threshold;
}

function numberLessThan(value, threshold) {
  return typeof value === "number" && Number.isFinite(value) && value < threshold;
}

function numberAtLeast(value, threshold) {
  return typeof value === "number" && Number.isFinite(value) && value >= threshold;
}

export function validateCommercialCanaryReport(report) {
  const errors = [];
  if (!isRecord(report)) return { ok: false, errors: ["canary report must be a JSON object"] };
  if (report.schemaVersion !== 1) fail(errors, "schemaVersion must be 1");
  if (report.ok !== true) fail(errors, "ok must be true");
  if (typeof report.generatedAt !== "string" || Number.isNaN(Date.parse(report.generatedAt))) {
    fail(errors, "generatedAt must be an ISO timestamp string");
  }

  if ((report.hoursObserved ?? 0) < 72 && (report.paidUsersObserved ?? 0) < 25) {
    fail(errors, "canary must observe at least 72 hours or 25 paid users");
  }
  if (report.noOpenP0P1 !== true) fail(errors, "noOpenP0P1 must be true");
  if (!numberAtLeast(report.cloudGrossMarginPercent, 80)) {
    fail(errors, "cloudGrossMarginPercent must be >= 80");
  }
  if (!numberAtLeast(report.cloudProGrossMarginPercent, 50)) {
    fail(errors, "cloudProGrossMarginPercent must be >= 50");
  }
  if (!numberLessThan(report.appCheckDeniedPercent, 1)) {
    fail(errors, "appCheckDeniedPercent must be < 1");
  }
  if (!numberLessThan(report.entitlementFailurePercent, 0.5)) {
    fail(errors, "entitlementFailurePercent must be < 0.5");
  }
  if (!numberAtMost(report.mediaProjectedSpendUSD, 600)) {
    fail(errors, "mediaProjectedSpendUSD must be <= 600");
  }
  if (!numberAtMost(report.computerUseProjectedSpendUSD, 1500)) {
    fail(errors, "computerUseProjectedSpendUSD must be <= 1500");
  }

  const remoteConfig = report.remoteConfig ?? {};
  for (const [key, expected] of Object.entries(REQUIRED_REMOTE_CONFIG)) {
    if (String(remoteConfig[key]) !== expected) fail(errors, `remoteConfig.${key} must be ${expected}`);
  }

  for (const kind of REQUIRED_EVIDENCE_KINDS) {
    if (!hasEvidenceKind(report.evidence, kind)) fail(errors, `evidence must include ${kind}`);
  }

  return { ok: errors.length === 0, errors };
}

export function templateCommercialCanaryReport() {
  return {
    schemaVersion: 1,
    ok: true,
    generatedAt: new Date(0).toISOString(),
    hoursObserved: 72,
    paidUsersObserved: 25,
    noOpenP0P1: true,
    cloudGrossMarginPercent: 80,
    cloudProGrossMarginPercent: 50,
    appCheckDeniedPercent: 0,
    entitlementFailurePercent: 0,
    mediaProjectedSpendUSD: 0,
    computerUseProjectedSpendUSD: 0,
    remoteConfig: REQUIRED_REMOTE_CONFIG,
    evidence: [
      { kind: "dashboard", path: "launch-evidence/canary-dashboard.png" },
      { kind: "cogs-report", path: "launch-evidence/canary-cogs-report.json" },
      { kind: "incident-log", path: "launch-evidence/canary-incident-log.md" },
    ],
  };
}

function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage());
    return 0;
  }
  if (argv.includes("--template")) {
    console.log(JSON.stringify(templateCommercialCanaryReport(), null, 2));
    return 0;
  }
  const reportPath = argv[0] || DEFAULT_CANARY_PATH;
  const report = JSON.parse(readFileSync(reportPath, "utf8"));
  const result = validateCommercialCanaryReport(report);
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
