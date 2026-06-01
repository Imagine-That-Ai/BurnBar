#!/usr/bin/env node
/**
 * Validate the GTM T29 cross-channel paid-path smoke matrix.
 *
 * This script intentionally validates evidence shape only. The matrix itself
 * must be produced after real Apple, Stripe, and Google Play paid-path proof.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import process from "node:process";

const DEFAULT_MATRIX_PATH = "launch-evidence/cross-channel-paid-path-matrix.json";

const PRODUCTS = Object.freeze({
  cloudMonthly: "com.openburnbar.pro.monthly",
  cloudAnnual: "com.openburnbar.pro.annual",
  cloudProMonthly: "com.openburnbar.proMax.v2.monthly",
  cloudProAnnual: "com.openburnbar.proMax.annual",
  legacyHostedQuota: "com.openburnbar.hostedQuotaSync.cloud.monthly",
});

const REQUIRED_ROWS = Object.freeze({
  stripe_cloud_monthly: {
    channel: "stripe",
    tier: "cloud",
    entitlementID: "burnbar_pro",
    productIDs: [PRODUCTS.cloudMonthly],
    groupA: true,
    groupB: false,
    events: ["purchase"],
  },
  stripe_cloud_pro_annual: {
    channel: "stripe",
    tier: "cloud-pro",
    entitlementID: "burnbar_pro_max",
    productIDs: [PRODUCTS.cloudProAnnual],
    groupA: true,
    groupB: true,
    events: ["purchase"],
    requireAllowance: true,
  },
  apple_cloud_restore_cancel_refund: {
    channel: "apple",
    tier: "cloud",
    entitlementID: "burnbar_pro",
    productIDs: [PRODUCTS.cloudMonthly, PRODUCTS.cloudAnnual],
    groupA: true,
    groupB: false,
    events: ["purchase", "restore", "cancel", "refund"],
    requireRevocation: true,
  },
  apple_cloud_pro_topup: {
    channel: "apple",
    tier: "cloud-pro",
    entitlementID: "burnbar_pro_max",
    productIDs: [PRODUCTS.cloudProMonthly, PRODUCTS.cloudProAnnual],
    groupA: true,
    groupB: true,
    events: ["purchase", "topup"],
    requireAllowance: true,
    requireTopUp: true,
  },
  google_play_cloud_restore_cancel_refund: {
    channel: "google_play",
    tier: "cloud",
    entitlementID: "burnbar_pro",
    productIDs: [PRODUCTS.cloudMonthly, PRODUCTS.cloudAnnual],
    groupA: true,
    groupB: false,
    events: ["purchase", "restore", "cancel", "refund"],
    requireRevocation: true,
  },
  google_play_cloud_pro_topup: {
    channel: "google_play",
    tier: "cloud-pro",
    entitlementID: "burnbar_pro_max",
    productIDs: [PRODUCTS.cloudProMonthly, PRODUCTS.cloudProAnnual],
    groupA: true,
    groupB: true,
    events: ["purchase", "topup"],
    requireAllowance: true,
    requireTopUp: true,
  },
  legacy_hosted_quota_group_a_only: {
    channel: "legacy",
    tier: "legacy-hosted-quota",
    entitlementID: "hosted_quota_sync",
    productIDs: [PRODUCTS.legacyHostedQuota],
    groupA: true,
    groupB: false,
    events: ["grandfathered_access"],
  },
  expired_canceled_fail_closed: {
    channel: "any",
    tier: "expired-or-canceled",
    entitlementID: null,
    productIDs: [],
    groupA: false,
    groupB: false,
    events: ["expired", "canceled"],
    requireFailClosed: true,
  },
});

function usage() {
  return `Usage:
  scripts/validate-cross-channel-paid-path-matrix.mjs [matrix.json]
  cat matrix.json | scripts/validate-cross-channel-paid-path-matrix.mjs -
  scripts/validate-cross-channel-paid-path-matrix.mjs --template

Default matrix path: ${DEFAULT_MATRIX_PATH}
`;
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function fail(errors, message) {
  errors.push(message);
}

function arrayIncludesAll(values, required) {
  const set = new Set(Array.isArray(values) ? values : []);
  return required.every((value) => set.has(value));
}

function hasEvidence(row) {
  return (
    Array.isArray(row.evidence) &&
    row.evidence.some(
      (item) =>
        isRecord(item) &&
        typeof item.kind === "string" &&
        typeof item.path === "string" &&
        item.path.length > 0,
    )
  );
}

function clientSelfGrantDenied(matrix, row) {
  return matrix.security?.clientSelfGrantDenied === true || row.featureGates?.clientSelfGrantDenied === true;
}

async function readStdin() {
  let text = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) {
    text += chunk;
  }
  return text;
}

function validateRow(matrix, row, spec, errors) {
  if (!isRecord(row)) {
    fail(errors, "row is not an object");
    return;
  }
  if (row.ok !== true) fail(errors, `${row.id}: ok must be true`);
  if (spec.channel !== "any" && row.channel !== spec.channel) {
    fail(errors, `${row.id}: channel must be ${spec.channel}`);
  }
  if (row.tier !== spec.tier) fail(errors, `${row.id}: tier must be ${spec.tier}`);
  if (!arrayIncludesAll(row.events, spec.events)) {
    fail(errors, `${row.id}: events must include ${spec.events.join(", ")}`);
  }
  if (!hasEvidence(row)) fail(errors, `${row.id}: evidence must include at least one {kind,path}`);
  if (!clientSelfGrantDenied(matrix, row)) {
    fail(errors, `${row.id}: client self-grant denial evidence is required`);
  }

  const gates = row.featureGates ?? {};
  if (gates.groupA !== spec.groupA) fail(errors, `${row.id}: groupA gate mismatch`);
  if (gates.groupB !== spec.groupB) fail(errors, `${row.id}: groupB gate mismatch`);

  if (spec.entitlementID) {
    const entitlement = row.entitlement ?? {};
    if (entitlement.id !== spec.entitlementID) fail(errors, `${row.id}: entitlement.id mismatch`);
    if (entitlement.active !== true) fail(errors, `${row.id}: entitlement.active must be true`);
    if (!spec.productIDs.includes(entitlement.productID)) {
      fail(errors, `${row.id}: entitlement.productID is not allowed for this row`);
    }
  }

  if (spec.requireAllowance && row.allowanceLedger?.present !== true) {
    fail(errors, `${row.id}: allowanceLedger.present must be true`);
  }
  if (spec.requireTopUp && row.topUp?.present !== true) {
    fail(errors, `${row.id}: topUp.present must be true`);
  }
  if (spec.requireRevocation && row.revocation?.verified !== true) {
    fail(errors, `${row.id}: revocation.verified must be true`);
  }
  if (spec.requireFailClosed) {
    if (row.failClosed !== true) fail(errors, `${row.id}: failClosed must be true`);
    if (row.entitlement?.active === true) fail(errors, `${row.id}: active entitlement is not allowed`);
  }
}

export function validateCrossChannelPaidPathMatrix(matrix) {
  const errors = [];
  if (!isRecord(matrix)) return { ok: false, errors: ["matrix must be a JSON object"] };
  if (matrix.schemaVersion !== 1) fail(errors, "schemaVersion must be 1");
  if (typeof matrix.generatedAt !== "string" || Number.isNaN(Date.parse(matrix.generatedAt))) {
    fail(errors, "generatedAt must be an ISO timestamp string");
  }
  if (!Array.isArray(matrix.rows)) fail(errors, "rows must be an array");

  const rowsByID = new Map((Array.isArray(matrix.rows) ? matrix.rows : []).map((row) => [row?.id, row]));
  for (const [rowID, spec] of Object.entries(REQUIRED_ROWS)) {
    const row = rowsByID.get(rowID);
    if (!row) {
      fail(errors, `missing row: ${rowID}`);
      continue;
    }
    validateRow(matrix, row, spec, errors);
  }
  return { ok: errors.length === 0, errors };
}

export function templateMatrix() {
  return {
    schemaVersion: 1,
    generatedAt: new Date(0).toISOString(),
    security: {
      clientSelfGrantDenied: true,
      evidence: [{ kind: "firestore-rules", path: "functions test output" }],
    },
    rows: Object.entries(REQUIRED_ROWS).map(([id, spec]) => ({
      id,
      ok: true,
      channel: spec.channel,
      tier: spec.tier,
      events: spec.events,
      entitlement: spec.entitlementID
        ? {
            id: spec.entitlementID,
            active: true,
            productID: spec.productIDs[0],
          }
        : { active: false },
      featureGates: {
        groupA: spec.groupA,
        groupB: spec.groupB,
      },
      allowanceLedger: spec.requireAllowance ? { present: true } : undefined,
      topUp: spec.requireTopUp ? { present: true } : undefined,
      revocation: spec.requireRevocation ? { verified: true } : undefined,
      failClosed: spec.requireFailClosed ? true : undefined,
      evidence: [{ kind: "placeholder", path: "replace-with-live-proof-artifact" }],
    })),
  };
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage());
    return 0;
  }
  if (argv.includes("--template")) {
    console.log(JSON.stringify(templateMatrix(), null, 2));
    return 0;
  }
  const matrixPath = argv[0] || DEFAULT_MATRIX_PATH;
  const matrixText = matrixPath === "-" ? await readStdin() : readFileSync(matrixPath, "utf8");
  const matrix = JSON.parse(matrixText);
  const result = validateCrossChannelPaidPathMatrix(matrix);
  if (!result.ok) {
    console.error(JSON.stringify(result, null, 2));
    return 1;
  }
  console.log(JSON.stringify({ ok: true, path: matrixPath }, null, 2));
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exitCode = await main(process.argv.slice(2));
}
