#!/usr/bin/env node

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { classifyFailure } = require("../../.github/actions/ops-failure-issue/escalation.cjs");

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "../..");
const DEFAULT_OUTPUT = path.join(repositoryRoot, "ci/nightly-health.json");
const DEFAULT_LIMIT = 8;
const SCHEDULED_RUN_MAX_AGE_MS = 36 * 60 * 60 * 1000;
const GITHUB_API_DEFAULT = "https://api.github.com";

/**
 * These are the five scheduled full-confidence product lanes named by the
 * remediation validators, plus the scheduled repair operator. DAST is an
 * isolated security sandbox and deploy-production is the companion
 * deploy-lane-health report; neither is silently folded into this six-lane
 * trend. The six entries are intentionally stable machine keys.
 */
export const NIGHTLY_LANES = Object.freeze([
  Object.freeze({
    lane: "openburnbar-pr-harness",
    workflow: "openburnbar-pr-harness.yml",
    label: "OpenBurnBar Full Harness",
  }),
  Object.freeze({
    lane: "app-pr-gate",
    workflow: "app-pr-gate.yml",
    label: "App PR Gate",
  }),
  Object.freeze({
    lane: "nightly-e2e",
    workflow: "nightly-e2e.yml",
    label: "OpenBurnBar Nightly E2E",
  }),
  Object.freeze({
    lane: "codeql",
    workflow: "codeql.yml",
    label: "CodeQL",
  }),
  Object.freeze({
    lane: "linux-nightly",
    workflow: "linux-nightly.yml",
    label: "Linux Nightly Matrix",
  }),
  Object.freeze({
    lane: "codex-nightly-ci-repair",
    workflow: "codex-nightly-ci-repair.yml",
    label: "Codex Nightly CI Repair",
  }),
]);

function parseArguments(argv) {
  const values = {
    out: DEFAULT_OUTPUT,
    fixture: process.env.NIGHTLY_HEALTH_FIXTURE || null,
    apiBase: process.env.GITHUB_API_URL || GITHUB_API_DEFAULT,
    repo: process.env.GITHUB_REPOSITORY || null,
    token: process.env.GH_TOKEN || process.env.GITHUB_TOKEN || null,
    limit: DEFAULT_LIMIT,
    deployLaneHealth: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!["--out", "--fixture", "--api-base", "--repo", "--limit", "--deploy-lane-health"].includes(argument)) {
      throw new Error(`unsupported argument ${argument}`);
    }
    if (index + 1 >= argv.length) throw new Error(`${argument} requires a value`);
    const value = argv[index + 1];
    index += 1;
    if (argument === "--out") values.out = path.resolve(value);
    if (argument === "--fixture") values.fixture = path.resolve(value);
    if (argument === "--api-base") values.apiBase = value.replace(/\/+$/u, "");
    if (argument === "--repo") values.repo = value;
    if (argument === "--limit") {
      values.limit = Number.parseInt(value, 10);
      if (!Number.isInteger(values.limit) || values.limit < 1 || values.limit > 100) {
        throw new Error("--limit must be an integer between 1 and 100");
      }
    }
    if (argument === "--deploy-lane-health") values.deployLaneHealth = path.resolve(value);
  }
  return values;
}

function repositoryName(repo) {
  if (!repo || !/^[^/]+\/[^/]+$/u.test(repo)) {
    throw new Error("GITHUB_REPOSITORY or --repo must be owner/repository");
  }
  return repo;
}

async function requestJson(url, token) {
  const response = await fetch(url, {
    headers: {
      Accept: "application/vnd.github+json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      "X-GitHub-Api-Version": "2022-11-28",
    },
    signal: AbortSignal.timeout(30_000),
  });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`GitHub API returned ${response.status} for ${url}: ${body.slice(0, 240)}`);
  }
  try {
    return body ? JSON.parse(body) : null;
  } catch (error) {
    throw new Error(`GitHub API returned invalid JSON for ${url}: ${error.message}`);
  }
}

function workflowRunsUrl(apiBase, repo, workflow, limit) {
  const query = new URLSearchParams({
    branch: "main",
    event: "schedule",
    per_page: String(limit),
  });
  return `${apiBase}/repos/${repo}/actions/workflows/${encodeURIComponent(workflow)}/runs?${query}`;
}

function checkRunsUrl(apiBase, repo, sha, limit = 100) {
  const query = new URLSearchParams({ per_page: String(limit) });
  return `${apiBase}/repos/${repo}/commits/${encodeURIComponent(sha)}/check-runs?${query}`;
}

function workflowJobsUrl(apiBase, repo, runId, limit = 100) {
  const query = new URLSearchParams({ per_page: String(limit) });
  return `${apiBase}/repos/${repo}/actions/runs/${encodeURIComponent(runId)}/jobs?${query}`;
}

function parseReasonCode(value) {
  const text = String(value || "");
  const match = text.match(/\breason[_-]?Code\s*[:=]\s*`?([a-z0-9][a-z0-9-]*)/iu);
  return match?.[1] || null;
}

function checkRunMetadata(checkRuns) {
  if (!Array.isArray(checkRuns)) return { reasonCode: null, status: null };
  for (const check of checkRuns) {
    if (check?.conclusion === "skipped") {
      return { reasonCode: "job-skipped", status: "skipped" };
    }
    const text = [
      check?.name,
      check?.output?.title,
      check?.output?.summary,
      check?.output?.text,
    ].filter(Boolean).join("\n");
    const reasonCode = parseReasonCode(text);
    const statusMatch = text.match(/\bstatus\s*[:=]\s*`?(infra-failed|failed|passed)/iu);
    if (reasonCode || statusMatch) {
      return {
        reasonCode,
        status: statusMatch?.[1]?.toLowerCase() || null,
      };
    }
  }
  return { reasonCode: null, status: null };
}

function jobMetadata(jobs) {
  if (!Array.isArray(jobs)) return { reasonCode: null, status: null };
  if (jobs.length === 0) {
    return {
      reasonCode: "job-metadata-missing",
      status: "infra-failed",
      conclusion: "unknown",
      jobName: null,
    };
  }
  const missingStatus = jobs.find((job) => !job?.status);
  if (missingStatus) {
    return {
      reasonCode: "job-metadata-missing",
      status: "infra-failed",
      conclusion: "unknown",
      jobName: missingStatus.name || null,
    };
  }
  const skipped = jobs.find((job) => job?.conclusion === "skipped");
  if (skipped) {
    return {
      reasonCode: "job-skipped",
      status: "skipped",
      conclusion: "skipped",
      jobName: skipped.name || null,
    };
  }
  const incomplete = jobs.find((job) => (
    job?.status && job.status !== "completed"
  ));
  if (incomplete) {
    return {
      reasonCode: "job-incomplete",
      status: "action_required",
      conclusion: "action_required",
      jobName: incomplete.name || null,
    };
  }
  const cancelled = jobs.find((job) => job?.conclusion === "cancelled");
  if (cancelled) {
    return {
      reasonCode: "job-cancelled",
      status: "cancelled",
      conclusion: "cancelled",
      jobName: cancelled.name || null,
    };
  }
  const timedOut = jobs.find((job) => job?.conclusion === "timed_out");
  if (timedOut) {
    return {
      reasonCode: "job-timed-out",
      status: "timed_out",
      conclusion: "timed_out",
      jobName: timedOut.name || null,
    };
  }
  const neutral = jobs.find((job) => job?.conclusion === "neutral");
  if (neutral) {
    return {
      reasonCode: "job-neutral",
      status: "neutral",
      conclusion: "neutral",
      jobName: neutral.name || null,
    };
  }
  const missingConclusion = jobs.find((job) => (
    String(job?.status).toLowerCase() === "completed" && !job?.conclusion
  ));
  if (missingConclusion) {
    return {
      reasonCode: "job-conclusion-missing",
      status: "infra-failed",
      conclusion: "unknown",
      jobName: missingConclusion.name || null,
    };
  }
  const unknown = jobs.find((job) => (
    job?.conclusion
    && !["success", "neutral", "skipped", "failure", "cancelled", "timed_out"].includes(job.conclusion)
  ));
  if (unknown) {
    return {
      reasonCode: "job-unknown-conclusion",
      status: "infra-failed",
      conclusion: "unknown",
      jobName: unknown.name || null,
    };
  }
  const failed = jobs.find((job) => job?.conclusion === "failure");
  if (failed) {
    return {
      reasonCode: "job-failed",
      status: "failure",
      conclusion: "failure",
      jobName: failed.name || null,
    };
  }
  return { reasonCode: null, status: null };
}

function normalizeRun(raw, checkMetadata = {}) {
  const status = raw?.status || null;
  const runId = raw?.id ?? raw?.databaseId ?? raw?.run_id ?? null;
  const createdAt = raw?.created_at || raw?.createdAt || null;
  const headSha = raw?.head_sha || raw?.headSha || null;
  const hasRunMetadata = Number.isSafeInteger(Number(runId))
    && Number(runId) > 0
    && String(status).toLowerCase() === "completed"
    && Number.isFinite(Date.parse(createdAt || ""))
    && typeof headSha === "string"
    && headSha.length > 0;
  const conclusion = checkMetadata.conclusion && raw?.conclusion === "success"
    ? checkMetadata.conclusion
    : raw?.conclusion || (
      checkMetadata.status === "infra-failed" ? "infra-failed" : null
    );
  const reasonCode = raw?.reasonCode
    || raw?.reason_code
    || checkMetadata.reasonCode
    || (hasRunMetadata ? null : "run-metadata-missing")
    || null;
  const classification = classifyFailure({
    status: checkMetadata.status || status,
    conclusion,
    reasonCode,
    skipped: conclusion === "skipped",
  });
  const healthy = classification.classification === "healthy";
  return {
    id: raw?.id ?? raw?.databaseId ?? null,
    run_id: raw?.run_id ?? raw?.id ?? raw?.databaseId ?? null,
    run_attempt: raw?.run_attempt ?? raw?.runAttempt ?? null,
    status: healthy ? "success" : classification.classification === "infra" ? "infra-failed" : "failed",
    run_status: status,
    conclusion: conclusion || "unknown",
    classification: classification.classification,
    failureClass: classification.failureClass,
    reasonCode: reasonCode || classification.reasonCode,
    red: !healthy,
    created_at: raw?.created_at || raw?.createdAt || null,
    updated_at: raw?.updated_at || raw?.updatedAt || null,
    url: raw?.html_url || raw?.url || null,
    head_sha: raw?.head_sha || raw?.headSha || null,
  };
}

function sortRuns(runs) {
  const timestamp = (run) => {
    const value = Date.parse(run?.created_at || run?.createdAt || run?.updated_at || run?.updatedAt || "");
    return Number.isFinite(value) ? value : Number.POSITIVE_INFINITY;
  };
  return [...runs].sort((left, right) => (
    timestamp(right) - timestamp(left)
    || Number(right.run_id || right.id || right.databaseId || 0)
      - Number(left.run_id || left.id || left.databaseId || 0)
  ));
}

function markStaleScheduledRun(run, observedAt) {
  if (!run || !Number.isFinite(observedAt)) return run;
  const createdAt = Date.parse(run.created_at || "");
  if (!Number.isFinite(createdAt) || observedAt - createdAt <= SCHEDULED_RUN_MAX_AGE_MS) {
    return run;
  }
  return {
    ...run,
    status: "infra-failed",
    conclusion: "infra-failed",
    classification: "infra",
    failureClass: "infra",
    reasonCode: "scheduled-run-stale",
    red: true,
  };
}

export function buildLaneHealth(
  laneDefinition,
  rawRuns,
  checkMetadataByRun = {},
  limit = DEFAULT_LIMIT,
  { observedAt = null } = {},
) {
  const runs = sortRuns(Array.isArray(rawRuns) ? rawRuns : [])
    .slice(0, limit)
    .map((run) => normalizeRun(
      run,
      checkMetadataByRun[run?.id ?? run?.databaseId ?? run?.run_id] || {},
    ))
    .map((run, index) => index === 0 ? markStaleScheduledRun(run, observedAt) : run);
  let consecutiveRed = 0;
  for (const run of runs) {
    if (!run.red) break;
    consecutiveRed += 1;
  }
  const latest = runs[0] || normalizeRun({
    status: "infra-failed",
    conclusion: "unknown",
    reasonCode: "no-scheduled-run",
  });
  return {
    lane: laneDefinition.lane,
    workflow: laneDefinition.workflow,
    label: laneDefinition.label,
    run_id: latest.run_id,
    run_attempt: latest.run_attempt,
    status: latest.status,
    conclusion: latest.conclusion,
    classification: latest.classification,
    failureClass: latest.failureClass,
    reasonCode: latest.reasonCode,
    red: latest.red,
    consecutive_red: consecutiveRed || (latest.red ? 1 : 0),
    observed_runs: runs.length,
    last_green_run_id: runs.find((run) => !run.red)?.run_id ?? null,
    last_green_at: runs.find((run) => !run.red)?.created_at ?? null,
    created_at: latest.created_at,
    updated_at: latest.updated_at,
    url: latest.url,
    runs,
  };
}

function fixtureRunsForLane(fixture, laneDefinition) {
  if (Array.isArray(fixture?.lanes)) {
    const row = fixture.lanes.find((candidate) => (
      candidate?.lane === laneDefinition.lane || candidate?.workflow === laneDefinition.workflow
    ));
    return row?.runs || row?.workflow_runs || [];
  }
  if (fixture?.lanes && typeof fixture.lanes === "object") {
    const row = fixture.lanes[laneDefinition.lane] || fixture.lanes[laneDefinition.workflow];
    return Array.isArray(row) ? row : row?.runs || row?.workflow_runs || [];
  }
  const row = fixture?.[laneDefinition.lane] || fixture?.[laneDefinition.workflow];
  return Array.isArray(row) ? row : row?.runs || row?.workflow_runs || [];
}

function builtInFixture() {
  return {
    mode: "offline-fixture",
    generatedAt: "2026-09-01T00:00:00.000Z",
    lanes: NIGHTLY_LANES.map((lane) => ({
      lane: lane.lane,
      runs: [{
        id: null,
        status: "infra-failed",
        conclusion: "infra-failed",
        reasonCode: "offline-fixture",
        created_at: "2026-09-01T00:00:00.000Z",
      }],
    })),
  };
}

async function loadFixture(fixturePath) {
  if (!fixturePath) return builtInFixture();
  return JSON.parse(await readFile(fixturePath, "utf8"));
}

async function fetchLaneRuns(options, laneDefinition) {
  const runsResponse = await requestJson(
    workflowRunsUrl(options.apiBase, options.repo, laneDefinition.workflow, options.limit),
    options.token,
  );
  if (!Array.isArray(runsResponse?.workflow_runs)) {
    throw new Error(`Checks API returned no workflow_runs array for ${laneDefinition.workflow}`);
  }
  const runs = runsResponse.workflow_runs.filter((run) => (
    run?.head_branch === "main" || run?.head_branch == null
  ));
  const checkMetadataByRun = {};
  const latest = sortRuns(runs)[0];
  // The workflow-run endpoint supplies lifecycle/conclusion truth. The
  // Checks API is queried for the latest SHA to carry an explicit
  // infra-failed/reasonCode emitted by a producer when one exists.
  if (latest?.head_sha && latest?.id) {
    const checksResponse = await requestJson(
      checkRunsUrl(options.apiBase, options.repo, latest.head_sha),
      options.token,
    );
    if (!Array.isArray(checksResponse?.check_runs)) {
      throw new Error(`Checks API returned no check_runs array for ${laneDefinition.workflow}`);
    }
    const checksMetadata = checkRunMetadata(checksResponse?.check_runs);
    const jobsResponse = await requestJson(
      workflowJobsUrl(options.apiBase, options.repo, latest.id),
      options.token,
    );
    if (!Array.isArray(jobsResponse?.jobs)) {
      throw new Error(`Actions API returned no jobs array for ${laneDefinition.workflow}`);
    }
    const jobsMetadata = jobMetadata(jobsResponse?.jobs);
    // Checks are keyed by commit SHA, not workflow-run ID, so a successful
    // workflow run must not be overturned by an unrelated check from another
    // workflow on the same commit. The workflow-jobs response is run-scoped
    // and remains authoritative for skipped/incomplete jobs.
    const scopedChecksMetadata = latest.conclusion === "success"
      ? {}
      : checksMetadata;
    checkMetadataByRun[latest.id] = {
      ...(scopedChecksMetadata.status ? scopedChecksMetadata : {}),
      ...(jobsMetadata.status ? jobsMetadata : {}),
      reasonCode: jobsMetadata.reasonCode || scopedChecksMetadata.reasonCode || null,
      status: jobsMetadata.status || scopedChecksMetadata.status || null,
      conclusion: jobsMetadata.conclusion || scopedChecksMetadata.status || null,
    };
  }
  return buildLaneHealth(
    laneDefinition,
    runs,
    checkMetadataByRun,
    options.limit,
    { observedAt: options.observedAt },
  );
}

function markdownSummary(report) {
  const redLanes = report.lanes.filter((lane) => lane.red);
  const lines = [
    "## Nightly health",
    "",
    `Status: **${report.status.toUpperCase()}**`,
    "",
    "| Lane | Latest conclusion | Class | Consecutive red | Run |",
    "| --- | --- | --- | ---: | --- |",
  ];
  for (const lane of report.lanes) {
    const run = lane.url ? `[${lane.run_id ?? "missing"}](${lane.url})` : String(lane.run_id ?? "missing");
    lines.push(
      `| \`${lane.lane}\` | \`${lane.conclusion}\` | \`${lane.failureClass ?? "healthy"}\` | ${lane.consecutive_red} | ${run} |`,
    );
  }
  if (report.deployLaneHealth) {
    lines.push(
      "",
      `Deploy companion: **${report.deployLaneHealth.status.toUpperCase()}** `
        + `(${report.deployLaneHealth.consecutive_red} consecutive red)`,
    );
  }
  if (redLanes.length > 0) {
    lines.push("", `Red lanes: ${redLanes.map((lane) => `\`${lane.lane}\``).join(", ")}`);
  }
  if (report.source.mode === "offline-fixture") {
    lines.push("", "> Offline fixture mode: no GitHub token was available; this is not a live-green claim.");
  }
  return `${lines.join("\n")}\n`;
}

function normalizeDeployCompanion(value) {
  if (!value || typeof value !== "object") return null;
  const runs = Array.isArray(value.runs) ? value.runs : [];
  const lanes = Array.isArray(value.lanes) ? value.lanes : [];
  const invalidLaneData = lanes.length !== 2 || lanes.some((lane) => (
    lane?.red !== false
    || lane?.status !== "success"
    || lane?.classification !== "healthy"
    || lane?.failureClass !== null
    || !Number.isSafeInteger(Number(lane?.run_id))
    || Number(lane.run_id) <= 0
    || !Array.isArray(lane?.runs)
    || lane.runs.length === 0
    || !Array.isArray(lane?.probes)
    || lane.probes.length === 0
    || lane.probes.some((probe) => probe?.ok !== true)
  ));
  const red = value.status === "red" || value.status === "infra-failed"
    || runs.some((run) => run?.red === true || run?.conclusion !== "success")
    || invalidLaneData;
  return {
    status: red ? "red" : "green",
    consecutive_red: Number.isInteger(value.consecutive_red)
      ? value.consecutive_red
      : (red ? 1 : 0),
    run_id: value.latest?.run_id ?? runs[0]?.run_id ?? null,
    reasonCode: value.reasonCode
      ?? (invalidLaneData ? "deploy-health-companion-invalid" : red ? "deploy-health-companion-red" : null),
  };
}

export function buildHealthReport(lanes, {
  source = { mode: "fixture" },
  deployLaneHealth = null,
  generatedAt = new Date().toISOString(),
} = {}) {
  assert.equal(lanes.length, NIGHTLY_LANES.length, "nightly health must contain exactly six lanes");
  assert.deepEqual(
    lanes.map((lane) => lane.lane),
    NIGHTLY_LANES.map((lane) => lane.lane),
    "nightly health lane order must remain stable",
  );
  const normalizedDeploy = normalizeDeployCompanion(deployLaneHealth);
  const redLanes = lanes.filter((lane) => lane.red);
  const deployRed = normalizedDeploy?.status === "red";
  const report = {
    schemaVersion: 1,
    generatedAt,
    status: redLanes.length > 0 || deployRed ? "red" : "green",
    source,
    lanes,
    red_lanes: redLanes.map((lane) => lane.lane),
    deployLaneHealth: normalizedDeploy,
    seven_day_repage: {
      policy: "ops-failure-issue escalation.cjs",
      threshold_hours: 168,
      label: "repage:7d",
    },
  };
  return { ...report, markdown: markdownSummary(report) };
}

async function writeReport(outputPath, report) {
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  const summaryPath = process.env.GITHUB_STEP_SUMMARY;
  if (summaryPath) await writeFile(summaryPath, report.markdown, { encoding: "utf8", flag: "a" });
  if (process.env.GITHUB_OUTPUT) {
    await writeFile(
      process.env.GITHUB_OUTPUT,
      [
        `status=${report.status}`,
        `red=${report.status === "red"}`,
        `red_lanes=${report.red_lanes.join(",") || "none"}`,
      ].join("\n") + "\n",
      { encoding: "utf8", flag: "a" },
    );
  }
}

export async function collectNightlyHealth(options) {
  const live = Boolean(options.token);
  const source = {
    mode: live ? "github" : "offline-fixture",
    api: "GitHub Actions workflow-runs + Checks API + workflow jobs",
    repository: options.repo || null,
    ref: "main",
    window_runs: options.limit,
  };
  if (!live) {
    const fixture = await loadFixture(options.fixture);
    const fixtureObservedAt = Date.parse(fixture?.generatedAt || "");
    const lanes = NIGHTLY_LANES.map((lane) => buildLaneHealth(
      lane,
      fixtureRunsForLane(fixture, lane),
      fixture?.checkMetadataByRun || {},
      options.limit,
      { observedAt: Number.isFinite(fixtureObservedAt) ? fixtureObservedAt : null },
    ));
    return buildHealthReport(lanes, {
      source: { ...source, fixture: options.fixture || "built-in" },
      deployLaneHealth: fixture?.deployLaneHealth || null,
      generatedAt: fixture?.generatedAt || new Date().toISOString(),
    });
  }
  const observedAt = Number.isFinite(options.observedAt) ? options.observedAt : Date.now();
  const lanes = await Promise.all(NIGHTLY_LANES.map(async (lane) => {
    try {
      return await fetchLaneRuns({ ...options, observedAt }, lane);
    } catch (error) {
      const unavailable = buildLaneHealth(lane, [], {}, options.limit);
      return {
        ...unavailable,
        status: "infra-failed",
        conclusion: "infra-failed",
        classification: "infra",
        failureClass: "infra",
        reasonCode: "github-api-error",
        red: true,
        consecutive_red: 1,
        observation_error: String(error?.message || error).slice(0, 240),
      };
    }
  }));
  let deployLaneHealth = null;
  if (options.deployLaneHealth) {
    try {
      deployLaneHealth = JSON.parse(await readFile(options.deployLaneHealth, "utf8"));
    } catch (error) {
      throw new Error(`unable to read deploy lane-health companion: ${error.message}`);
    }
  }
  return buildHealthReport(lanes, { source, deployLaneHealth });
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  if (!options.token && !options.fixture) {
    process.stderr.write("GH_TOKEN unavailable; using the explicit offline fixture mode.\n");
  }
  const report = await collectNightlyHealth({
    ...options,
    repo: options.repo ? repositoryName(options.repo) : null,
  });
  await writeReport(options.out, report);
  process.stdout.write(report.markdown);
  return report;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const report = await main();
    if (report.status !== "green") process.exitCode = 1;
  } catch (error) {
    process.stderr.write(`nightly-health failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
