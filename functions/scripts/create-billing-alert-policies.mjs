#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  BILLING_ALERT_POLICIES,
  materializeBillingAlertPolicy,
} from "./billing-alert-policy-definitions.mjs";

const project = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
if (!project) {
  console.error("Set GCLOUD_PROJECT or GOOGLE_CLOUD_PROJECT before creating alert policies.");
  process.exit(1);
}

const notificationChannels = (process.env.BILLING_ALERT_CHANNELS || "")
  .split(",")
  .map((entry) => entry.trim())
  .filter(Boolean);

if (notificationChannels.length === 0) {
  console.error("Set BILLING_ALERT_CHANNELS to one or more Monitoring notification channel IDs.");
  process.exit(1);
}

const tmp = mkdtempSync(join(tmpdir(), "openburnbar-alerts-"));

function listExistingPolicies() {
  const output = execFileSync(
    "gcloud",
    ["monitoring", "policies", "list", `--project=${project}`, "--format=json"],
    { encoding: "utf8" }
  );
  return JSON.parse(output || "[]");
}

try {
  const existingPolicies = listExistingPolicies();
  for (const policy of BILLING_ALERT_POLICIES) {
    const file = join(tmp, `${policy.displayName.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}.json`);
    writeFileSync(
      file,
      JSON.stringify(
        materializeBillingAlertPolicy(policy, notificationChannels),
        null,
        2
      )
    );
    const matches = existingPolicies.filter((entry) => entry.displayName === policy.displayName);
    if (matches.length > 1) {
      console.error(
        `Found ${matches.length} alert policies named "${policy.displayName}". Clean up duplicates before running this script.`
      );
      process.exitCode = 1;
      continue;
    }

    const existing = matches[0];
    const command = existing
      ? ["monitoring", "policies", "update", existing.name, `--project=${project}`, `--policy-from-file=${file}`, "--quiet"]
      : ["monitoring", "policies", "create", `--project=${project}`, `--policy-from-file=${file}`, "--quiet"];
    console.error(`${existing ? "Updating" : "Creating"} ${policy.displayName}`);
    execFileSync("gcloud", command, { stdio: "inherit" });
  }
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
