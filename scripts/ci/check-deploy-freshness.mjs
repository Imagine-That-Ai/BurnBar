#!/usr/bin/env node
// Deploy-freshness monitor (diligence 2026-07-14 Ops §"no freshness detection").
//
// The company's signature failure — a 26-day silent production freeze (Cloud
// Functions frozen at 2026-06-18 while the fix sat merged-but-undeployed) —
// was undetectable because nothing checked whether prod was *recently*
// deployed. This script reads the live `updateTime` of every ACTIVE Cloud
// Function (v2 API — the repo's functions are gen2/firebase-functions/v2)
// and the Cloud Run hosted-MCP service, then checks each deploy surface
// INDEPENDENTLY against a configurable threshold (default 14 days). A single
// stale surface fails the check even if another surface is fresh — that's
// the whole point, since Cloud Functions and Cloud Run deploy in separate
// workflows and a fresh Cloud Run must not mask a frozen Functions plane.
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
  // Cloud Functions v2 API: the repo's functions are gen2
  // (firebase-functions/v2 — see functions/src/health.ts). The v1 endpoint
  // returns no functions in a gen2-only project, so v2 is mandatory.
  const url =
    `https://cloudfunctions.googleapis.com/v2/projects/${project}/locations/${region}/functions`;
  const data = await fetchJson(url, token);
  const allFns = data.functions || [];
  if (allFns.length === 0) {
    console.error(
      `::error::No Cloud Functions found in ${project}/${region}. ` +
        `If this is expected, set DEPLOY_FRESHNESS_FIXTURE to skip the live check.`,
    );
    process.exit(1);
  }
  // Filter to ACTIVE functions only — a FAILED/DEPLOYING function with a
  // fresh updateTime must not mask a stale production surface.
  const activeFns = allFns.filter((fn) => fn.state === "ACTIVE");
  if (activeFns.length === 0) {
    console.error(
      `::error::No ACTIVE Cloud Functions in ${project}/${region}. ` +
        `All ${allFns.length} function(s) are in non-serving state — ` +
        `production may be serving old code or no code at all.`,
    );
    process.exit(1);
  }
  return activeFns.map((fn) => ({
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
 *   "now": "2026-07-14T12:00:00.000Z",
 *   "cloudFunctions": [
 *     { "name": "projects/.../functions/healthLive", "updateTime": "...", "state": "ACTIVE" },
 *     ...
 *   ],
 *   "cloudRun": {
 *     "name": "projects/.../services/openburnbar-hosted-mcp",
 *     "updateTime": "..."
 *   }
 * }
 *
 * `cloudFunctions` or `cloudRun` may be omitted to test a single surface.
 * `state` on cloudFunctions entries defaults to "ACTIVE" if absent.
 */
function loadFixture(fixturePath) {
  const raw = readFileSync(resolve(fixturePath), "utf8");
  const data = JSON.parse(raw);
  const surfaces = { cloudFunctions: [], cloudRun: null };
  for (const fn of data.cloudFunctions || []) {
    surfaces.cloudFunctions.push({
      kind: "cloudFunctions",
      name: fn.name,
      updateTime: fn.updateTime,
      state: fn.state || "ACTIVE",
    });
  }
  if (data.cloudRun) {
    surfaces.cloudRun = {
      kind: "cloudRun",
      name: data.cloudRun.name,
      updateTime: data.cloudRun.updateTime,
    };
  }
  if (surfaces.cloudFunctions.length === 0 && !surfaces.cloudRun) {
    console.error("::error::Fixture contains no updateTime entries.");
    process.exit(1);
  }
  return surfaces;
}

// ---------------------------------------------------------------------------
// Core freshness logic — per-surface, not global newest
// ---------------------------------------------------------------------------
function ageDays(updateTime, now) {
  const ts = new Date(updateTime).getTime();
  if (Number.isNaN(ts)) {
    throw new Error(`Unparseable updateTime: "${updateTime}"`);
  }
  return (now - ts) / (1000 * 60 * 60 * 24);
}

/**
 * Evaluate freshness per independent deploy surface.
 *
 * - cloudFunctions surface: the OLDEST active function's age (the weakest link).
 *   A single frozen function fails the whole surface — that's the 6/18 freeze
 *   pattern (healthLive/healthReady stuck while Cloud Run was fresh).
 * - cloudRun surface: the single service's age.
 *
 * Each surface is checked independently: if EITHER is stale, the check fails.
 * This prevents a fresh Cloud Run deploy from masking a stale Functions plane.
 */
function evaluateFreshness(surfaces, maxAgeDays, now) {
  const results = [];

  // Cloud Functions surface — check oldest active function
  if (surfaces.cloudFunctions.length > 0) {
    // Filter to ACTIVE only (fixture may carry non-active entries)
    const active = surfaces.cloudFunctions.filter(
      (fn) => fn.state === "ACTIVE",
    );
    if (active.length > 0) {
      let oldest = null;
      for (const fn of active) {
        const age = ageDays(fn.updateTime, now);
        if (!oldest || age > oldest.age) {
          oldest = { ...fn, age };
        }
      }
      results.push({
        surface: "cloudFunctions",
        entry: oldest,
        stale: oldest.age > maxAgeDays,
      });
    }
  }

  // Cloud Run surface
  if (surfaces.cloudRun) {
    const age = ageDays(surfaces.cloudRun.updateTime, now);
    results.push({
      surface: "cloudRun",
      entry: { ...surfaces.cloudRun, age },
      stale: age > maxAgeDays,
    });
  }

  const staleSurfaces = results.filter((r) => r.stale);
  const anyStale = staleSurfaces.length > 0;
  return { results, staleSurfaces, anyStale, maxAgeDays, now };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
const maxAgeDays = parseMaxAgeDays();
const fixturePath = process.env.DEPLOY_FRESHNESS_FIXTURE;

let surfaces;
if (fixturePath) {
  surfaces = loadFixture(fixturePath);
} else {
  const token = accessToken();
  const fnEntries = await fetchCloudFunctionsUpdateTime(token);
  // Cloud Run is a required production surface — fail closed on any read
  // failure (404, 403, 5xx) rather than silently disabling the check.
  const crEntry = await fetchCloudRunUpdateTime(token);
  surfaces = {
    cloudFunctions: fnEntries,
    cloudRun: crEntry,
  };
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

const { results, staleSurfaces, anyStale } = evaluateFreshness(
  surfaces,
  maxAgeDays,
  now,
);

// Report each surface
for (const r of results) {
  const ageStr = r.entry.age.toFixed(1);
  const status = r.stale ? "FAIL" : "OK";
  const tag = r.stale ? "::error::" : "";
  console.log(
    `${tag}Deploy freshness ${status} [${r.surface}]: ${ageStr} days old ` +
      `(threshold ${maxAgeDays}d). ${r.entry.name} updateTime=${r.entry.updateTime}.`,
  );
}

if (anyStale) {
  const surfaceNames = staleSurfaces.map((r) => r.surface).join(", ");
  console.error(
    `::error::Deploy freshness FAIL: stale surface(s): ${surfaceNames}. ` +
      `This is the 6/18 freeze signature — a merged fix sitting undeployed.`,
  );
  process.exit(1);
}

const allAges = results.map((r) => `${r.surface}=${r.entry.age.toFixed(1)}d`).join(", ");
console.log(
  `Deploy freshness OK: all surfaces within ${maxAgeDays}d threshold (${allAges}).`,
);