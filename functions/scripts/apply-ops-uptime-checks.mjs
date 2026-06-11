#!/usr/bin/env node
/**
 * Idempotent upsert of public uptime checks used by the launch-gate alert policies.
 *
 * Prerequisites:
 *   - gcloud auth
 *   - GCLOUD_PROJECT or GOOGLE_CLOUD_PROJECT
 */
import { execFileSync } from "node:child_process";
import { OPS_UPTIME_CHECKS, materializeOpsUptimeCheck } from "./ops-uptime-check-definitions.mjs";

const project = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
if (!project) {
  console.error("Set GCLOUD_PROJECT or GOOGLE_CLOUD_PROJECT.");
  process.exit(1);
}

function accessToken() {
  return execFileSync("gcloud", ["auth", "print-access-token"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim();
}

async function monitoringRequest(path, token, options = {}) {
  const response = await fetch(`https://monitoring.googleapis.com/v3/${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(options.headers ?? {}),
    },
  });
  if (!response.ok) {
    throw new Error(`Monitoring API ${path} failed: ${response.status} ${await response.text()}`);
  }
  return response.status === 204 ? undefined : response.json();
}

const token = accessToken();
const parent = `projects/${project}`;
const existing = [];
let pageToken = "";
do {
  const query = pageToken ? `?pageToken=${encodeURIComponent(pageToken)}` : "";
  const page = await monitoringRequest(`${parent}/uptimeCheckConfigs${query}`, token);
  existing.push(...(Array.isArray(page.uptimeCheckConfigs) ? page.uptimeCheckConfigs : []));
  pageToken = typeof page.nextPageToken === "string" ? page.nextPageToken : "";
} while (pageToken);

for (const check of OPS_UPTIME_CHECKS) {
  const body = materializeOpsUptimeCheck(check, project);
  const matches = existing.filter((entry) => entry.displayName === check.displayName);
  if (matches.length > 1) {
    console.error(`Duplicate uptime checks: ${check.displayName}`);
    process.exitCode = 1;
    continue;
  }

  const match = matches[0];
  if (match?.name) {
    console.error(`Updating ${check.displayName}`);
    await monitoringRequest(
      `${match.name}?updateMask=displayName,monitoredResource,httpCheck,tcpCheck,period,timeout,contentMatchers,selectedRegions`,
      token,
      {
        method: "PATCH",
        body: JSON.stringify({ ...body, name: match.name }),
      },
    );
  } else {
    console.error(`Creating ${check.displayName}`);
    await monitoringRequest(`${parent}/uptimeCheckConfigs`, token, {
      method: "POST",
      body: JSON.stringify(body),
    });
  }
}
