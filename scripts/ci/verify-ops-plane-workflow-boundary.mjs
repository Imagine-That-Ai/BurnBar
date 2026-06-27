#!/usr/bin/env node
/**
 * Static boundary gate for the production ops-plane verification workflow.
 *
 * The secret-availability detector must run inside the same protected
 * environment that owns the production GCP credential. Otherwise a repository
 * scoped detector can silently report the protected credential as absent and
 * skip the real verification lane.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT =
  process.env.OPS_PLANE_WORKFLOW_BOUNDARY_ROOT ??
  join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const WORKFLOW = join(ROOT, ".github", "workflows", "ops-plane-verify.yml");

const failures = [];
const fail = (message) => failures.push(message);

function readWorkflow() {
  if (!existsSync(WORKFLOW)) {
    fail(`missing workflow: ${WORKFLOW}`);
    return "";
  }
  return readFileSync(WORKFLOW, "utf8");
}

function beforeJobs(source) {
  const marker = /^jobs:\s*$/mu.exec(source);
  return marker ? source.slice(0, marker.index) : source;
}

function extractJobs(source) {
  const lines = source.split("\n");
  const jobs = new Map();
  let inJobs = false;
  let currentName = null;
  let currentLines = [];
  for (const line of lines) {
    if (!inJobs) {
      if (line === "jobs:") inJobs = true;
      continue;
    }
    const match = /^  ([A-Za-z0-9_-]+):\s*$/u.exec(line);
    if (match) {
      if (currentName) jobs.set(currentName, currentLines.join("\n"));
      currentName = match[1];
      currentLines = [line];
      continue;
    }
    if (currentName) currentLines.push(line);
  }
  if (currentName) jobs.set(currentName, currentLines.join("\n"));
  return jobs;
}

function hasLine(block, pattern) {
  return new RegExp(`^\\s*${pattern}\\s*$`, "mu").test(block);
}

function countMatches(source, pattern) {
  return Array.from(source.matchAll(new RegExp(pattern, "gu"))).length;
}

const source = readWorkflow();
if (source) {
  const top = beforeJobs(source);
  const jobs = extractJobs(source);
  const detect = jobs.get("detect-secrets") ?? "";
  const verify = jobs.get("verify") ?? "";
  const skipped = jobs.get("skipped-no-gcp-key") ?? "";

  if (/id-token:\s*write/u.test(top)) {
    fail("ops-plane workflow must not grant id-token:write at top level");
  }
  if (!/contents:\s*read/u.test(top)) {
    fail("ops-plane workflow must keep top-level contents:read");
  }

  if (!detect) fail("ops-plane workflow must define detect-secrets");
  if (!verify) fail("ops-plane workflow must define verify");
  if (!skipped) fail("ops-plane workflow must define skipped-no-gcp-key");

  if (detect) {
    if (!hasLine(detect, "environment:\\s*production")) {
      fail("detect-secrets must bind the production environment before probing production secrets");
    }
    if (!/GCP_SA_KEY:\s*\$\{\{\s*secrets\.GCP_SA_KEY\s*\}\}/u.test(detect)) {
      fail("detect-secrets must probe the production GCP_SA_KEY secret through the protected environment");
    }
    if (!/has-gcp-sa-key:\s*\$\{\{\s*steps\.detect\.outputs\.has-gcp-sa-key\s*\}\}/u.test(detect)) {
      fail("detect-secrets must expose has-gcp-sa-key from the detector step output");
    }
    if (/id-token:\s*write/u.test(detect)) {
      fail("detect-secrets must not receive id-token:write");
    }
  }

  if (verify) {
    if (!/needs:\s*detect-secrets/u.test(verify)) {
      fail("verify must depend on detect-secrets");
    }
    if (!/if:\s*needs\.detect-secrets\.outputs\.has-gcp-sa-key\s*==\s*'true'/u.test(verify)) {
      fail("verify must run only when detect-secrets reports the production GCP credential is available");
    }
    if (!hasLine(verify, "environment:\\s*production")) {
      fail("verify must bind the production environment");
    }
    if (!/permissions:[\s\S]*contents:\s*read[\s\S]*id-token:\s*write/u.test(verify)) {
      fail("verify must own job-level contents:read and id-token:write permissions");
    }
    if (!/credentials_json:\s*\$\{\{\s*secrets\.GCP_SA_KEY\s*\}\}/u.test(verify)) {
      fail("verify must authenticate with the same production GCP_SA_KEY secret checked by detect-secrets");
    }
  }

  if (skipped) {
    if (!/needs:\s*detect-secrets/u.test(skipped)) {
      fail("skipped-no-gcp-key must depend on detect-secrets");
    }
    if (!/if:\s*needs\.detect-secrets\.outputs\.has-gcp-sa-key\s*==\s*'false'/u.test(skipped)) {
      fail("skipped-no-gcp-key must run only when detect-secrets reports the credential is unavailable");
    }
    for (const marker of [
      '${{ github.event_name }}',
      "schedule",
      "exit 1",
      "production DR/governance verification could not run",
    ]) {
      if (!skipped.includes(marker)) {
        fail(`skipped-no-gcp-key is missing fail-closed marker ${marker}`);
      }
    }
  }

  if (countMatches(source, String.raw`\$\{\{\s*secrets\.GCP_SA_KEY\s*\}\}`) !== 2) {
    fail("GCP_SA_KEY must appear exactly in the protected detector and verify auth step");
  }
}

if (failures.length > 0) {
  console.error("Ops-plane workflow boundary verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("PASS: Ops-plane verification probes production secrets inside the protected environment.");
