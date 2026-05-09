#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

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

const policies = [
  {
    displayName: "OpenBurnBar Firestore read spike",
    documentation: {
      content:
        "Firestore document reads are the first scaling cost signal. Inspect scheduled rollups, searchStreams, and mobile dashboard polling before raising thresholds.",
      mimeType: "text/markdown",
    },
    combiner: "OR",
    conditions: [
      {
        displayName: "Firestore reads exceed 50k/min",
        conditionThreshold: {
          filter:
            'resource.type="firestore_database" AND metric.type="firestore.googleapis.com/document/read_count"',
          aggregations: [
            {
              alignmentPeriod: "60s",
              perSeriesAligner: "ALIGN_RATE",
              crossSeriesReducer: "REDUCE_SUM",
            },
          ],
          comparison: "COMPARISON_GT",
          thresholdValue: 50000,
          duration: "300s",
          trigger: { count: 1 },
        },
      },
    ],
  },
  {
    displayName: "OpenBurnBar storage growth",
    documentation: {
      content:
        "Storage growth usually means large backup bodies are leaking into Firestore or Cloud Storage retention is too loose. Check session log manifests, chunks, and object lifecycle rules.",
      mimeType: "text/markdown",
    },
    combiner: "OR",
    conditions: [
      {
        displayName: "Firestore storage exceeds 50 GiB",
        conditionThreshold: {
          filter:
            'resource.type="firestore_database" AND metric.type="firestore.googleapis.com/storage/bytes_used"',
          aggregations: [
            {
              alignmentPeriod: "3600s",
              perSeriesAligner: "ALIGN_MEAN",
              crossSeriesReducer: "REDUCE_SUM",
            },
          ],
          comparison: "COMPARISON_GT",
          thresholdValue: 53687091200,
          duration: "3600s",
          trigger: { count: 1 },
        },
      },
    ],
  },
  {
    displayName: "OpenBurnBar relay spend proxy",
    documentation: {
      content:
        "Cloud Run and Redis are the relay cost centers. This policy catches sustained relay request volume before it becomes a billing surprise.",
      mimeType: "text/markdown",
    },
    combiner: "OR",
    conditions: [
      {
        displayName: "Cloud Run request rate exceeds 1k/min",
        conditionThreshold: {
          filter:
            'resource.type="cloud_run_revision" AND metric.type="run.googleapis.com/request_count"',
          aggregations: [
            {
              alignmentPeriod: "60s",
              perSeriesAligner: "ALIGN_RATE",
              crossSeriesReducer: "REDUCE_SUM",
            },
          ],
          comparison: "COMPARISON_GT",
          thresholdValue: 1000,
          duration: "300s",
          trigger: { count: 1 },
        },
      },
    ],
  },
];

try {
  for (const policy of policies) {
    const file = join(tmp, `${policy.displayName.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}.json`);
    writeFileSync(
      file,
      JSON.stringify(
        {
          ...policy,
          enabled: true,
          notificationChannels,
          alertStrategy: { autoClose: "604800s" },
        },
        null,
        2
      )
    );
    execFileSync(
      "gcloud",
      ["monitoring", "policies", "create", `--project=${project}`, `--policy-from-file=${file}`],
      { stdio: "inherit" }
    );
  }
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
