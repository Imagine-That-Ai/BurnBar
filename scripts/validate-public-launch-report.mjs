#!/usr/bin/env node
/**
 * Validate T31 public launch evidence.
 *
 * This report proves the launch was actually opened publicly after canary:
 * public Remote Config, GitHub release, website announcement/deploy, launch
 * comms, live pricing capture, and monitoring dashboard evidence.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import process from "node:process";

const DEFAULT_PUBLIC_LAUNCH_PATH = "launch-evidence/public-launch-report.json";

const REQUIRED_REMOTE_CONFIG = Object.freeze({
  public_paid_launch: "true",
  paid_canary_percent: "100",
  cloud_pro_enabled: "true",
});

const REQUIRED_CHANNELS = Object.freeze([
  "github_release",
  "hacker_news",
  "reddit",
  "indie_hackers",
  "product_hunt",
  "email",
]);

const REQUIRED_EVIDENCE_KINDS = Object.freeze([
  "github-release",
  "website-announcement",
  "website-pricing-capture",
  "monitoring-dashboard",
]);

function usage() {
  return `Usage:
  scripts/validate-public-launch-report.mjs [public-launch-report.json]
  scripts/validate-public-launch-report.mjs --template

Default report path: ${DEFAULT_PUBLIC_LAUNCH_PATH}
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

function includesAll(values, required) {
  const set = new Set(Array.isArray(values) ? values : []);
  return required.every((value) => set.has(value));
}

export function validatePublicLaunchReport(report) {
  const errors = [];
  if (!isRecord(report)) return { ok: false, errors: ["public launch report must be a JSON object"] };
  if (report.schemaVersion !== 1) fail(errors, "schemaVersion must be 1");
  if (report.ok !== true) fail(errors, "ok must be true");
  if (typeof report.generatedAt !== "string" || Number.isNaN(Date.parse(report.generatedAt))) {
    fail(errors, "generatedAt must be an ISO timestamp string");
  }

  const remoteConfig = report.remoteConfig ?? {};
  for (const [key, expected] of Object.entries(REQUIRED_REMOTE_CONFIG)) {
    if (String(remoteConfig[key]) !== expected) fail(errors, `remoteConfig.${key} must be ${expected}`);
  }

  if (!report.githubRelease?.url) fail(errors, "githubRelease.url is required");
  if (!report.githubRelease?.tag) fail(errors, "githubRelease.tag is required");
  if (report.githubRelease?.draft !== false) fail(errors, "githubRelease.draft must be false");
  if (!report.website?.url) fail(errors, "website.url is required");
  if (!report.website?.deployID) fail(errors, "website.deployID is required");
  if (report.website?.pricingHTTPStatus !== 200) fail(errors, "website.pricingHTTPStatus must be 200");
  if (report.website?.legalHTTPStatus !== 200) fail(errors, "website.legalHTTPStatus must be 200");
  if (report.topUpPrepayEnforced !== true) fail(errors, "topUpPrepayEnforced must be true");
  if (report.entitlementGatesVerified !== true) fail(errors, "entitlementGatesVerified must be true");
  if (report.monitoringDashboardsLive !== true) fail(errors, "monitoringDashboardsLive must be true");

  if (!includesAll(report.launchChannelsPosted, REQUIRED_CHANNELS)) {
    fail(errors, `launchChannelsPosted must include ${REQUIRED_CHANNELS.join(", ")}`);
  }

  for (const kind of REQUIRED_EVIDENCE_KINDS) {
    if (!hasEvidenceKind(report.evidence, kind)) fail(errors, `evidence must include ${kind}`);
  }

  return { ok: errors.length === 0, errors };
}

export function templatePublicLaunchReport() {
  return {
    schemaVersion: 1,
    ok: true,
    generatedAt: new Date(0).toISOString(),
    remoteConfig: { ...REQUIRED_REMOTE_CONFIG },
    githubRelease: {
      tag: "v1.0.0",
      url: "https://github.com/Imagine-That-Ai/BurnBar/releases/tag/v1.0.0",
      draft: false,
    },
    website: {
      url: "https://burnbar.ai/pricing",
      deployID: "replace-with-firebase-hosting-release-id",
      pricingHTTPStatus: 200,
      legalHTTPStatus: 200,
    },
    launchChannelsPosted: REQUIRED_CHANNELS,
    topUpPrepayEnforced: true,
    entitlementGatesVerified: true,
    monitoringDashboardsLive: true,
    evidence: [
      { kind: "github-release", path: "launch-evidence/github-release.json" },
      { kind: "website-announcement", path: "launch-evidence/website-announcement.html" },
      { kind: "website-pricing-capture", path: "launch-evidence/public-pricing.html" },
      { kind: "monitoring-dashboard", path: "launch-evidence/public-launch-dashboard.png" },
    ],
  };
}

function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage());
    return 0;
  }
  if (argv.includes("--template")) {
    console.log(JSON.stringify(templatePublicLaunchReport(), null, 2));
    return 0;
  }
  const reportPath = argv[0] || DEFAULT_PUBLIC_LAUNCH_PATH;
  const report = JSON.parse(readFileSync(reportPath, "utf8"));
  const result = validatePublicLaunchReport(report);
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
