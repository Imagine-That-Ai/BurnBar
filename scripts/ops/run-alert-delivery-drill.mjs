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
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import process from "node:process";
import { checkBillingAlerts, checkOpsAlerts } from "../lib/ops-alerts-gate.mjs";
import { requiredVerifiableAlertChannels } from "../commercial-launch-gate.mjs";

const PROJECT = process.env.OPENBURNBAR_FIREBASE_PROJECT
  || process.env.GCLOUD_PROJECT
  || process.env.GOOGLE_CLOUD_PROJECT
  || "burnbar";
const OUTPUT = process.env.OPENBURNBAR_ALERT_DELIVERY_EVIDENCE
  || "launch-evidence/alert-channel-verified.json";

function usage() {
  console.error(`Usage: node scripts/ops/run-alert-delivery-drill.mjs --confirm-delivered --operator <name> [--evidence-url <url>] [--skip-trigger]

Without --confirm-delivered, this command prints the verifiable channels and
triggers the canary log event, but refuses to write launch evidence.`);
}

function parseArgs(argv) {
  const args = {
    confirmDelivered: false,
    operator: process.env.USER || process.env.GITHUB_ACTOR || "",
    evidenceUrl: "",
    skipTrigger: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--confirm-delivered") args.confirmDelivered = true;
    else if (arg === "--operator") args.operator = argv[++i] || "";
    else if (arg === "--evidence-url") args.evidenceUrl = argv[++i] || "";
    else if (arg === "--skip-trigger") args.skipTrigger = true;
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

const args = parseArgs(process.argv.slice(2));
const triggeredAt = new Date().toISOString();
const runId = `alert-delivery-drill-${triggeredAt.replace(/[:.]/g, "-")}`;

const opsAlerts = checkOpsAlerts();
const billingAlerts = checkBillingAlerts();
const channels = requiredVerifiableAlertChannels(opsAlerts, billingAlerts);
if (channels.length === 0) {
  console.error("FAIL: no verifiable email/SMS channels found in ops/billing alert policies.");
  process.exit(1);
}

console.log(JSON.stringify({ project: PROJECT, runId, channels }, null, 2));

let triggerResult = { ok: true, skipped: true };
if (!args.skipTrigger) {
  triggerResult = run("gcloud", [
    "logging",
    "write",
    "openburnbar-alert-delivery-drill",
    JSON.stringify({
      event: "alert_delivery_drill",
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

if (!args.confirmDelivered) {
  console.error("Canary triggered. Re-run with --confirm-delivered after the human endpoint receives it.");
  process.exit(2);
}
if (!args.operator.trim()) {
  console.error("FAIL: --operator is required when recording delivery evidence.");
  process.exit(2);
}

const evidence = {
  generatedAt: new Date().toISOString(),
  project: PROJECT,
  runId,
  canary: {
    logName: "openburnbar-alert-delivery-drill",
    event: "alert_delivery_drill",
    triggeredAt,
    triggerSkipped: args.skipTrigger,
  },
  channels: channels.map((channel) => ({
    name: channel.name,
    type: channel.type,
    target: channel.target,
    policyDisplayNames: channel.policyDisplayNames,
    deliveryConfirmed: true,
    deliveredAt: new Date().toISOString(),
    verifiedBy: args.operator.trim(),
    evidenceUri: args.evidenceUrl || undefined,
  })),
};

mkdirSync(dirname(OUTPUT), { recursive: true });
writeFileSync(OUTPUT, `${JSON.stringify(evidence, null, 2)}\n`);
const timestamped = join(
  dirname(OUTPUT),
  `alert-channel-verified-${triggeredAt.replace(/[:.]/g, "-")}.json`,
);
writeFileSync(timestamped, `${JSON.stringify(evidence, null, 2)}\n`);
console.log(JSON.stringify({ ok: true, output: OUTPUT, timestamped, triggerResult }, null, 2));
