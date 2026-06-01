#!/usr/bin/env node
/**
 * Validate the GTM launch evidence bundle before canary, public release, or
 * LAUNCH_DONE.md. This intentionally validates evidence shape; live proof files
 * must come from the store/payment/admin commands themselves.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

const DEFAULT_MANIFEST_PATH = "launch-evidence/final-launch-evidence.json";
const DEFAULT_DONE_PATH = "launch-evidence/LAUNCH_DONE.md";
const STAGES = new Set(["paid-proof", "public-release", "done"]);

const REQUIRED_PAID_PROOFS = {
  apple_cloud: ["apple", "cloud"],
  apple_cloud_pro: ["apple", "cloud-pro"],
  stripe_cloud: ["stripe", "cloud"],
  stripe_cloud_pro: ["stripe", "cloud-pro"],
  google_play_cloud: ["google_play", "cloud"],
  google_play_cloud_pro: ["google_play", "cloud-pro"],
};

const REQUIRED_MATRIX_ROWS = [
  "stripe_cloud_monthly",
  "stripe_cloud_pro_annual",
  "apple_cloud_restore_cancel_refund",
  "apple_cloud_pro_topup",
  "google_play_cloud_restore_cancel_refund",
  "google_play_cloud_pro_topup",
  "legacy_hosted_quota_group_a_only",
  "expired_canceled_fail_closed",
];

const REQUIRED_CANARY_RC = {
  public_paid_launch: "false",
  paid_canary_percent: "10",
  cloud_pro_enabled: "true",
  cloud_pro_monthly_hosted_action_cap: "2000",
};

const REQUIRED_PUBLIC_RC = {
  public_paid_launch: "true",
  paid_canary_percent: "100",
  cloud_pro_enabled: "true",
};

const REQUIRED_REFUND_CASES = [
  "stripe_subscription_deleted",
  "stripe_chargeback",
  "apple_refund_revocation",
  "apple_expiration",
  "google_play_refund_revocation",
  "google_play_expiration",
];

const REQUIRED_DENIED_SURFACES = ["hosted_quota", "remote_mcp", "floo_relay", "hosted_agent_control"];

function usage() {
  return `Usage:
  scripts/validate-launch-evidence-bundle.mjs [manifest.json]
  scripts/validate-launch-evidence-bundle.mjs --stage paid-proof [manifest.json]
  scripts/validate-launch-evidence-bundle.mjs --stage public-release [manifest.json]
  scripts/validate-launch-evidence-bundle.mjs --require-done-stamp [manifest.json]
  scripts/validate-launch-evidence-bundle.mjs --template
`;
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function fail(errors, message) {
  errors.push(message);
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function includesAll(values, required) {
  const set = new Set(asArray(values));
  return required.every((value) => set.has(value));
}

function hasEvidence(items, kind) {
  return asArray(items).some(
    (item) =>
      isRecord(item) &&
      (kind === undefined || item.kind === kind) &&
      typeof item.path === "string" &&
      item.path.length > 0,
  );
}

function resolveEvidencePath(baseDir, evidencePath) {
  if (typeof evidencePath !== "string" || evidencePath.length === 0) return null;
  if (/^https?:\/\//.test(evidencePath)) return evidencePath;
  return isAbsolute(evidencePath) ? evidencePath : join(baseDir, evidencePath);
}

function pathExists(baseDir, evidencePath) {
  const resolved = resolveEvidencePath(baseDir, evidencePath);
  if (!resolved) return false;
  if (/^https?:\/\//.test(resolved)) return true;
  return existsSync(resolved);
}

function readJSONAt(baseDir, evidencePath, errors, label) {
  const resolved = resolveEvidencePath(baseDir, evidencePath);
  if (!resolved || /^https?:\/\//.test(resolved)) {
    fail(errors, `${label}: local JSON path is required`);
    return null;
  }
  try {
    return JSON.parse(readFileSync(resolved, "utf8"));
  } catch (error) {
    fail(errors, `${label}: cannot read JSON (${error.message})`);
    return null;
  }
}

function proofOK(proof) {
  return isRecord(proof) && (proof.ok === true || proof.result?.ok === true || proof.verdict?.ok === true);
}

function validateLaunchGate(manifest, baseDir, errors) {
  if (!isRecord(manifest.launchGate)) return fail(errors, "launchGate must be an object");
  if (!pathExists(baseDir, manifest.launchGate.path)) fail(errors, "launchGate.path must reference an existing artifact");
  const gate = readJSONAt(baseDir, manifest.launchGate.path, errors, "launchGate.path");
  const status = gate?.verdict?.status ?? manifest.launchGate.status;
  if (!["READY_FOR_LIVE_PAID_PROOF", "READY_FOR_CANARY", "READY_FOR_PUBLIC_RELEASE", "LAUNCH_DONE"].includes(status)) {
    fail(errors, "launchGate status must be a launch-ready status");
  }
  if (gate?.checks?.repo?.ok === false) fail(errors, "launchGate repo check is not ok");
}

function validatePaidProofs(manifest, baseDir, errors) {
  const byID = new Map(asArray(manifest.paidProofs).map((proof) => [proof?.id, proof]));
  for (const [id, [channel, tier]] of Object.entries(REQUIRED_PAID_PROOFS)) {
    const proof = byID.get(id);
    if (!isRecord(proof)) {
      fail(errors, `missing paid proof: ${id}`);
      continue;
    }
    if (proof.ok !== true) fail(errors, `${id}: ok must be true`);
    if (proof.channel !== channel) fail(errors, `${id}: channel must be ${channel}`);
    if (proof.tier !== tier) fail(errors, `${id}: tier must be ${tier}`);
    if (!pathExists(baseDir, proof.path)) fail(errors, `${id}: path must reference an existing artifact`);
    const proofJSON = readJSONAt(baseDir, proof.path, errors, `${id}.path`);
    if (proofJSON && !proofOK(proofJSON)) fail(errors, `${id}: proof artifact must contain ok:true`);
  }
}

function validateCrossChannelMatrix(manifest, baseDir, errors) {
  const ref = manifest.crossChannelMatrix;
  if (!isRecord(ref)) return fail(errors, "crossChannelMatrix must be an object");
  if (!pathExists(baseDir, ref.path)) fail(errors, "crossChannelMatrix.path must reference an existing artifact");
  const matrix = readJSONAt(baseDir, ref.path, errors, "crossChannelMatrix.path");
  if (!matrix) return;
  if (matrix.schemaVersion !== 1) fail(errors, "crossChannelMatrix: schemaVersion must be 1");
  if (matrix.security?.clientSelfGrantDenied !== true) {
    fail(errors, "crossChannelMatrix: client self-grant denial evidence is required");
  }
  const rows = new Map(asArray(matrix.rows).map((row) => [row?.id, row]));
  for (const id of REQUIRED_MATRIX_ROWS) {
    const row = rows.get(id);
    if (!row) {
      fail(errors, `crossChannelMatrix: missing row: ${id}`);
      continue;
    }
    if (row.ok !== true) fail(errors, `crossChannelMatrix: ${id}: ok must be true`);
    if (!hasEvidence(row.evidence)) fail(errors, `crossChannelMatrix: ${id}: evidence must include {kind,path}`);
  }
}

function validateCanary(manifest, baseDir, errors) {
  const canary = manifest.canary;
  if (!isRecord(canary)) return fail(errors, "canary must be an object");
  if (canary.ok !== true) fail(errors, "canary.ok must be true");
  if (!pathExists(baseDir, canary.path)) fail(errors, "canary.path must reference an existing artifact");
  const report = readJSONAt(baseDir, canary.path, errors, "canary.path");
  if (!report) return;
  if (report.ok !== true) fail(errors, "canary: ok must be true");
  if ((report.hoursObserved ?? 0) < 72 && (report.paidUsersObserved ?? 0) < 25) {
    fail(errors, "canary: must observe at least 72 hours or 25 paid users");
  }
  if (report.noOpenP0P1 !== true) fail(errors, "canary: noOpenP0P1 must be true");
  if ((report.cloudGrossMarginPercent ?? 0) < 80) fail(errors, "canary: cloudGrossMarginPercent must be >= 80");
  if ((report.cloudProGrossMarginPercent ?? 0) < 50) fail(errors, "canary: cloudProGrossMarginPercent must be >= 50");
  if ((report.appCheckDeniedPercent ?? 1) >= 1) fail(errors, "canary: appCheckDeniedPercent must be < 1");
  if ((report.entitlementFailurePercent ?? 0.5) >= 0.5) fail(errors, "canary: entitlementFailurePercent must be < 0.5");
  if ((report.mediaProjectedSpendUSD ?? Infinity) > 600) fail(errors, "canary: mediaProjectedSpendUSD must be <= 600");
  if ((report.computerUseProjectedSpendUSD ?? Infinity) > 1500) {
    fail(errors, "canary: computerUseProjectedSpendUSD must be <= 1500");
  }
  for (const [key, expected] of Object.entries(REQUIRED_CANARY_RC)) {
    if (String(report.remoteConfig?.[key]) !== expected) fail(errors, `canary: remoteConfig.${key} must be ${expected}`);
  }
  for (const kind of ["dashboard", "cogs-report", "incident-log"]) {
    if (!hasEvidence(report.evidence, kind)) fail(errors, `canary: evidence must include ${kind}`);
  }
}

function validatePublicLaunch(manifest, baseDir, errors) {
  const ref = manifest.release?.publicLaunchReport;
  if (!ref?.path) return fail(errors, "release.publicLaunchReport.path is required");
  if (!pathExists(baseDir, ref.path)) fail(errors, "release.publicLaunchReport.path must reference an existing artifact");
  const report = readJSONAt(baseDir, ref.path, errors, "release.publicLaunchReport.path");
  if (!report) return;
  if (report.ok !== true) fail(errors, "release.publicLaunchReport: ok must be true");
  for (const [key, expected] of Object.entries(REQUIRED_PUBLIC_RC)) {
    if (String(report.remoteConfig?.[key]) !== expected) {
      fail(errors, `release.publicLaunchReport: remoteConfig.${key} must be ${expected}`);
    }
  }
  if (report.githubRelease?.draft !== false || !report.githubRelease?.url) {
    fail(errors, "release.publicLaunchReport: published GitHub release is required");
  }
  if (report.website?.pricingHTTPStatus !== 200 || report.website?.legalHTTPStatus !== 200 || !report.website?.deployID) {
    fail(errors, "release.publicLaunchReport: website deploy plus pricing/legal HTTP 200 are required");
  }
  if (!includesAll(report.launchChannelsPosted, ["github_release", "hacker_news", "reddit", "indie_hackers", "product_hunt", "email"])) {
    fail(errors, "release.publicLaunchReport: all launch channels must be posted");
  }
  if (report.topUpPrepayEnforced !== true) fail(errors, "release.publicLaunchReport: topUpPrepayEnforced must be true");
  if (report.entitlementGatesVerified !== true) fail(errors, "release.publicLaunchReport: entitlementGatesVerified must be true");
  if (report.monitoringDashboardsLive !== true) fail(errors, "release.publicLaunchReport: monitoringDashboardsLive must be true");
}

function validateRefundAbuse(manifest, baseDir, errors) {
  const ref = manifest.refundAbuseReport;
  if (!isRecord(ref)) return fail(errors, "refundAbuseReport must be an object");
  if (ref.ok !== true) fail(errors, "refundAbuseReport.ok must be true");
  if (!pathExists(baseDir, ref.path)) fail(errors, "refundAbuseReport.path must reference an existing artifact");
  const report = readJSONAt(baseDir, ref.path, errors, "refundAbuseReport.path");
  if (!report) return;
  if (report.ok !== true) fail(errors, "refundAbuseReport: ok must be true");
  if (!includesAll(report.refundCasesCovered, REQUIRED_REFUND_CASES)) {
    fail(errors, `refundAbuseReport: refundCasesCovered must include ${REQUIRED_REFUND_CASES.join(", ")}`);
  }
  if (report.entitlementRemovedWithinReconciliationWindow !== true) {
    fail(errors, "refundAbuseReport: entitlementRemovedWithinReconciliationWindow must be true");
  }
  if (report.revocationAuditEventPresent !== true) fail(errors, "refundAbuseReport: revocationAuditEventPresent must be true");
  if (report.topUpConsumedNonRefundableDocumented !== true) {
    fail(errors, "refundAbuseReport: topUpConsumedNonRefundableDocumented must be true");
  }
  if (report.abuseOverridePath !== "users/{uid}/ops/suspensions/cloudFeatures") {
    fail(errors, "refundAbuseReport: abuseOverridePath must be users/{uid}/ops/suspensions/cloudFeatures");
  }
  if (String(report.userQuotaDailyRefreshLimit) !== "5") fail(errors, "refundAbuseReport: userQuotaDailyRefreshLimit must be 5");
  if (report.remoteMcpGrantsRevoked !== true) fail(errors, "refundAbuseReport: remoteMcpGrantsRevoked must be true");
  if (!includesAll(report.suspendedUserDeniedSurfaces, REQUIRED_DENIED_SURFACES)) {
    fail(errors, `refundAbuseReport: suspendedUserDeniedSurfaces must include ${REQUIRED_DENIED_SURFACES.join(", ")}`);
  }
  if (!hasEvidence(report.evidence)) fail(errors, "refundAbuseReport: evidence must include at least one {kind,path}");
}

function validateRollback(manifest, baseDir, errors) {
  const rollback = manifest.rollbackDrill;
  if (!isRecord(rollback)) return fail(errors, "rollbackDrill must be an object");
  if (rollback.ok !== true) fail(errors, "rollbackDrill.ok must be true");
  if (!pathExists(baseDir, rollback.path)) fail(errors, "rollbackDrill.path must reference an existing artifact");
  const drill = readJSONAt(baseDir, rollback.path, errors, "rollbackDrill.path");
  if (!drill) return;
  if (drill.ok !== true) fail(errors, "rollbackDrill: ok must be true");
  for (const field of ["remote_config_kill_switch_patch", "hosting_release_list", "functions_build", "cloud_run_revision_list", "commercial_launch_gate", "ops_readiness", "stripe_console_access", "apple_console_access", "google_play_console_access"]) {
    if (!includesAll(drill.controlsCovered, [field])) fail(errors, `rollbackDrill: controlsCovered must include ${field}`);
  }
  if (drill.remoteConfigPublished !== false) fail(errors, "rollbackDrill: remoteConfigPublished must be false");
  if (drill.killSwitchHaltVerified !== true) fail(errors, "rollbackDrill: killSwitchHaltVerified must be true");
  if (drill.onCallCanExecute !== true) fail(errors, "rollbackDrill: onCallCanExecute must be true");
}

function validateReleaseIDs(manifest, errors) {
  const release = manifest.release;
  if (!isRecord(release)) return fail(errors, "release must be an object");
  if (!release.ios?.appVersionID) fail(errors, "release.ios.appVersionID is required");
  if (!release.ios?.buildNumber) fail(errors, "release.ios.buildNumber is required");
  if (!release.stripe?.livemode) fail(errors, "release.stripe.livemode must be true");
  if (!release.stripe?.cloudPriceID) fail(errors, "release.stripe.cloudPriceID is required");
  if (!release.stripe?.cloudProPriceID) fail(errors, "release.stripe.cloudProPriceID is required");
  if (!release.googlePlay?.track) fail(errors, "release.googlePlay.track is required");
  if (!release.website?.url) fail(errors, "release.website.url is required");
  if (!release.website?.deployID) fail(errors, "release.website.deployID is required");
}

function validateDoneStamp(manifest, manifestPath, donePath, errors) {
  if (!existsSync(donePath)) return fail(errors, `${relative(process.cwd(), donePath)} is required`);
  const done = readFileSync(donePath, "utf8");
  const requiredRefs = [
    manifest.launchGate?.path,
    manifest.crossChannelMatrix?.path,
    manifest.canary?.path,
    manifest.rollbackDrill?.path,
    manifest.refundAbuseReport?.path,
    manifest.release?.publicLaunchReport?.path,
    ...asArray(manifest.paidProofs).map((proof) => proof?.path),
    relative(dirname(donePath), manifestPath),
  ].filter(Boolean);
  for (const evidencePath of requiredRefs) {
    const basename = evidencePath.split("/").pop();
    if (!done.includes(evidencePath) && !done.includes(basename)) fail(errors, `LAUNCH_DONE.md must reference ${evidencePath}`);
  }
}

export function validateLaunchEvidenceBundle(manifest, options = {}) {
  const errors = [];
  const stage = options.stage ?? "done";
  if (!STAGES.has(stage)) return { ok: false, errors: [`unknown launch evidence stage: ${stage}`] };
  if (!isRecord(manifest)) return { ok: false, errors: ["manifest must be a JSON object"] };
  if (manifest.schemaVersion !== 1) fail(errors, "schemaVersion must be 1");
  if (typeof manifest.generatedAt !== "string" || Number.isNaN(Date.parse(manifest.generatedAt))) {
    fail(errors, "generatedAt must be an ISO timestamp string");
  }
  const manifestPath = options.manifestPath ?? DEFAULT_MANIFEST_PATH;
  const baseDir = dirname(manifestPath);
  validateLaunchGate(manifest, baseDir, errors);
  validatePaidProofs(manifest, baseDir, errors);
  validateCrossChannelMatrix(manifest, baseDir, errors);
  if (stage === "public-release" || stage === "done") validateCanary(manifest, baseDir, errors);
  if (stage === "done") {
    validatePublicLaunch(manifest, baseDir, errors);
    validateRefundAbuse(manifest, baseDir, errors);
    validateRollback(manifest, baseDir, errors);
    validateReleaseIDs(manifest, errors);
  }
  if (options.requireDoneStamp === true) validateDoneStamp(manifest, manifestPath, options.donePath ?? DEFAULT_DONE_PATH, errors);
  return { ok: errors.length === 0, errors };
}

export function templateLaunchEvidenceBundle() {
  return {
    schemaVersion: 1,
    generatedAt: new Date(0).toISOString(),
    launchGate: { path: "latest-commercial-launch-gate.json" },
    paidProofs: Object.entries(REQUIRED_PAID_PROOFS).map(([id, [channel, tier]]) => ({
      id,
      ok: true,
      channel,
      tier,
      path: `paid-proof-${id}.json`,
    })),
    crossChannelMatrix: { path: "cross-channel-paid-path-matrix.json" },
    canary: { ok: true, path: "canary-report.json" },
    release: {
      ios: { appVersionID: "replace-with-app-store-version-id", buildNumber: "replace-with-build-number" },
      stripe: { livemode: true, cloudPriceID: "replace-with-live-cloud-price-id", cloudProPriceID: "replace-with-live-cloud-pro-price-id" },
      googlePlay: { track: "production" },
      website: { url: "https://burnbar.ai/pricing", deployID: "replace-with-deploy-id" },
      publicLaunchReport: { path: "public-launch-report.json" },
    },
    refundAbuseReport: { ok: true, path: "refund-abuse-report.json" },
    rollbackDrill: { ok: true, path: "rollback-drill.json" },
  };
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage());
    return 0;
  }
  if (argv.includes("--template")) {
    console.log(JSON.stringify(templateLaunchEvidenceBundle(), null, 2));
    return 0;
  }
  const requireDoneStamp = argv.includes("--require-done-stamp");
  const stageIndex = argv.indexOf("--stage");
  const stage = stageIndex >= 0 ? argv[stageIndex + 1] : "done";
  const positional = argv.filter((arg, index) => !arg.startsWith("-") && (stageIndex < 0 || index !== stageIndex + 1));
  const manifestPath = positional[0] ?? DEFAULT_MANIFEST_PATH;
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  } catch (error) {
    console.error(JSON.stringify({ ok: false, errors: [`${manifestPath}: cannot read JSON (${error.message})`] }, null, 2));
    return 1;
  }
  const result = validateLaunchEvidenceBundle(manifest, { manifestPath, stage, requireDoneStamp });
  if (!result.ok) {
    console.error(JSON.stringify(result, null, 2));
    return 1;
  }
  console.log(JSON.stringify({ ok: true, path: manifestPath, stage, requireDoneStamp }, null, 2));
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exitCode = await main(process.argv.slice(2));
}
