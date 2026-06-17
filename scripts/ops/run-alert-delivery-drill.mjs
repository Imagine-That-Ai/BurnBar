#!/usr/bin/env node
/**
 * Triggers the alert-delivery drill canary and records human-confirmed delivery.
 *
 * GCP Monitoring can prove that channels are VERIFIED, but it has no API that
 * proves the endpoint received a notification. This command writes the canary
 * log event that trips the dedicated alert policy, then records the operator's
 * delivery confirmation as launch evidence.
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import process from "node:process";
import { checkBillingAlerts, checkOpsAlerts } from "../lib/ops-alerts-gate.mjs";
import {
  ALERT_DRILL_EVENT,
  ALERT_DRILL_LOG_NAME,
  alertDeliveryChannelDrift,
  alertDeliveryRunId,
  buildAlertDeliveryEvidence,
  buildPendingAlertDeliveryTrigger,
} from "../lib/alert-delivery-drill.mjs";
import { requiredVerifiableAlertChannels } from "../commercial-launch-gate.mjs";

const PROJECT = process.env.OPENBURNBAR_FIREBASE_PROJECT
  || process.env.GCLOUD_PROJECT
  || process.env.GOOGLE_CLOUD_PROJECT
  || "burnbar";
const OUTPUT = process.env.OPENBURNBAR_ALERT_DELIVERY_EVIDENCE
  || "launch-evidence/alert-channel-verified.json";
const PENDING = process.env.OPENBURNBAR_ALERT_DELIVERY_PENDING
  || "launch-evidence/alert-delivery-pending.json";

function usage() {
  console.error(`Usage:
  node scripts/ops/run-alert-delivery-drill.mjs [--skip-trigger]
  node scripts/ops/run-alert-delivery-drill.mjs --confirm-delivered --operator <name> [--run-id <id>] [--evidence-url <url>]

Without --confirm-delivered, this command prints the verifiable channels and
triggers the canary log event, then writes ${PENDING}. Re-run with
--confirm-delivered after the human endpoint receives that same canary.`);
}

function parseArgs(argv) {
  const args = {
    confirmDelivered: false,
    operator: process.env.USER || process.env.GITHUB_ACTOR || "",
    evidenceUrl: "",
    skipTrigger: false,
    runId: "",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--confirm-delivered") args.confirmDelivered = true;
    else if (arg === "--operator") args.operator = argv[++i] || "";
    else if (arg === "--evidence-url") args.evidenceUrl = argv[++i] || "";
    else if (arg === "--skip-trigger") args.skipTrigger = true;
    else if (arg === "--run-id") args.runId = argv[++i] || "";
    else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else {
      console.error(`Unknown argument: ${arg}`);
      usage();
      process.exit(2);
    }
  }
  return args;
}

function run(command, args) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  return {
    ok: result.status === 0,
    status: result.status,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    error: result.error?.message,
  };
}

function readPendingTrigger(path) {
  if (!existsSync(path)) {
    console.error(`FAIL: missing pending trigger evidence at ${path}. Run without --confirm-delivered first.`);
    process.exit(2);
  }
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    console.error(`FAIL: invalid pending trigger evidence at ${path}: ${error.message}`);
    process.exit(2);
  }
}

function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

const args = parseArgs(process.argv.slice(2));

const opsAlerts = checkOpsAlerts();
const billingAlerts = checkBillingAlerts();
const channels = requiredVerifiableAlertChannels(opsAlerts, billingAlerts);
if (channels.length === 0) {
  console.error("FAIL: no verifiable email/SMS channels found in ops/billing alert policies.");
  process.exit(1);
}

if (args.confirmDelivered) {
  if (args.skipTrigger) {
    console.error("FAIL: --skip-trigger is only for dry-running channel discovery, not delivery confirmation.");
    process.exit(2);
  }
  if (!args.operator.trim()) {
    console.error("FAIL: --operator is required when recording delivery evidence.");
    process.exit(2);
  }
  const pending = readPendingTrigger(PENDING);
  if (args.runId && pending.runId !== args.runId) {
    console.error(`FAIL: pending runId ${pending.runId} does not match requested ${args.runId}.`);
    process.exit(2);
  }
  const drift = alertDeliveryChannelDrift(pending.channels, channels);
  if (!drift.ok) {
    console.error(
      "FAIL: pending alert channels drifted since trigger; trigger a fresh canary. "
        + `missing=${JSON.stringify(drift.missing)} `
        + `stale=${JSON.stringify(drift.stale)} `
        + `changed=${JSON.stringify(drift.changed)}`,
    );
    process.exit(1);
  }

  const evidence = buildAlertDeliveryEvidence({
    pending,
    operator: args.operator,
    evidenceUrl: args.evidenceUrl,
  });
  const timestamped = join(dirname(OUTPUT), `alert-channel-verified-${evidence.runId}.json`);
  writeJson(OUTPUT, evidence);
  writeJson(timestamped, evidence);
  unlinkSync(PENDING);
  console.log(
    JSON.stringify({ ok: true, output: OUTPUT, timestamped, confirmedRunId: evidence.runId }, null, 2),
  );
  process.exit(0);
}

const triggeredAt = new Date().toISOString();
const runId = alertDeliveryRunId(triggeredAt);

console.log(JSON.stringify({ project: PROJECT, runId, channels }, null, 2));

let triggerResult = { ok: true, skipped: true };
if (!args.skipTrigger) {
  triggerResult = run("gcloud", [
    "logging",
    "write",
    ALERT_DRILL_LOG_NAME,
    JSON.stringify({
      event: ALERT_DRILL_EVENT,
      runId,
      triggeredAt,
      project: PROJECT,
    }),
    "--payload-type=json",
    "--severity=ERROR",
    "--project",
    PROJECT,
  ]);
  if (!triggerResult.ok) {
    console.error(triggerResult.stderr || triggerResult.stdout || triggerResult.error);
    process.exit(1);
  }
}

if (args.skipTrigger) {
  console.error("Canary trigger skipped. Re-run without --skip-trigger to create a pending canary run.");
  process.exit(2);
}

const pending = buildPendingAlertDeliveryTrigger({
  project: PROJECT,
  runId,
  triggeredAt,
  channels,
});
writeJson(PENDING, pending);

console.error(
  `Canary triggered for ${runId}. After the endpoint receives it, run: `
    + `node scripts/ops/run-alert-delivery-drill.mjs --confirm-delivered --operator <name> --run-id ${runId}`,
);
console.log(JSON.stringify({ ok: false, pending: PENDING, runId, triggerResult }, null, 2));
process.exit(2);
