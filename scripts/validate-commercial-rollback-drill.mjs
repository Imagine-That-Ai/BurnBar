#!/usr/bin/env node
/**
 * Validate T33 commercial rollback drill evidence.
 *
 * This validates that the drill captured every rollback control required by
 * GTMMasterPlan.MD and docs/COMMERCIAL_ROLLBACK.md. It does not perform the
 * rollback; operators attach command outputs and console access evidence.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import process from "node:process";

const DEFAULT_DRILL_PATH = "launch-evidence/rollback-drill.json";

const REQUIRED_TRIGGERS = Object.freeze([
  "cloud_pro_gross_margin_below_50",
  "media_projection_over_600",
  "media_hard_cap_over_1000",
  "computer_use_projection_over_1500",
  "computer_use_hard_cap_over_2500",
  "app_check_denied_over_1_percent",
  "entitlement_mismatch_over_0_5_percent",
  "stripe_webhook_failure_over_5m",
  "apple_or_play_rejection_after_release",
  "security_incident",
]);

const REQUIRED_CONTROLS = Object.freeze([
  "remote_config_kill_switch_patch",
  "hosting_release_list",
  "functions_build",
  "cloud_run_revision_list",
  "commercial_launch_gate",
  "ops_readiness",
  "stripe_console_access",
  "apple_console_access",
  "google_play_console_access",
]);

const REQUIRED_REMOTE_CONFIG_VALUES = Object.freeze({
  media_kill_switch: "true",
  computer_use_kill_switch: "true",
  hosted_quota_daily_refresh_limit: "0",
  hosted_quota_monthly_refresh_limit: "0",
});

function usage() {
  return `Usage:
  scripts/validate-commercial-rollback-drill.mjs [rollback-drill.json]
  scripts/validate-commercial-rollback-drill.mjs --template

Default drill path: ${DEFAULT_DRILL_PATH}
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

function validateControl(control, errors) {
  if (!isRecord(control)) {
    fail(errors, "control entry must be an object");
    return;
  }
  if (control.ok !== true) fail(errors, `${control.id ?? "control"}: ok must be true`);
  if (!hasEvidence(control.evidence)) fail(errors, `${control.id ?? "control"}: evidence must include {kind,path}`);
}

export function validateCommercialRollbackDrill(drill) {
  const errors = [];
  if (!isRecord(drill)) return { ok: false, errors: ["drill must be a JSON object"] };
  if (drill.schemaVersion !== 1) fail(errors, "schemaVersion must be 1");
  if (drill.ok !== true) fail(errors, "ok must be true");
  if (typeof drill.generatedAt !== "string" || Number.isNaN(Date.parse(drill.generatedAt))) {
    fail(errors, "generatedAt must be an ISO timestamp string");
  }

  if (!arrayIncludesAll(drill.triggersCovered, REQUIRED_TRIGGERS)) {
    fail(errors, `triggersCovered must include ${REQUIRED_TRIGGERS.join(", ")}`);
  }
  if (!arrayIncludesAll(drill.controlsCovered, REQUIRED_CONTROLS)) {
    fail(errors, `controlsCovered must include ${REQUIRED_CONTROLS.join(", ")}`);
  }

  const remoteConfig = drill.remoteConfigPatch ?? {};
  for (const [key, expected] of Object.entries(REQUIRED_REMOTE_CONFIG_VALUES)) {
    if (String(remoteConfig[key]) !== expected) {
      fail(errors, `remoteConfigPatch.${key} must be ${expected}`);
    }
  }
  if (drill.remoteConfigPublished !== false) {
    fail(errors, "remoteConfigPublished must be false for dry-run rollback evidence");
  }
  if (drill.killSwitchHaltVerified !== true) {
    fail(errors, "killSwitchHaltVerified must be true");
  }
  if (drill.onCallCanExecute !== true) {
    fail(errors, "onCallCanExecute must be true");
  }
  if (drill.safeRollbackTargetIdentified !== true) {
    fail(errors, "safeRollbackTargetIdentified must be true");
  }
  if (drill.customerFacingSurfacesExplained !== true) {
    fail(errors, "customerFacingSurfacesExplained must be true");
  }

  const controlsByID = new Map((Array.isArray(drill.controls) ? drill.controls : []).map((control) => [control?.id, control]));
  for (const controlID of REQUIRED_CONTROLS) {
    const control = controlsByID.get(controlID);
    if (!control) {
      fail(errors, `missing control: ${controlID}`);
      continue;
    }
    validateControl(control, errors);
  }

  return { ok: errors.length === 0, errors };
}

export function templateCommercialRollbackDrill() {
  return {
    schemaVersion: 1,
    ok: true,
    generatedAt: new Date(0).toISOString(),
    triggersCovered: REQUIRED_TRIGGERS,
    controlsCovered: REQUIRED_CONTROLS,
    remoteConfigPublished: false,
    remoteConfigPatch: REQUIRED_REMOTE_CONFIG_VALUES,
    killSwitchHaltVerified: true,
    onCallCanExecute: true,
    safeRollbackTargetIdentified: true,
    customerFacingSurfacesExplained: true,
    controls: REQUIRED_CONTROLS.map((id) => ({
      id,
      ok: true,
      evidence: [{ kind: "command-output", path: `launch-evidence/rollback-${id}.txt` }],
    })),
  };
}

function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage());
    return 0;
  }
  if (argv.includes("--template")) {
    console.log(JSON.stringify(templateCommercialRollbackDrill(), null, 2));
    return 0;
  }
  const drillPath = argv[0] || DEFAULT_DRILL_PATH;
  const drill = JSON.parse(readFileSync(drillPath, "utf8"));
  const result = validateCommercialRollbackDrill(drill);
  if (!result.ok) {
    console.error(JSON.stringify(result, null, 2));
    return 1;
  }
  console.log(JSON.stringify({ ok: true, path: drillPath }, null, 2));
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exitCode = main(process.argv.slice(2));
}
