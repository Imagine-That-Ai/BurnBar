#!/usr/bin/env node
/**
 * Validate the final GTM launch evidence bundle before stamping LAUNCH_DONE.md.
 *
 * This is intentionally evidence-shape validation. The live proof files must be
 * produced by the payment/store/prod verification commands themselves.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";
import { validateCommercialCanaryReport } from "./validate-commercial-canary-report.mjs";
import { validateCommercialRollbackDrill } from "./validate-commercial-rollback-drill.mjs";
import { validateCrossChannelPaidPathMatrix } from "./validate-cross-channel-paid-path-matrix.mjs";
import { validatePublicLaunchReport } from "./validate-public-launch-report.mjs";

const DEFAULT_MANIFEST_PATH = "launch-evidence/final-launch-evidence.json";
const DEFAULT_DONE_PATH = "launch-evidence/LAUNCH_DONE.md";
const STAGES = new Set(["paid-proof", "public-release", "done"]);

const ACCEPTED_GATE_STATUSES = new Set([
  "READY_FOR_LIVE_PAID_PROOF",
  "READY_FOR_CANARY",
  "READY_FOR_PUBLIC_RELEASE",
  "LAUNCH_DONE",
]);

const REQUIRED_PAID_PROOFS = Object.freeze({
  apple_cloud: { channel: "apple", tier: "cloud" },
  apple_cloud_pro: { channel: "apple", tier: "cloud-pro" },
  stripe_cloud: { channel: "stripe", tier: "cloud" },
  stripe_cloud_pro: { channel: "stripe", tier: "cloud-pro" },
  google_play_cloud: { channel: "google_play", tier: "cloud" },
  google_play_cloud_pro: { channel: "google_play", tier: "cloud-pro" },
});

function usage() {
  return `Usage:
  scripts/validate-launch-evidence-bundle.mjs [manifest.json]
  scripts/validate-launch-evidence-bundle.mjs --stage paid-proof [manifest.json]
  scripts/validate-launch-evidence-bundle.mjs --stage public-release [manifest.json]
  scripts/validate-launch-evidence-bundle.mjs --require-done-stamp [manifest.json]
  scripts/validate-launch-evidence-bundle.mjs --template

Default manifest path: ${DEFAULT_MANIFEST_PATH}
Default done stamp path: ${DEFAULT_DONE_PATH}
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

function resolveEvidencePath(baseDir, evidencePath) {
  if (typeof evidencePath !== "string" || evidencePath.length === 0) return null;
  if (/^https?:\/\//.test(evidencePath)) return evidencePath;
  return isAbsolute(evidencePath) ? evidencePath : join(baseDir, evidencePath);
}

function pathExists(baseDir, evidencePath) {
  const resolved = resolveEvidencePath(baseDir, evidencePath);
  return typeof resolved === "string" && /^https?:\/\//.test(resolved) ? true : existsSync(resolved);
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
  if (!isRecord(proof)) return false;
  return proof.ok === true || proof.result?.ok === true || proof.verdict?.ok === true;
}

function validateLaunchGate(manifest, baseDir, errors) {
  const gate = manifest.launchGate;
  if (!isRecord(gate)) {
    fail(errors, "launchGate must be an object");
    return;
  }
  if (!pathExists(baseDir, gate.path)) fail(errors, "launchGate.path must reference an existing artifact");
  const gateJSON = readJSONAt(baseDir, gate.path, errors, "launchGate.path");
  const status = gateJSON?.verdict?.status ?? gate.status;
  if (!ACCEPTED_GATE_STATUSES.has(status)) {
    fail(errors, `launchGate status must be one of ${Array.from(ACCEPTED_GATE_STATUSES).join(", ")}`);
  }
  if (gateJSON?.checks?.repo?.ok === false) fail(errors, "launchGate repo check is not ok");
}

function validatePaidProofs(manifest, baseDir, errors) {
  const paidProofs = asArray(manifest.paidProofs);
  const byID = new Map(paidProofs.map((proof) => [proof?.id, proof]));
  for (const [id, spec] of Object.entries(REQUIRED_PAID_PROOFS)) {
    const proof = byID.get(id);
    if (!isRecord(proof)) {
      fail(errors, `missing paid proof: ${id}`);
      continue;
    }
    if (proof.ok !== true) fail(errors, `${id}: ok must be true`);
    if (proof.channel !== spec.channel) fail(errors, `${id}: channel must be ${spec.channel}`);
    if (proof.tier !== spec.tier) fail(errors, `${id}: tier must be ${spec.tier}`);
    if (!pathExists(baseDir, proof.path)) fail(errors, `${id}: path must reference an existing artifact`);
    const proofJSON = readJSONAt(baseDir, proof.path, errors, `${id}.path`);
    if (proofJSON && !proofOK(proofJSON)) fail(errors, `${id}: proof artifact must contain ok:true`);
  }
}

function validateMatrix(manifest, baseDir, errors) {
  const matrixRef = manifest.crossChannelMatrix;
  if (!isRecord(matrixRef)) {
    fail(errors, "crossChannelMatrix must be an object");
    return;
  }
  if (!pathExists(baseDir, matrixRef.path)) fail(errors, "crossChannelMatrix.path must reference an existing artifact");
  const matrix = readJSONAt(baseDir, matrixRef.path, errors, "crossChannelMatrix.path");
  if (!matrix) return;
  const result = validateCrossChannelPaidPathMatrix(matrix);
  if (!result.ok) {
    for (const error of result.errors) fail(errors, `crossChannelMatrix: ${error}`);
  }
}

function validateCanary(manifest, baseDir, errors) {
  const canary = manifest.canary;
  if (!isRecord(canary)) {
    fail(errors, "canary must be an object");
    return;
  }
  if (!pathExists(baseDir, canary.path)) fail(errors, "canary.path must reference an existing artifact");
  if (canary.ok !== true) fail(errors, "canary.ok must be true");
  const report = readJSONAt(baseDir, canary.path, errors, "canary.path");
  if (!report) return;
  const result = validateCommercialCanaryReport(report);
  if (!result.ok) {
    for (const error of result.errors) fail(errors, `canary: ${error}`);
  }
}

function validateRollback(manifest, baseDir, errors) {
  const rollback = manifest.rollbackDrill;
  if (!isRecord(rollback)) {
    fail(errors, "rollbackDrill must be an object");
    return;
  }
  if (rollback.ok !== true) fail(errors, "rollbackDrill.ok must be true");
  if (!pathExists(baseDir, rollback.path)) fail(errors, "rollbackDrill.path must reference an existing artifact");
  const drill = readJSONAt(baseDir, rollback.path, errors, "rollbackDrill.path");
  if (!drill) return;
  const result = validateCommercialRollbackDrill(drill);
  if (!result.ok) {
    for (const error of result.errors) fail(errors, `rollbackDrill: ${error}`);
  }
}

function validateReleaseIDs(manifest, baseDir, errors) {
  const release = manifest.release;
  if (!isRecord(release)) {
    fail(errors, "release must be an object");
    return;
  }
  if (!release.ios?.appVersionID) fail(errors, "release.ios.appVersionID is required");
  if (!release.ios?.buildNumber) fail(errors, "release.ios.buildNumber is required");
  if (!release.stripe?.livemode) fail(errors, "release.stripe.livemode must be true");
  if (!release.stripe?.cloudPriceID) fail(errors, "release.stripe.cloudPriceID is required");
  if (!release.stripe?.cloudProPriceID) fail(errors, "release.stripe.cloudProPriceID is required");
  if (!release.googlePlay?.track) fail(errors, "release.googlePlay.track is required");
  if (!release.website?.url) fail(errors, "release.website.url is required");
  if (!release.website?.deployID) fail(errors, "release.website.deployID is required");
  if (!release.publicLaunchReport?.path) {
    fail(errors, "release.publicLaunchReport.path is required");
    return;
  }
  if (!pathExists(baseDir, release.publicLaunchReport.path)) {
    fail(errors, "release.publicLaunchReport.path must reference an existing artifact");
  }
  const report = readJSONAt(baseDir, release.publicLaunchReport.path, errors, "release.publicLaunchReport.path");
  if (!report) return;
  const result = validatePublicLaunchReport(report);
  if (!result.ok) {
    for (const error of result.errors) fail(errors, `release.publicLaunchReport: ${error}`);
  }
}

function validateDashboards(manifest, baseDir, errors) {
  const dashboards = asArray(manifest.dashboards);
  if (dashboards.length === 0) {
    fail(errors, "dashboards must include at least one evidence artifact");
    return;
  }
  for (const dashboard of dashboards) {
    if (!isRecord(dashboard)) {
      fail(errors, "dashboard entry must be an object");
      continue;
    }
    if (!dashboard.kind) fail(errors, "dashboard.kind is required");
    if (!pathExists(baseDir, dashboard.path)) fail(errors, `${dashboard.kind || "dashboard"}: path must exist`);
  }
}

function validateDoneStamp(manifest, manifestPath, donePath, errors) {
  if (!existsSync(donePath)) {
    fail(errors, `${relative(process.cwd(), donePath)} is required`);
    return;
  }
  const done = readFileSync(donePath, "utf8");
  const requiredRefs = [
    manifest.launchGate?.path,
    manifest.crossChannelMatrix?.path,
    manifest.canary?.path,
    manifest.rollbackDrill?.path,
    ...asArray(manifest.paidProofs).map((proof) => proof?.path),
    relative(dirname(donePath), manifestPath),
  ].filter(Boolean);
  for (const evidencePath of requiredRefs) {
    const basename = evidencePath.split("/").pop();
    if (!done.includes(evidencePath) && !done.includes(basename)) {
      fail(errors, `LAUNCH_DONE.md must reference ${evidencePath}`);
    }
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
  validateMatrix(manifest, baseDir, errors);

  if (stage === "public-release" || stage === "done") {
    validateCanary(manifest, baseDir, errors);
  }

  if (stage === "done") {
    validateRollback(manifest, baseDir, errors);
    validateReleaseIDs(manifest, baseDir, errors);
    validateDashboards(manifest, baseDir, errors);
  }

  if (options.requireDoneStamp === true) {
    const donePath = options.donePath ?? join(baseDir, "LAUNCH_DONE.md");
    validateDoneStamp(manifest, manifestPath, donePath, errors);
  }

  return { ok: errors.length === 0, errors };
}

export function templateLaunchEvidenceBundle() {
  return {
    schemaVersion: 1,
    generatedAt: new Date(0).toISOString(),
    launchGate: {
      path: "latest-commercial-launch-gate.json",
    },
    paidProofs: Object.entries(REQUIRED_PAID_PROOFS).map(([id, spec]) => ({
      id,
      ok: true,
      channel: spec.channel,
      tier: spec.tier,
      path: `paid-proof-${id}.json`,
    })),
    crossChannelMatrix: {
      path: "cross-channel-paid-path-matrix.json",
    },
    canary: {
      ok: true,
      path: "canary-report.json",
    },
    rollbackDrill: {
      ok: true,
      path: "rollback-drill.json",
    },
    release: {
      ios: {
        appVersionID: "replace-with-app-store-version-id",
        buildNumber: "replace-with-build-number",
      },
      stripe: {
        livemode: true,
        cloudPriceID: "replace-with-live-cloud-price-id",
        cloudProPriceID: "replace-with-live-cloud-pro-price-id",
      },
      googlePlay: {
        track: "production",
      },
      website: {
        url: "https://openburnbar.com/pricing",
        deployID: "replace-with-deploy-id",
      },
      publicLaunchReport: {
        path: "public-launch-report.json",
      },
    },
    dashboards: [{ kind: "revenue-margin", path: "dashboard-revenue-margin.png" }],
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
  if (!STAGES.has(stage)) {
    console.error(JSON.stringify({ ok: false, errors: [`unknown launch evidence stage: ${stage}`] }, null, 2));
    return 1;
  }
  const positional = argv.filter(
    (arg, index) => !arg.startsWith("-") && (stageIndex < 0 || index !== stageIndex + 1),
  );
  const manifestPath = positional[0] ?? DEFAULT_MANIFEST_PATH;
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  } catch (error) {
    console.error(JSON.stringify({ ok: false, errors: [`${manifestPath}: cannot read JSON (${error.message})`] }, null, 2));
    return 1;
  }
  const result = validateLaunchEvidenceBundle(manifest, {
    manifestPath,
    stage,
    requireDoneStamp,
    donePath: DEFAULT_DONE_PATH,
  });
  if (!result.ok) {
    console.error(JSON.stringify(result, null, 2));
    return 1;
  }
  console.log(JSON.stringify({ ok: true, path: manifestPath, requireDoneStamp }, null, 2));
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exitCode = await main(process.argv.slice(2));
}
