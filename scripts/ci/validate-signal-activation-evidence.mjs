#!/usr/bin/env node
/**
 * Validate the SOTASIGNAL activation evidence bundle.
 *
 * This is intentionally stricter than a status doc:
 * - `ready-for-phase-e` means every prerequisite artifact is present.
 * - `phase-e-active` additionally means production rings were activated and a
 *   live rollback drill was evidenced.
 *
 * External crypto/legal review may be replaced only by an explicit owner risk
 * acceptance artifact. That is not the same as independent review or legal
 * advice; it is an owner waiver recorded in the evidence bundle.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

const DEFAULT_MANIFEST = ".agent/runs/sotasignal-full-ship-20260605/evidence/signal-activation-evidence.json";
const REQUIRED_DEVICES = ["iphone", "ipad", "android", "mac"];
const REQUIRED_DEVICE_FLOWS = [
  "iphone_to_mac_at_rest",
  "mac_to_iphone_at_rest",
  "android_to_mac_or_iphone_at_rest",
  "pensieve_write_read",
  "mobile_assistant_chat_write_read",
  "cli_mission_request_write_read",
  "trust_safety_code_compare",
  "revocation_blocks_future_decrypt",
  "legacy_dual_read",
  "relocation_rejected_all_platforms",
];
const REQUIRED_PRODUCER_DOMAINS = [
  "pensieve",
  "mobile_assistant_chats",
  "cli_agent_mission_requests",
];
const REQUIRED_RULE0_ITEMS = [".gitmodules", "Vendor/libsignal", "website/src/data/trust.generated.ts"];

function usage() {
  return `Usage:
  scripts/ci/validate-signal-activation-evidence.mjs [manifest.json]
  scripts/ci/validate-signal-activation-evidence.mjs --template
`;
}

function template() {
  return {
    schemaVersion: 1,
    status: "blocked",
    generatedAt: new Date().toISOString(),
    repo: {
      branch: "signal/phase2",
      head: "",
      dirtyTreeAccepted: true,
    },
    externalCryptoReview: {
      ok: false,
      reviewer: "",
      reportPath: "",
      blockerFindingsClosed: false,
      majorFindingsClosed: false,
    },
    legalAgplMasSignoff: {
      ok: false,
      approver: "",
      reportPath: "",
      agplSourceOfferApproved: false,
        masDistributionApprovedOrExcluded: false,
        rule0ItemsApproved: REQUIRED_RULE0_ITEMS.map((path) => ({ path, approved: false, evidence: "" })),
    },
    ownerRiskAcceptance: {
      ok: false,
      acceptedBy: "",
      acceptedAt: "",
      reportPath: "",
      waivesExternalCryptoReview: false,
      waivesLegalAgplMasReview: false,
      acceptsAgplMasRule0Risk: false,
      acceptsNoIndependentExternalReview: false,
    },
    nativePackaging: {
      ok: false,
      apple: {
        ok: false,
        xcframeworkLog: "",
        slices: [],
        scriptRecreatedArtifact: false,
        iosSimulatorBuildLog: "",
        iosDeviceBuildLog: "",
        macosBuildLog: "",
        notarizationOrMasEvidence: "",
      },
      android: {
        ok: false,
        gradleLog: "",
        instrumentedDeviceLog: "",
        signalMavenVerified: false,
      },
    },
    physicalDeviceE2E: {
      ok: false,
      devices: REQUIRED_DEVICES.map((id) => ({ id, ok: false, evidence: "" })),
      flows: REQUIRED_DEVICE_FLOWS.map((id) => ({ id, ok: false, evidence: "" })),
    },
    productionProducerWiring: {
      ok: false,
      domains: REQUIRED_PRODUCER_DOMAINS.map((id) => ({
        id,
        ok: false,
        producerEvidence: "",
        adminValidatorEvidence: "",
        legacyDualReadEvidence: "",
        telemetryEvidence: "",
      })),
    },
    l40SourceManifestId: {
      ok: false,
      migrationPlan: "",
      backfillEvidence: "",
      emulatorEvidence: "",
    },
    l41PrekeySessionDirectory: {
      ok: false,
      designDoc: "",
      rulesEvidence: "",
      rotationEvidence: "",
      revocationEvidence: "",
    },
    phaseEActivation: {
      ok: false,
      activationCommit: "",
      ringEvidence: "",
      liveRollbackEvidence: "",
      rollbackSeconds: null,
      ownerSignoff: "",
    },
  };
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function fail(errors, message) {
  errors.push(message);
}

function resolvePath(baseDir, evidencePath) {
  if (typeof evidencePath !== "string" || evidencePath.length === 0) return null;
  if (/^https?:\/\//.test(evidencePath)) return evidencePath;
  return isAbsolute(evidencePath) ? evidencePath : join(baseDir, evidencePath);
}

function pathExists(baseDir, evidencePath) {
  const resolved = resolvePath(baseDir, evidencePath);
  if (!resolved) return false;
  if (/^https?:\/\//.test(resolved)) return true;
  return existsSync(resolved);
}

function requirePath(baseDir, errors, label, evidencePath) {
  if (!pathExists(baseDir, evidencePath)) {
    fail(errors, `${label} must reference an existing local artifact or HTTPS URL`);
  }
}

function requireOK(errors, label, value) {
  if (value !== true) fail(errors, `${label}.ok must be true`);
}

function validateReview(manifest, baseDir, errors) {
  const ref = manifest.externalCryptoReview;
  if (!isRecord(ref)) return fail(errors, "externalCryptoReview must be an object");
  requireOK(errors, "externalCryptoReview", ref.ok);
  if (!ref.reviewer) fail(errors, "externalCryptoReview.reviewer is required");
  requirePath(baseDir, errors, "externalCryptoReview.reportPath", ref.reportPath);
  if (ref.blockerFindingsClosed !== true) fail(errors, "externalCryptoReview.blockerFindingsClosed must be true");
  if (ref.majorFindingsClosed !== true) fail(errors, "externalCryptoReview.majorFindingsClosed must be true");
}

function validateLegal(manifest, baseDir, errors) {
  const ref = manifest.legalAgplMasSignoff;
  if (!isRecord(ref)) return fail(errors, "legalAgplMasSignoff must be an object");
  requireOK(errors, "legalAgplMasSignoff", ref.ok);
  if (!ref.approver) fail(errors, "legalAgplMasSignoff.approver is required");
  requirePath(baseDir, errors, "legalAgplMasSignoff.reportPath", ref.reportPath);
  if (ref.agplSourceOfferApproved !== true) fail(errors, "legalAgplMasSignoff.agplSourceOfferApproved must be true");
  if (ref.masDistributionApprovedOrExcluded !== true) {
    fail(errors, "legalAgplMasSignoff.masDistributionApprovedOrExcluded must be true");
  }
  const approvals = new Map((Array.isArray(ref.rule0ItemsApproved) ? ref.rule0ItemsApproved : []).map((item) => [item?.path, item]));
  for (const path of REQUIRED_RULE0_ITEMS) {
    const item = approvals.get(path);
    if (!isRecord(item) || item.approved !== true) fail(errors, `legalAgplMasSignoff.rule0ItemsApproved missing approval for ${path}`);
    else requirePath(baseDir, errors, `legalAgplMasSignoff.rule0ItemsApproved[${path}].evidence`, item.evidence);
  }
}

function ownerRiskAcceptanceWaivesExternalLegal(manifest, baseDir, errors) {
  const ref = manifest.ownerRiskAcceptance;
  if (!isRecord(ref)) return false;
  if (ref.ok !== true) return false;

  const localErrors = [];
  if (!ref.acceptedBy) fail(localErrors, "ownerRiskAcceptance.acceptedBy is required");
  if (!ref.acceptedAt) fail(localErrors, "ownerRiskAcceptance.acceptedAt is required");
  requirePath(baseDir, localErrors, "ownerRiskAcceptance.reportPath", ref.reportPath);
  if (ref.waivesExternalCryptoReview !== true) {
    fail(localErrors, "ownerRiskAcceptance.waivesExternalCryptoReview must be true");
  }
  if (ref.waivesLegalAgplMasReview !== true) {
    fail(localErrors, "ownerRiskAcceptance.waivesLegalAgplMasReview must be true");
  }
  if (ref.acceptsAgplMasRule0Risk !== true) {
    fail(localErrors, "ownerRiskAcceptance.acceptsAgplMasRule0Risk must be true");
  }
  if (ref.acceptsNoIndependentExternalReview !== true) {
    fail(localErrors, "ownerRiskAcceptance.acceptsNoIndependentExternalReview must be true");
  }

  for (const error of localErrors) fail(errors, error);
  return localErrors.length === 0;
}

function validatePackaging(manifest, baseDir, errors) {
  const ref = manifest.nativePackaging;
  if (!isRecord(ref)) return fail(errors, "nativePackaging must be an object");
  requireOK(errors, "nativePackaging", ref.ok);
  const apple = ref.apple;
  const android = ref.android;
  if (!isRecord(apple)) fail(errors, "nativePackaging.apple must be an object");
  else {
    requireOK(errors, "nativePackaging.apple", apple.ok);
    requirePath(baseDir, errors, "nativePackaging.apple.xcframeworkLog", apple.xcframeworkLog);
    const slices = new Set(Array.isArray(apple.slices) ? apple.slices : []);
    for (const slice of ["macos-arm64", "ios-arm64", "ios-simulator-arm64"]) {
      if (!slices.has(slice)) fail(errors, `nativePackaging.apple.slices must include ${slice}`);
    }
    if (apple.scriptRecreatedArtifact !== true) fail(errors, "nativePackaging.apple.scriptRecreatedArtifact must be true");
    for (const key of ["iosSimulatorBuildLog", "iosDeviceBuildLog", "macosBuildLog", "notarizationOrMasEvidence"]) {
      requirePath(baseDir, errors, `nativePackaging.apple.${key}`, apple[key]);
    }
  }
  if (!isRecord(android)) fail(errors, "nativePackaging.android must be an object");
  else {
    requireOK(errors, "nativePackaging.android", android.ok);
    if (android.signalMavenVerified !== true) fail(errors, "nativePackaging.android.signalMavenVerified must be true");
    requirePath(baseDir, errors, "nativePackaging.android.gradleLog", android.gradleLog);
    requirePath(baseDir, errors, "nativePackaging.android.instrumentedDeviceLog", android.instrumentedDeviceLog);
  }
}

function validatePhysicalDevices(manifest, baseDir, errors) {
  const ref = manifest.physicalDeviceE2E;
  if (!isRecord(ref)) return fail(errors, "physicalDeviceE2E must be an object");
  requireOK(errors, "physicalDeviceE2E", ref.ok);
  const devices = new Map((Array.isArray(ref.devices) ? ref.devices : []).map((item) => [item?.id, item]));
  for (const id of REQUIRED_DEVICES) {
    const item = devices.get(id);
    if (!isRecord(item) || item.ok !== true) fail(errors, `physicalDeviceE2E.devices missing passing row for ${id}`);
    else requirePath(baseDir, errors, `physicalDeviceE2E.devices[${id}].evidence`, item.evidence);
  }
  const flows = new Map((Array.isArray(ref.flows) ? ref.flows : []).map((item) => [item?.id, item]));
  for (const id of REQUIRED_DEVICE_FLOWS) {
    const item = flows.get(id);
    if (!isRecord(item) || item.ok !== true) fail(errors, `physicalDeviceE2E.flows missing passing row for ${id}`);
    else requirePath(baseDir, errors, `physicalDeviceE2E.flows[${id}].evidence`, item.evidence);
  }
}

function validateProducerWiring(manifest, baseDir, errors) {
  const ref = manifest.productionProducerWiring;
  if (!isRecord(ref)) return fail(errors, "productionProducerWiring must be an object");
  requireOK(errors, "productionProducerWiring", ref.ok);
  const domains = new Map((Array.isArray(ref.domains) ? ref.domains : []).map((item) => [item?.id, item]));
  for (const id of REQUIRED_PRODUCER_DOMAINS) {
    const item = domains.get(id);
    if (!isRecord(item) || item.ok !== true) {
      fail(errors, `productionProducerWiring.domains missing passing row for ${id}`);
      continue;
    }
    for (const key of ["producerEvidence", "adminValidatorEvidence", "legacyDualReadEvidence", "telemetryEvidence"]) {
      requirePath(baseDir, errors, `productionProducerWiring.domains[${id}].${key}`, item[key]);
    }
  }
}

function validateL40L41(manifest, baseDir, errors) {
  for (const [section, keys] of Object.entries({
    l40SourceManifestId: ["migrationPlan", "backfillEvidence", "emulatorEvidence"],
    l41PrekeySessionDirectory: ["designDoc", "rulesEvidence", "rotationEvidence", "revocationEvidence"],
  })) {
    const ref = manifest[section];
    if (!isRecord(ref)) {
      fail(errors, `${section} must be an object`);
      continue;
    }
    requireOK(errors, section, ref.ok);
    for (const key of keys) requirePath(baseDir, errors, `${section}.${key}`, ref[key]);
  }
}

function validateActivation(manifest, baseDir, errors) {
  const ref = manifest.phaseEActivation;
  if (!isRecord(ref)) return fail(errors, "phaseEActivation must be an object");
  requireOK(errors, "phaseEActivation", ref.ok);
  if (!ref.activationCommit) fail(errors, "phaseEActivation.activationCommit is required");
  requirePath(baseDir, errors, "phaseEActivation.ringEvidence", ref.ringEvidence);
  requirePath(baseDir, errors, "phaseEActivation.liveRollbackEvidence", ref.liveRollbackEvidence);
  if (typeof ref.rollbackSeconds !== "number" || ref.rollbackSeconds > 60) {
    fail(errors, "phaseEActivation.rollbackSeconds must be a number <= 60");
  }
  requirePath(baseDir, errors, "phaseEActivation.ownerSignoff", ref.ownerSignoff);
}

function validate(manifest, baseDir) {
  const errors = [];
  if (manifest.schemaVersion !== 1) fail(errors, "schemaVersion must be 1");
  const allowedStatuses = new Set(["ready-for-phase-e", "phase-e-active"]);
  if (!allowedStatuses.has(manifest.status)) fail(errors, "status must be ready-for-phase-e or phase-e-active");

  const ownerWaivedExternalLegal = ownerRiskAcceptanceWaivesExternalLegal(manifest, baseDir, errors);
  if (!ownerWaivedExternalLegal) {
    validateReview(manifest, baseDir, errors);
    validateLegal(manifest, baseDir, errors);
  }

  validatePackaging(manifest, baseDir, errors);
  validatePhysicalDevices(manifest, baseDir, errors);
  validateProducerWiring(manifest, baseDir, errors);
  validateL40L41(manifest, baseDir, errors);
  if (manifest.status === "phase-e-active") {
    validateActivation(manifest, baseDir, errors);
  }
  return errors;
}

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(usage());
  process.exit(0);
}
if (args.includes("--template")) {
  console.log(JSON.stringify(template(), null, 2));
  process.exit(0);
}

const manifestPath = args[0] ?? DEFAULT_MANIFEST;
let manifest;
try {
  manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
} catch (error) {
  console.error(`signal activation evidence FAILED: cannot read ${manifestPath}: ${error.message}`);
  process.exit(1);
}

const baseDir = dirname(isAbsolute(manifestPath) ? manifestPath : join(process.cwd(), manifestPath));
const errors = validate(manifest, baseDir);
if (errors.length > 0) {
  console.error(`signal activation evidence FAILED (${errors.length} issue${errors.length === 1 ? "" : "s"}):`);
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}

if (manifest.status === "phase-e-active") {
  console.log("signal activation evidence OK — Phase-E activation and rollback evidence are present.");
} else {
  console.log("signal activation evidence OK — all Phase-E prerequisite artifacts are present; production activation is not marked complete.");
}
