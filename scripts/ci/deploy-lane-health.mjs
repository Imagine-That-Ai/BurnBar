#!/usr/bin/env node

import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { classifyFailure } = require("../../.github/actions/ops-failure-issue/escalation.cjs");

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const DEFAULT_OUTPUT = path.join(repositoryRoot, "ci/deploy-lane-health.json");
const GITHUB_API_DEFAULT = "https://api.github.com";
const DEFAULT_LIMIT = 10;

export const DEPLOY_LANES = Object.freeze([
  Object.freeze({
    lane: "deploy-production",
    workflow: "deploy-production.yml",
    label: "Production Cloud Functions",
    healthUrls: ["functionsReady", "functionsLive"],
    healthExpectations: {
      functionsReady: { status: "ready" },
      functionsLive: { status: "alive" },
    },
  }),
  Object.freeze({
    lane: "deploy-cloud-run",
    workflow: "deploy-cloud-run.yml",
    label: "Production hosted MCP Cloud Run",
    healthUrls: ["cloudRunReady"],
    healthExpectations: {
      cloudRunReady: { ok: true },
    },
  }),
]);

function parseArguments(argv) {
  const values = {
    out: DEFAULT_OUTPUT,
    fixture: process.env.DEPLOY_LANE_HEALTH_FIXTURE || null,
    apiBase: process.env.GITHUB_API_URL || GITHUB_API_DEFAULT,
    repo: process.env.GITHUB_REPOSITORY || null,
    token: process.env.GH_TOKEN || process.env.GITHUB_TOKEN || null,
    limit: DEFAULT_LIMIT,
    functionsReady: process.env.FUNCTIONS_HEALTH_READY_URL || "https://us-central1-burnbar.cloudfunctions.net/healthReady",
    functionsLive: process.env.FUNCTIONS_HEALTH_LIVE_URL || "https://us-central1-burnbar.cloudfunctions.net/healthLive",
    cloudRunReady: process.env.CLOUD_RUN_HEALTH_READY_URL || "https://mcp.burnbar.ai/readyz",
  };
  const supported = new Set([
    "--out",
    "--fixture",
    "--api-base",
    "--repo",
    "--limit",
    "--functions-ready",
    "--functions-live",
    "--cloud-run-ready",
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!supported.has(argument)) throw new Error(`unsupported argument ${argument}`);
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
    if (argument === "--functions-ready") values.functionsReady = value;
    if (argument === "--functions-live") values.functionsLive = value;
    if (argument === "--cloud-run-ready") values.cloudRunReady = value;
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

async function probeHealth(url, expectation = {}) {
  const startedAt = Date.now();
  try {
    const response = await fetch(url, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(15_000),
    });
    const body = await response.text();
    let parsed = null;
    try {
      parsed = body ? JSON.parse(body) : null;
    } catch {
      // The semantic expectation below intentionally fails closed when a
      // health endpoint returns a non-JSON or malformed response.
    }
    const semanticOk = Object.entries(expectation).every(([key, expected]) => (
      parsed?.[key] === expected
    ));
    return {
      url,
      statusCode: response.status,
      ok: response.ok && semanticOk,
      durationMs: Date.now() - startedAt,
      responseOk: response.ok,
      bodyOk: parsed?.ok ?? null,
      bodyStatus: parsed?.status ?? null,
    };
  } catch (error) {
    return {
      url,
      statusCode: null,
      ok: false,
      durationMs: Date.now() - startedAt,
      responseOk: false,
      bodyOk: null,
      error: String(error?.message || error).slice(0, 240),
    };
  }
}

function sortRuns(runs) {
  const timestamp = (run) => {
    const value = Date.parse(run?.created_at || run?.updated_at || "");
    return Number.isFinite(value) ? value : Number.POSITIVE_INFINITY;
  };
  return [...runs].sort((left, right) => (
    timestamp(right) - timestamp(left)
    || Number(right.id || 0) - Number(left.id || 0)
  ));
}

function isProductionRun(run) {
  if (!run || !["push", "workflow_dispatch"].includes(run.event)) return false;
  const descriptor = `${run.name || ""} ${run.display_title || ""}`.toLowerCase();
  return !descriptor.includes("dry-run") && !descriptor.includes("dry run");
}

function normalizeRun(run) {
  const conclusion = run?.conclusion || null;
  const runId = run?.id ?? null;
  const hasRunMetadata = Number.isSafeInteger(Number(runId))
    && Number(runId) > 0
    && String(run?.status).toLowerCase() === "completed"
    && Number.isFinite(Date.parse(run?.created_at || ""));
  const reasonCode = run?.reasonCode
    || run?.reason_code
    || (hasRunMetadata ? null : "run-metadata-missing");
  const classification = classifyFailure({
    status: run?.status,
    conclusion,
    reasonCode,
    skipped: conclusion === "skipped",
  });
  return {
    run_id: runId,
    run_attempt: run?.run_attempt ?? null,
    status: classification.classification === "healthy"
      ? "success"
      : classification.classification === "infra" ? "infra-failed" : "failed",
    conclusion: conclusion || "unknown",
    classification: classification.classification,
    failureClass: classification.failureClass,
    reasonCode: classification.reasonCode,
    created_at: run?.created_at || null,
    updated_at: run?.updated_at || null,
    url: run?.html_url || null,
    event: run?.event || null,
    head_sha: run?.head_sha || null,
  };
}

function latestProductionRun(rawRuns, limit) {
  const productionRuns = sortRuns(rawRuns.filter(isProductionRun)).slice(0, limit);
  const normalized = productionRuns.map(normalizeRun);
  let consecutiveRed = 0;
  for (const run of normalized) {
    if (run.classification === "healthy") break;
    consecutiveRed += 1;
  }
  return {
    latest: normalized[0] || {
      run_id: null,
      run_attempt: null,
      status: "infra-failed",
      conclusion: "unknown",
      classification: "infra",
      failureClass: "infra",
      reasonCode: "no-production-deploy-run",
      created_at: null,
      updated_at: null,
      url: null,
      event: null,
      head_sha: null,
    },
    runs: normalized,
    consecutive_red: consecutiveRed || (normalized[0]?.classification !== "healthy" ? 1 : 0),
  };
}

function fixtureRunsForLane(fixture, definition) {
  if (Array.isArray(fixture?.lanes)) {
    const row = fixture.lanes.find((candidate) => (
      candidate?.lane === definition.lane || candidate?.workflow === definition.workflow
    ));
    return row?.runs || row?.workflow_runs || [];
  }
  const row = fixture?.lanes?.[definition.lane]
    || fixture?.lanes?.[definition.workflow]
    || fixture?.[definition.lane]
    || fixture?.[definition.workflow];
  return Array.isArray(row) ? row : row?.runs || row?.workflow_runs || [];
}

function fixtureProbe(fixture, key, fallbackUrl) {
  const value = fixture?.probes?.[key];
  if (!value) return { url: fallbackUrl, ok: false, statusCode: null, error: "missing-probe-fixture" };
  return {
    url: value.url || fallbackUrl,
    ok: value.ok === true,
    statusCode: value.statusCode ?? null,
    durationMs: value.durationMs ?? 0,
    responseOk: value.responseOk ?? value.ok === true,
    bodyOk: value.bodyOk ?? null,
    ...(value.error ? { error: String(value.error).slice(0, 240) } : {}),
  };
}

function laneReport(definition, runHistory, probes) {
  const probeRed = probes.some((probe) => !probe.ok);
  const latest = runHistory.latest;
  const deployRed = latest.classification !== "healthy";
  const red = deployRed || probeRed;
  const probeOnlyRed = !deployRed && probeRed;
  const classification = deployRed
    ? latest.classification
    : probeRed ? "infra" : "healthy";
  const reasonCode = deployRed
    ? latest.reasonCode
    : probeRed ? (probes.find((probe) => !probe.ok)?.error ? "health-probe-error" : "health-check-failed") : null;
  return {
    lane: definition.lane,
    workflow: definition.workflow,
    label: definition.label,
    status: red ? (probeOnlyRed ? "infra-failed" : latest.status) : "success",
    conclusion: red
      ? (probeOnlyRed || latest.conclusion === "success" ? "health-check-failed" : latest.conclusion)
      : "success",
    classification,
    failureClass: red ? (classification === "infra" ? "infra" : latest.failureClass) : null,
    reasonCode,
    red,
    consecutive_red: red ? Math.max(1, runHistory.consecutive_red) : 0,
    run_id: latest.run_id,
    run_attempt: latest.run_attempt,
    url: latest.url,
    created_at: latest.created_at,
    updated_at: latest.updated_at,
    probes,
    runs: runHistory.runs,
  };
}

function markdownSummary(report) {
  const lines = [
    "## Deploy lane health",
    "",
    `Status: **${report.status.toUpperCase()}**`,
    "",
    "| Lane | Latest deploy | Health probes | Consecutive red |",
    "| --- | --- | --- | ---: |",
  ];
  for (const lane of report.lanes) {
    const probeStatus = lane.probes.every((probe) => probe.ok) ? "green" : "red";
    lines.push(
      `| \`${lane.lane}\` | \`${lane.conclusion}\` | \`${probeStatus}\` | ${lane.consecutive_red} |`,
    );
  }
  if (report.blockers.length > 0) {
    lines.push("", `Blockers: ${report.blockers.map((blocker) => `\`${blocker}\``).join(", ")}`);
  }
  lines.push(
    "",
    "Automated path: red opens/updates the deploy-health issue and remains non-zero.",
    "Human queue path: assign a release owner, record the blocker and expiry, then use the approved main-only release control; do not rerun a tag workflow blindly.",
  );
  if (report.source.mode === "offline-fixture") {
    lines.push("", "> Offline fixture mode: no GitHub token was used; this is not a live-green claim.");
  }
  return `${lines.join("\n")}\n`;
}

function buildReport(lanes, source, generatedAt, blockers = []) {
  const laneBlockers = lanes
    .filter((lane) => lane.red && lane.reasonCode)
    .map((lane) => `${lane.lane}:${lane.reasonCode}`);
  return {
    schemaVersion: 1,
    generatedAt,
    status: lanes.some((lane) => lane.red) ? "red" : "green",
    source,
    lanes,
    blockers: [...new Set([...blockers, ...laneBlockers])],
    human_queue: {
      required_on_red: true,
      owner: "release owner",
      exit_path: "record named blocker and expiry, then use approved main-only release control",
    },
    markdown: "",
  };
}

async function loadFixture(fixturePath) {
  if (!fixturePath) return { generatedAt: new Date().toISOString(), lanes: [], probes: {} };
  return JSON.parse(await readFile(fixturePath, "utf8"));
}

async function collectLive(options) {
  const lanes = [];
  const blockers = [];
  for (const definition of DEPLOY_LANES) {
    let runHistory;
    try {
      // Fetch the maximum bounded page before filtering dry runs. A burst of
      // manual dry-runs must not hide the latest real tag deploy outside the
      // first `limit` raw results.
      const rawRunPageSize = "100";
      const query = new URLSearchParams({ event: "push", per_page: rawRunPageSize });
      const response = await requestJson(
        `${options.apiBase}/repos/${options.repo}/actions/workflows/${encodeURIComponent(definition.workflow)}/runs?${query}`,
        options.token,
      );
      if (!Array.isArray(response?.workflow_runs)) {
        throw new Error(`no workflow_runs array for ${definition.workflow}`);
      }
      // A tag push is the ordinary real deploy path. A manually approved
      // existing-tag retry is queried separately because GitHub's workflow-run
      // list cannot filter its input payload.
      const dispatchQuery = new URLSearchParams({ event: "workflow_dispatch", per_page: rawRunPageSize });
      const dispatchResponse = await requestJson(
        `${options.apiBase}/repos/${options.repo}/actions/workflows/${encodeURIComponent(definition.workflow)}/runs?${dispatchQuery}`,
        options.token,
      );
      const dispatchRuns = Array.isArray(dispatchResponse?.workflow_runs)
        ? dispatchResponse.workflow_runs
        : [];
      runHistory = latestProductionRun([...response.workflow_runs, ...dispatchRuns], options.limit);
    } catch (error) {
      runHistory = latestProductionRun([], options.limit);
      runHistory.latest = {
        ...runHistory.latest,
        status: "infra-failed",
        conclusion: "infra-failed",
        classification: "infra",
        failureClass: "infra",
        reasonCode: "github-api-error",
        observation_error: String(error?.message || error).slice(0, 240),
      };
      blockers.push(`${definition.lane}:github-api-error`);
    }
    const probeUrls = definition.healthUrls.map((key) => options[key]);
    const probes = await Promise.all(probeUrls.map((url, index) => (
      probeHealth(url, definition.healthExpectations[definition.healthUrls[index]])
    )));
    const report = laneReport(definition, runHistory, probes);
    lanes.push(report);
    if (report.red && report.reasonCode) blockers.push(`${definition.lane}:${report.reasonCode}`);
  }
  return { lanes, blockers };
}

export async function collectDeployLaneHealth(options) {
  const source = {
    mode: options.token ? "github" : "offline-fixture",
    api: "GitHub Actions workflow-runs + public deployment health probes",
    repository: options.repo || null,
    events: ["push", "workflow_dispatch"],
  };
  if (!options.token) {
    const fixture = await loadFixture(options.fixture);
    const lanes = DEPLOY_LANES.map((definition) => {
      const history = latestProductionRun(fixtureRunsForLane(fixture, definition), options.limit);
      const probes = definition.healthUrls.map((key) => fixtureProbe(fixture, key, options[key]));
      return laneReport(definition, history, probes);
    });
    const report = buildReport(
      lanes,
      { ...source, fixture: options.fixture || "built-in" },
      fixture.generatedAt || new Date().toISOString(),
      fixture.blockers || [],
    );
    report.markdown = markdownSummary(report);
    return report;
  }
  const live = await collectLive(options);
  const report = buildReport(live.lanes, source, new Date().toISOString(), live.blockers);
  report.markdown = markdownSummary(report);
  return report;
}

async function writeReport(outputPath, report) {
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  if (process.env.GITHUB_STEP_SUMMARY) {
    await writeFile(process.env.GITHUB_STEP_SUMMARY, report.markdown, { encoding: "utf8", flag: "a" });
  }
  if (process.env.GITHUB_OUTPUT) {
    await writeFile(
      process.env.GITHUB_OUTPUT,
      `status=${report.status}\nred=${report.status === "red"}\n` +
      `blockers=${report.blockers.join(",") || "none"}\n`,
      { encoding: "utf8", flag: "a" },
    );
  }
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  if (!options.token && !options.fixture) {
    process.stderr.write("GH_TOKEN unavailable; using the explicit offline fixture mode.\n");
  }
  const report = await collectDeployLaneHealth({
    ...options,
    repo: options.repo ? repositoryName(options.repo) : null,
  });
  await writeReport(options.out, report);
  process.stdout.write(report.markdown);
  if (report.status !== "green") process.exitCode = 1;
  return report;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await main();
  } catch (error) {
    process.stderr.write(`deploy-lane-health failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
