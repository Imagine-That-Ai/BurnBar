#!/usr/bin/env node
// Deploy-freshness monitor (diligence 2026-07-14 Ops §"no freshness detection").
//
// The company's signature failure — a 26-day silent production freeze (Cloud
// Functions frozen at 2026-06-18 while the fix sat merged-but-undeployed) —
// was undetectable because nothing checked whether prod was *recently*
// deployed. This script reads every ACTIVE gen2 Cloud Function plus the three
// independently deployed Cloud Run services: hosted MCP, the quota runner,
// and the OpenTimestamps verifier. Every surface is evaluated independently
// against a configurable threshold (default 14 days), and every live API read
// is attempted even when a sibling surface errors. A stale or unreadable
// surface fails the check; a fresh sibling can never mask it.
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
const cloudRunServices = [
  {
    surface: "hostedMcp",
    service:
      process.env.DEPLOY_FRESHNESS_HOSTED_MCP_SERVICE ||
      process.env.DEPLOY_FRESHNESS_CLOUD_RUN_SERVICE ||
      "openburnbar-hosted-mcp",
  },
  {
    surface: "quotaRunner",
    service:
      process.env.DEPLOY_FRESHNESS_QUOTA_RUNNER_SERVICE ||
      "openburnbar-quota-runner",
  },
  {
    surface: "otsVerifier",
    service:
      process.env.DEPLOY_FRESHNESS_OTS_VERIFIER_SERVICE ||
      "openburnbar-ots-verifier",
  },
];

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
async function fetchJson(url, token, surface) {
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) {
    // Do not echo the provider response body. It can contain operator or
    // project context that does not belong in public Actions logs/issues.
    throw new Error(
      `${surface} API returned ${res.status} ${res.statusText || "request failed"}`,
    );
  }
  return res.json();
}

async function fetchCloudFunctionsUpdateTime(token) {
  // Cloud Functions v2 API: the repo's functions are gen2
  // (firebase-functions/v2 — see functions/src/health.ts). Enumerate every
  // page so a stale function cannot disappear behind API pagination.
  const baseUrl =
    `https://cloudfunctions.googleapis.com/v2/projects/${project}/locations/${region}/functions`;
  const allFns = [];
  let pageToken = "";
  do {
    const params = new URLSearchParams({ pageSize: "1000" });
    if (pageToken) params.set("pageToken", pageToken);
    const data = await fetchJson(
      `${baseUrl}?${params.toString()}`,
      token,
      "cloudFunctions",
    );
    allFns.push(...(data.functions || []));
    pageToken = data.nextPageToken || "";
  } while (pageToken);

  if (allFns.length === 0) {
    throw new Error(`No Cloud Functions found in ${project}/${region}`);
  }
  const activeFns = allFns.filter((fn) => fn.state === "ACTIVE");
  if (activeFns.length === 0) {
    throw new Error(
      `No ACTIVE Cloud Functions in ${project}/${region}; ` +
        `all ${allFns.length} function(s) are non-serving`,
    );
  }
  return activeFns.map((fn) => ({
    kind: "cloudFunctions",
    name: fn.name,
    updateTime: fn.updateTime,
    state: fn.state,
  }));
}

async function fetchCloudRunUpdateTime(token, { surface, service }) {
  // Cloud Run API (v2): each service is an independent production surface.
  const url =
    `https://run.googleapis.com/v2/projects/${project}/locations/${region}/services/${service}`;
  const data = await fetchJson(url, token, surface);
  return {
    kind: surface,
    name: data.name || service,
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
 *   "cloudFunctions": [{ "name": ".../healthLive", "updateTime": "...", "state": "ACTIVE" }],
 *   "hostedMcp": { "name": ".../openburnbar-hosted-mcp", "updateTime": "..." },
 *   "quotaRunner": { "name": ".../openburnbar-quota-runner", "updateTime": "..." },
 *   "otsVerifier": { "name": ".../openburnbar-ots-verifier", "updateTime": "..." }
 * }
 *
 * `cloudRun` remains a backwards-compatible alias for `hostedMcp`. Fixtures
 * may intentionally omit surfaces to exercise one evaluator in isolation;
 * live mode always requires and attempts all four production surfaces.
 */
function loadFixture(fixturePath) {
  const raw = readFileSync(resolve(fixturePath), "utf8");
  const data = JSON.parse(raw);
  const surfaces = {
    cloudFunctions: [],
    hostedMcp: null,
    quotaRunner: null,
    otsVerifier: null,
    errors: [],
  };
  for (const fn of data.cloudFunctions || []) {
    surfaces.cloudFunctions.push({
      kind: "cloudFunctions",
      name: fn.name,
      updateTime: fn.updateTime,
      state: fn.state || "ACTIVE",
    });
  }
  for (const { surface } of cloudRunServices) {
    const entry = data[surface] || (surface === "hostedMcp" ? data.cloudRun : null);
    if (entry) {
      surfaces[surface] = {
        kind: surface,
        name: entry.name,
        updateTime: entry.updateTime,
      };
    }
  }
  for (const [surface, message] of Object.entries(data.errors || {})) {
    surfaces.errors.push({ surface, message: String(message) });
  }
  const hasEntry =
    surfaces.cloudFunctions.length > 0 ||
    cloudRunServices.some(({ surface }) => surfaces[surface]) ||
    surfaces.errors.length > 0;
  if (!hasEntry) {
    console.error("::error::Fixture contains no deploy freshness entries.");
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
 * - cloudFunctions: the oldest ACTIVE function is the weakest link.
 * - hostedMcp, quotaRunner, otsVerifier: each service has its own result.
 *
 * Parse/read errors are results, not omissions. They fail the whole gate while
 * preserving the other surfaces' independently collected evidence.
 */
function evaluateFreshness(surfaces, maxAgeDays, now) {
  const results = [];
  const errors = [...(surfaces.errors || [])];

  const record = (surface, entry) => {
    try {
      const age = ageDays(entry.updateTime, now);
      results.push({
        surface,
        entry: { ...entry, age },
        stale: age > maxAgeDays,
      });
    } catch (error) {
      errors.push({
        surface,
        message: error instanceof Error ? error.message : "unknown timestamp error",
      });
    }
  };

  if (surfaces.cloudFunctions.length > 0) {
    const active = surfaces.cloudFunctions.filter(
      (fn) => fn.state === "ACTIVE",
    );
    if (active.length === 0) {
      errors.push({
        surface: "cloudFunctions",
        message: "No ACTIVE Cloud Functions in the inspected fixture",
      });
    } else {
      let oldest = null;
      for (const fn of active) {
        try {
          const age = ageDays(fn.updateTime, now);
          if (!oldest || age > oldest.age) oldest = { ...fn, age };
        } catch (error) {
          errors.push({
            surface: "cloudFunctions",
            message: error instanceof Error ? error.message : "unknown timestamp error",
          });
        }
      }
      if (oldest) {
        results.push({
          surface: "cloudFunctions",
          entry: oldest,
          stale: oldest.age > maxAgeDays,
        });
      }
    }
  }

  for (const { surface } of cloudRunServices) {
    if (surfaces[surface]) record(surface, surfaces[surface]);
  }

  const staleSurfaces = results.filter((result) => result.stale);
  return {
    results,
    staleSurfaces,
    errors,
    anyStale: staleSurfaces.length > 0,
    anyError: errors.length > 0,
    maxAgeDays,
    now,
  };
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
  surfaces = {
    cloudFunctions: [],
    hostedMcp: null,
    quotaRunner: null,
    otsVerifier: null,
    errors: [],
  };
  const checks = await Promise.allSettled([
    fetchCloudFunctionsUpdateTime(token),
    ...cloudRunServices.map((service) => fetchCloudRunUpdateTime(token, service)),
  ]);
  const surfaceNames = [
    "cloudFunctions",
    ...cloudRunServices.map(({ surface }) => surface),
  ];
  for (let index = 0; index < checks.length; index += 1) {
    const result = checks[index];
    const surface = surfaceNames[index];
    if (result.status === "fulfilled") {
      if (surface === "cloudFunctions") surfaces.cloudFunctions = result.value;
      else surfaces[surface] = result.value;
    } else {
      surfaces.errors.push({
        surface,
        message:
          result.reason instanceof Error
            ? result.reason.message
            : "unknown provider API error",
      });
    }
  }
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

const { results, staleSurfaces, errors, anyStale, anyError } = evaluateFreshness(
  surfaces,
  maxAgeDays,
  now,
);

for (const result of results) {
  const ageStr = result.entry.age.toFixed(1);
  const status = result.stale ? "FAIL" : "OK";
  const tag = result.stale ? "::error::" : "";
  console.log(
    `${tag}Deploy freshness ${status} [${result.surface}]: ${ageStr} days old ` +
      `(threshold ${maxAgeDays}d). ${result.entry.name} updateTime=${result.entry.updateTime}.`,
  );
}
for (const error of errors) {
  console.error(
    `::error::Deploy freshness ERROR [${error.surface}]: ${error.message}.`,
  );
}

if (anyStale || anyError) {
  const failures = [
    ...staleSurfaces.map((result) => `${result.surface}:stale`),
    ...errors.map((error) => `${error.surface}:error`),
  ].join(", ");
  console.error(
    `::error::Deploy freshness FAIL: ${failures}. ` +
      `This is the 6/18 freeze signature — a merged fix sitting undeployed.`,
  );
  process.exit(1);
}

const allAges = results
  .map((result) => `${result.surface}=${result.entry.age.toFixed(1)}d`)
  .join(", ");
console.log(
  `Deploy freshness OK: all inspected surfaces within ${maxAgeDays}d threshold (${allAges}).`,
);