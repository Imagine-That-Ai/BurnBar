#!/usr/bin/env node
// Deploy-freshness monitor (diligence 2026-07-14 Ops §"no freshness detection").
//
// The company's signature failure — a 26-day silent production freeze (Cloud
// Functions frozen at 2026-06-18 while the fix sat merged-but-undeployed) —
// was undetectable because nothing checked whether prod was *recently*
// deployed. This script reads the live `updateTime` of every Cloud Function
// and the Cloud Run hosted-MCP service, picks the newest, and fails if it is
// older than a configurable threshold (default 14 days).
//
// Auth pattern: reuse `accessToken()` from check-firestore-deploy-drift.mjs —
// `GOOGLE_OAUTH_ACCESS_TOKEN` env first, then `gcloud auth print-access-token`.
//
// Test seam: set `DEPLOY_FRESHNESS_FIXTURE` to a JSON file path to inject
// mock `updateTime` timestamps instead of calling the live APIs. This is the
// only way to unit-test the age-comparison logic deterministically.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const project = process.env.FIREBASE_PROJECT || "burnbar";
const region = process.env.FUNCTIONS_REGION || "us-central1";
const cloudRunService =
  process.env.DEPLOY_FRESHNESS_CLOUD_RUN_SERVICE || "openburnbar-hosted-mcp";

const DEFAULT_MAX_AGE_DAYS = 14;

// ---------------------------------------------------------------------------
// Auth — identical to check-firestore-deploy-drift.mjs
// ---------------------------------------------------------------------------
function accessToken() {
  if (process.env.GOOGLE_OAUTH_ACCESS_TOKEN)
    return process.env.GOOGLE_OAUTH_ACCESS_TOKEN;
  return execFileSync("gcloud", ["auth", "print-access-token"], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim();
}

// ---------------------------------------------------------------------------
// Threshold parsing — positive integer only, no silent coercion
// ---------------------------------------------------------------------------
function parseMaxAgeDays() {
  const raw = process.env.DEPLOY_FRESHNESS_MAX_AGE_DAYS;
  if (raw === undefined || raw === "") return DEFAULT_MAX_AGE_DAYS;
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) {
    console.error(
      `::error::DEPLOY_FRESHNESS_MAX_AGE_DAYS must be a positive integer, got "${raw}".`,
    );
    process.exit(2);
  }
  return n;
}

// ---------------------------------------------------------------------------
// Live API calls
// ---------------------------------------------------------------------------
async function fetchJson(url, token) {
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(
      `API ${url} returned ${res.status} ${res.statusText}: ${body.slice(0, 500)}`,
    );
  }
  return res.json();
}

async function fetchCloudFunctionsUpdateTime(token) {
  // Cloud Functions API (v1): list all functions in the region.
  const url =
    `https://cloudfunctions.googleapis.com/v1/projects/${project}/locations/${region}/functions`;
  const data = await fetchJson(url, token);
  const fns = data.functions || [];
  if (fns.length === 0) {
    console.error(
      `::error::No Cloud Functions found in ${project}/${region}. ` +
        `If this is expected, set DEPLOY_FRESHNESS_FIXTURE to skip the live check.`,
    );
    process.exit(1);
  }
  return fns.map((fn) => ({
    kind: "cloudFunctions",
    name: fn.name,
    updateTime: fn.updateTime,
  }));
}

async function fetchCloudRunUpdateTime(token) {
  // Cloud Run API (v2): get the single hosted-MCP service.
  const url =
    `https://run.googleapis.com/v2/projects/${project}/locations/${region}/services/${cloudRunService}`;
  const data = await fetchJson(url, token);
  return {
    kind: "cloudRun",
    name: data.name,
    updateTime: data.updateTime,
  };
}

// ---------------------------------------------------------------------------
// Fixture seam — for deterministic testing
// ---------------------------------------------------------------------------
/**
 * Fixture format (JSON):
 * {
 *   "cloudFunctions": [
 *     { "name": "projects/.../functions/healthLive", "updateTime": "2026-07-14T10:00:00.000Z" },
 *     ...
 *   ],
 *   "cloudRun": {
 *     "name": "projects/.../services/openburnbar-hosted-mcp",
 *     "updateTime": "2026-07-14T10:00:00.000Z"
 *   }
 * }
 *
 * Any key may be omitted; the check considers all present timestamps.
 */
function loadFixture(fixturePath) {
  const raw = readFileSync(resolve(fixturePath), "utf8");
  const data = JSON.parse(raw);
  const entries = [];
  for (const fn of data.cloudFunctions || []) {
    entries.push({ kind: "cloudFunctions", name: fn.name, updateTime: fn.updateTime });
  }
  if (data.cloudRun) {
    entries.push({ kind: "cloudRun", name: data.cloudRun.name, updateTime: data.cloudRun.updateTime });
  }
  if (entries.length === 0) {
    console.error("::error::Fixture contains no updateTime entries.");
    process.exit(1);
  }
  return entries;
}

// ---------------------------------------------------------------------------
// Core freshness logic
// ---------------------------------------------------------------------------
function ageDays(updateTime, now) {
  const ts = new Date(updateTime).getTime();
  if (Number.isNaN(ts)) {
    throw new Error(`Unparseable updateTime: "${updateTime}"`);
  }
  return (now - ts) / (1000 * 60 * 60 * 24);
}

function evaluateFreshness(entries, maxAgeDays, now) {
  let newest = null;
  for (const entry of entries) {
    const age = ageDays(entry.updateTime, now);
    if (!newest || age < newest.age) {
      newest = { ...entry, age };
    }
  }
  const stale = newest.age > maxAgeDays;
  return { newest, stale, maxAgeDays, now };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
const maxAgeDays = parseMaxAgeDays();
const fixturePath = process.env.DEPLOY_FRESHNESS_FIXTURE;

let entries;
if (fixturePath) {
  entries = loadFixture(fixturePath);
} else {
  const token = accessToken();
  const fnEntries = await fetchCloudFunctionsUpdateTime(token);
  let crEntry;
  try {
    crEntry = await fetchCloudRunUpdateTime(token);
  } catch (err) {
    // Cloud Run service may not exist in every project/region. A missing
    // service is a warning, not a hard failure — the functions check alone
    // is sufficient to catch a freeze.
    console.warn(`::warn::Cloud Run service ${cloudRunService} not reachable: ${err.message}`);
  }
  entries = [...fnEntries];
  if (crEntry) entries.push(crEntry);
}

// Use a fixed `now` when testing with a fixture so the age comparison is
// deterministic. The fixture file may carry an optional `now` field.
const now = fixturePath
  ? (() => {
      try {
        const data = JSON.parse(readFileSync(resolve(fixturePath), "utf8"));
        if (data.now) return new Date(data.now).getTime();
      } catch { /* fall through */ }
      return Date.now();
    })()
  : Date.now();

const { newest, stale } = evaluateFreshness(entries, maxAgeDays, now);

const ageStr = newest.age.toFixed(1);
if (stale) {
  console.error(
    `::error::Deploy freshness FAIL: newest prod deploy is ${ageStr} days old ` +
      `(threshold ${maxAgeDays}d). ${newest.kind} ${newest.name} updateTime=${newest.updateTime}. ` +
      `This is the 6/18 freeze signature — a merged fix sitting undeployed.`,
  );
  process.exit(1);
}

console.log(
  `Deploy freshness OK: newest prod deploy is ${ageStr} days old ` +
    `(threshold ${maxAgeDays}d). ${newest.kind} ${newest.name} updateTime=${newest.updateTime}.`,
);