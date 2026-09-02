#!/usr/bin/env node

import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const PASSING = new Set(["success", "neutral", "skipped"]);
const WORKFLOW_PASSING = new Set(["success", "neutral"]);
// Cancelled is intentionally NOT a hard failure during the poll loop.
// Merge-queue and concurrency cancellations routinely supersede a check run
// before its replacement is registered; treating cancelled as terminal after a
// short grace ejected healthy merge-group candidates (e.g. PR #2154) while
// AgentLens/macOS jobs were still queued. Cancelled stays pending until a
// non-cancelled terminal result arrives or the overall evaluator deadline
// expires (fail-closed at timeout).
const FAILING = new Set([
  "failure",
  "timed_out",
  "action_required",
  "startup_failure",
  "stale",
]);

export const MAIN_APP_PR_GATE_WORKFLOW = "app-pr-gate.yml";
export const MAIN_APP_GATE_JOB = "App build + test (AgentLens)";
export const MAIN_APP_LANE_JOB =
  "AgentLens Rust + Swift build/test prerequisites";
export const MAIN_MOBILE_GATE_JOB = "Mobile build + unit test";
export const CI_FREEZE_OVERRIDE_LABEL = "ci-freeze-override";
export const CI_FREEZE_OVERRIDE_ACTOR = "Ajnunezg";
export const CI_FREEZE_OVERRIDE_ACTOR_ID = 125839313;
export const MAIN_RED_CIRCUIT_BREAKER = "main-red-circuit-breaker";

export function resolveObservedSha(environment = process.env) {
  return environment.BURNBAR_CI_SHA || environment.GITHUB_SHA;
}

export function resolveBaseSha(environment = process.env) {
  return (
    environment.BURNBAR_BASE_SHA ||
    environment.GITHUB_BASE_SHA ||
    environment.GITHUB_SHA
  );
}

function githubApiUrl(repository, path) {
  return `https://api.github.com/repos/${repository}/${path}`;
}

function sortNewestFirst(values) {
  return [...values].sort((left, right) => {
    const leftTime = Date.parse(
      left.created_at ?? left.updated_at ?? left.run_started_at ?? "",
    );
    const rightTime = Date.parse(
      right.created_at ?? right.updated_at ?? right.run_started_at ?? "",
    );
    return (
      (Number.isFinite(rightTime) ? rightTime : 0) -
        (Number.isFinite(leftTime) ? leftTime : 0) ||
      Number(right.id ?? 0) - Number(left.id ?? 0)
    );
  });
}

function isCompletedJob(job) {
  return job?.status === "completed" && job?.conclusion != null;
}

function isRunJobSuccessful(job) {
  return isCompletedJob(job) && PASSING.has(job.conclusion);
}

function jobByName(jobs, name) {
  return jobs.find((job) => job?.name === name) ?? null;
}

function jobActuallyRan(job) {
  return isCompletedJob(job) && job.conclusion !== "skipped";
}

function jobIsFailed(job) {
  return jobActuallyRan(job) && !isRunJobSuccessful(job);
}

export function classifyAppGateRun(run, jobs) {
  if (run?.status !== "completed") {
    return {
      present: false,
      reason: "workflow run did not complete",
    };
  }

  const appAggregate = jobByName(jobs, MAIN_APP_GATE_JOB);
  const mobile = jobByName(jobs, MAIN_MOBILE_GATE_JOB);
  const appLane = jobByName(jobs, MAIN_APP_LANE_JOB);
  const requiredJobs = [
    ["App build + test (AgentLens)", appAggregate],
    ["Mobile build + unit test", mobile],
  ];

  // The aggregate job always runs with `if: always()`, including when the
  // classifier skips both macOS lanes. Require the two named jobs to have
  // actually completed and, when the underlying app lane is present in the
  // API response, require that lane too. This makes a skipped classifier
  // success a missing verdict rather than a green one without making fixture
  // or GitHub API shape differences authoritative.
  if (appLane) requiredJobs.push([MAIN_APP_LANE_JOB, appLane]);
  const missing = requiredJobs
    .filter(([, job]) => !job)
    .map(([name]) => name);
  const skippedOrIncomplete = requiredJobs
    .filter(([, job]) => job && !jobActuallyRan(job))
    .map(([name]) => name);
  if (missing.length > 0 || skippedOrIncomplete.length > 0) {
    return {
      present: false,
      reason:
        missing.length > 0
          ? `missing jobs: ${missing.join(", ")}`
          : `required jobs did not actually run: ${skippedOrIncomplete.join(", ")}`,
      run,
      jobs: requiredJobs.map(([name, job]) => ({
        name,
        status: job?.status ?? null,
        conclusion: job?.conclusion ?? null,
      })),
    };
  }

  const failed = requiredJobs
    .filter(([, job]) => jobIsFailed(job))
    .map(([name, job]) => ({
      name,
      conclusion: job.conclusion,
      url: job.html_url ?? job.url ?? null,
    }));
  if (
    failed.length === 0 &&
    run.conclusion != null &&
    !WORKFLOW_PASSING.has(run.conclusion)
  ) {
    failed.push({
      name: "app-pr-gate workflow run",
      conclusion: run.conclusion,
      url: run.html_url ?? run.url ?? null,
    });
  }
  return {
    present: true,
    conclusion: failed.length > 0 ? "failure" : "success",
    failed,
    run,
    jobs: requiredJobs.map(([name, job]) => ({
      name,
      status: job.status,
      conclusion: job.conclusion,
      url: job.html_url ?? job.url ?? null,
    })),
  };
}

export async function resolveMainMergeBase(
  repository,
  baseSha,
  token,
  options = {},
) {
  if (!repository || !baseSha) {
    throw new Error("repository and base SHA are required to resolve main");
  }
  const fetchJson = options.fetchJson ?? githubJson;
  const comparison = await fetchJson(
    githubApiUrl(repository, `compare/${baseSha}...main`),
    token,
  );
  const mergeBaseSha = comparison?.merge_base_commit?.sha ?? null;
  if (!mergeBaseSha) {
    throw new Error(
      `GitHub compare response did not contain a merge-base for ${baseSha} and main`,
    );
  }
  return mergeBaseSha;
}

export async function listMainCommitsBackwards(
  repository,
  mergeBaseSha,
  token,
  options = {},
) {
  const fetchJson = options.fetchJson ?? githubJson;
  const pageSize = options.pageSize ?? 100;
  const commits = [];
  for (let page = 1; ; page += 1) {
    const payload = await fetchJson(
      `${githubApiUrl(repository, `commits?sha=main`)}&per_page=${pageSize}&page=${page}`,
      token,
    );
    const batch = Array.isArray(payload) ? payload : [];
    commits.push(...batch);
    const found = batch.some((commit) => commit?.sha === mergeBaseSha);
    if (found) {
      const index = commits.findIndex((commit) => commit?.sha === mergeBaseSha);
      return {
        mergeBaseSha,
        commits: commits.slice(0, index + 1),
        commitShas: new Set(
          commits
            .slice(0, index + 1)
            .map((commit) => commit?.sha)
            .filter(Boolean),
        ),
      };
    }
    if (batch.length < pageSize) break;
  }
  return {
    mergeBaseSha,
    commits: [],
    commitShas: new Set(),
  };
}

export async function listMainAppGateRuns(
  repository,
  token,
  options = {},
) {
  const fetchJson = options.fetchJson ?? githubJson;
  const workflow = options.workflow ?? MAIN_APP_PR_GATE_WORKFLOW;
  const events = options.events ?? ["push", "schedule"];
  const runs = [];
  for (const event of events) {
    const batch = await githubPages(
      githubApiUrl(
        repository,
        `actions/workflows/${workflow}/runs?branch=main&event=${event}`,
      ),
      "workflow_runs",
      token,
      fetchJson,
    );
    runs.push(...batch);
  }
  const unique = new Map();
  for (const run of runs) {
    if (run?.id != null) unique.set(String(run.id), run);
  }
  return sortNewestFirst([...unique.values()]);
}

export async function listRunJobs(repository, runId, token, options = {}) {
  const fetchJson = options.fetchJson ?? githubJson;
  return githubPages(
    githubApiUrl(repository, `actions/runs/${runId}/jobs?filter=latest`),
    "jobs",
    token,
    fetchJson,
  );
}

export async function resolveMainAppGateVerdict({
  repository,
  baseSha,
  token,
  options = {},
}) {
  const fetchJson = options.fetchJson ?? githubJson;
  const mergeBaseSha = await resolveMainMergeBase(
    repository,
    baseSha,
    token,
    { fetchJson },
  );
  const history = await listMainCommitsBackwards(
    repository,
    mergeBaseSha,
    token,
    { fetchJson },
  );
  if (history.commitShas.size === 0) {
    return {
      present: false,
      reason: `merge-base ${mergeBaseSha} was not found in main history`,
      mergeBaseSha,
    };
  }

  let runs = await listMainAppGateRuns(repository, token, {
    fetchJson,
    workflow: options.workflow,
  });
  if (options.asOf) {
    const asOfMs = Date.parse(options.asOf);
    if (Number.isFinite(asOfMs)) {
      runs = runs.filter((run) => {
        const createdMs = Date.parse(run.created_at ?? "");
        return !Number.isFinite(createdMs) || createdMs <= asOfMs;
      });
    }
  }

  const eligibleRuns = runs.filter(
    (run) =>
      run?.status === "completed" &&
      history.commitShas.has(run.head_sha ?? ""),
  );
  const rejectedRuns = [];
  for (const run of eligibleRuns) {
    let jobs;
    try {
      jobs = await listRunJobs(repository, run.id, token, { fetchJson });
    } catch (error) {
      // A completed run without readable job evidence is not a verdict. Keep
      // walking backwards instead of trusting its aggregate conclusion.
      rejectedRuns.push({
        run,
        reason: `jobs unreadable: ${error.message}`,
      });
      continue;
    }
    const classification = classifyAppGateRun(run, jobs);
    if (classification.present) {
      return {
        ...classification,
        mergeBaseSha,
        rejectedRuns,
      };
    }
    rejectedRuns.push({ run, reason: classification.reason });
  }
  return {
    present: false,
    reason: "no completed app/mobile run with both lanes actually executed",
    mergeBaseSha,
    rejectedRuns,
  };
}

function readMergeGroupHeadRef(environment = process.env) {
  const eventPath = environment.GITHUB_EVENT_PATH;
  if (eventPath) {
    try {
      const event = JSON.parse(readFileSync(eventPath, "utf8"));
      const headRef = event?.merge_group?.head_ref;
      if (headRef) return headRef;
    } catch {
      // Fall through to the environment-only test/legacy path.
    }
  }
  if (
    environment.BURNBAR_HEAD_REF &&
    (!environment.GITHUB_EVENT_NAME ||
      environment.GITHUB_EVENT_NAME === "merge_group")
  ) {
    return environment.BURNBAR_HEAD_REF;
  }
  return environment.GITHUB_EVENT_NAME === "merge_group"
    ? environment.GITHUB_HEAD_REF || null
    : null;
}

export function parseQueuePullRequestNumber(headRef) {
  // merge_group.head_ref arrives both bare and as a fully qualified
  // refs/heads/... ref (the deletion guard resolver accepts both too).
  const match =
    /^(?:refs\/heads\/)?gh-readonly-queue\/main\/pr-(\d+)-[^/]+$/u.exec(
      headRef ?? "",
    );
  return match ? Number(match[1]) : null;
}

function positiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : null;
}

// The override label is read from the PR timeline, so the gate needs the PR
// number on every trigger that can carry an override: the merge queue (from
// the queue head ref) and pull_request / pull_request_target (from the event
// payload, or BURNBAR_PR_NUMBER when the payload is unavailable).
export function resolvePullRequestNumber(environment = process.env) {
  const fromQueue = parseQueuePullRequestNumber(
    readMergeGroupHeadRef(environment),
  );
  if (fromQueue !== null) return fromQueue;
  const eventPath = environment.GITHUB_EVENT_PATH;
  if (eventPath) {
    try {
      const event = JSON.parse(readFileSync(eventPath, "utf8"));
      const fromEvent = positiveInteger(event?.pull_request?.number);
      if (fromEvent !== null) return fromEvent;
    } catch {
      // Fall through to the environment-only path.
    }
  }
  return positiveInteger(environment.BURNBAR_PR_NUMBER);
}

function timelineActor(event) {
  return event?.actor ?? event?.user ?? null;
}

export function selectValidFreezeOverride(
  timeline,
  {
    label = CI_FREEZE_OVERRIDE_LABEL,
    overrideActors = [CI_FREEZE_OVERRIDE_ACTOR],
  } = {},
) {
  const allowed = new Set(overrideActors);
  if (!allowed.has(CI_FREEZE_OVERRIDE_ACTOR)) return null;
  const events = [...(Array.isArray(timeline) ? timeline : [])].sort(
    (left, right) => {
      const leftTime = Date.parse(left.created_at ?? "");
      const rightTime = Date.parse(right.created_at ?? "");
      return (
        (Number.isFinite(leftTime) ? leftTime : 0) -
          (Number.isFinite(rightTime) ? rightTime : 0) ||
        Number(left.id ?? 0) - Number(right.id ?? 0)
      );
    },
  );
  let valid = null;
  for (const event of events) {
    if (event?.label?.name !== label) continue;
    if (event.event === "unlabeled") {
      valid = null;
      continue;
    }
    if (event.event !== "labeled") continue;
    const actor = timelineActor(event);
    if (
      actor?.login === CI_FREEZE_OVERRIDE_ACTOR &&
      Number(actor.id) === CI_FREEZE_OVERRIDE_ACTOR_ID &&
      event.id != null &&
      event.created_at
    ) {
      valid = {
        actor: actor.login,
        actorId: Number(actor.id),
        eventId: event.id ?? null,
        timestamp: event.created_at ?? null,
        label,
      };
    } else {
      // An unauthorized labeling event never grants an override. It also
      // clears an earlier valid event if it is the latest label operation.
      valid = null;
    }
  }
  return valid;
}

export async function findFreezeOverride(
  repository,
  pullRequestNumber,
  token,
  options = {},
) {
  if (!pullRequestNumber) return null;
  const fetchJson = options.fetchJson ?? githubJson;
  const timeline = await githubArrayPages(
    githubApiUrl(repository, `issues/${pullRequestNumber}/timeline`),
    token,
    fetchJson,
  );
  return selectValidFreezeOverride(timeline, {
    overrideActors: options.overrideActors,
  });
}

function parseReplayWindow(value) {
  const match = /^(\d+)([dhm])$/u.exec(value ?? "");
  if (!match) {
    throw new Error(
      `--replay-window must be a positive duration such as 30d, got "${value}"`,
    );
  }
  const amount = Number(match[1]);
  if (!Number.isSafeInteger(amount) || amount <= 0) {
    throw new Error(`--replay-window must be positive, got "${value}"`);
  }
  const multiplier = { m: 60_000, h: 3_600_000, d: 86_400_000 }[match[2]];
  return amount * multiplier;
}

export function parseCliArguments(argv) {
  let configPath = "governance/burnbar-ci-gate.json";
  let replayWindow = null;
  let reportPath = null;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--replay-window") {
      replayWindow = argv[++index];
      if (!replayWindow) throw new Error("--replay-window requires a value");
    } else if (argument.startsWith("--replay-window=")) {
      replayWindow = argument.slice("--replay-window=".length);
    } else if (argument === "--report") {
      reportPath = argv[++index];
      if (!reportPath) throw new Error("--report requires a path");
    } else if (argument.startsWith("--report=")) {
      reportPath = argument.slice("--report=".length);
    } else if (argument.startsWith("--")) {
      throw new Error(`unknown option: ${argument}`);
    } else if (configPath === "governance/burnbar-ci-gate.json") {
      configPath = argument;
    } else {
      throw new Error(`unexpected positional argument: ${argument}`);
    }
  }
  return { configPath, replayWindow, reportPath };
}

export async function measureVerdictAvailability({
  repository,
  token,
  replayWindow,
  now = Date.now(),
  options = {},
}) {
  const windowMs = parseReplayWindow(replayWindow);
  const fetchJson = options.fetchJson ?? githubJson;
  const cutoff = now - windowMs;
  const runs = await listMainAppGateRuns(repository, token, {
    fetchJson,
    workflow: options.workflow,
  });
  const samples = [];
  for (const run of runs) {
    const createdMs = Date.parse(run.created_at ?? "");
    if (Number.isFinite(createdMs) && createdMs < cutoff) continue;
    let verdict = null;
    let error = null;
    if (run.status === "completed") {
      try {
        const jobs = await listRunJobs(repository, run.id, token, { fetchJson });
        verdict = classifyAppGateRun(run, jobs);
      } catch (caught) {
        error = caught instanceof Error ? caught.message : String(caught);
      }
    } else {
      verdict = {
        present: false,
        reason: `workflow run status is ${run.status ?? "unknown"}`,
      };
    }
    samples.push({
      runId: run.id ?? null,
      headSha: run.head_sha ?? null,
      event: run.event ?? null,
      createdAt: run.created_at ?? null,
      present: verdict?.present === true,
      ...(verdict?.reason ? { reason: verdict.reason } : {}),
      ...(error ? { reason: `jobs unreadable: ${error}` } : {}),
    });
  }
  const presentCount = samples.filter((sample) => sample.present).length;
  return {
    window: replayWindow,
    generatedAt: new Date(now).toISOString(),
    samples: samples.length,
    presentCount,
    verdictPresentRate:
      samples.length > 0 ? presentCount / samples.length : null,
    runs: samples,
  };
}

function summaryPath(environment = process.env) {
  return environment.GITHUB_STEP_SUMMARY || null;
}

function annotationValue(value) {
  return String(value)
    .replaceAll("%", "%25")
    .replaceAll("\r", "%0D")
    .replaceAll("\n", "%0A");
}

export function appendGateSummary(line, environment = process.env) {
  const path = summaryPath(environment);
  if (!path) return;
  appendFileSync(path, `${line.trimEnd()}\n`);
}

export function formatBreakerSummary(verdict, mode) {
  const base = verdict.mergeBaseSha
    ? ` merge-base=${verdict.mergeBaseSha}`
    : "";
  const reason = verdict.reason
    ? `\n- **Reason:** ${verdict.reason.replaceAll("\r", " ").replaceAll("\n", " ")}`
    : "";
  if (!verdict.present) {
    return `### Main-red circuit breaker (${mode})\n\n- **Verdict:** no completed app/mobile verdict${base}; missing verdict passes in ${mode} mode.${reason}`;
  }
  const run = verdict.run?.id != null ? ` run=${verdict.run.id}` : "";
  return `### Main-red circuit breaker (${mode})\n\n- **Verdict:** ${verdict.conclusion}${run}${base}.`;
}

export function evaluateMainRedCircuitBreaker(
  verdict,
  {
    mode = "observe",
    override = null,
  } = {},
) {
  if (!verdict?.present) {
    return { pass: true, status: "missing", override: null };
  }
  if (verdict.conclusion !== "failure") {
    return { pass: true, status: "passed", override: null };
  }
  if (mode === "observe") {
    return { pass: true, status: "failed_observed", override: null };
  }
  if (override) {
    return { pass: true, status: "overridden", override };
  }
  return {
    pass: false,
    status: "failed",
    blocker: MAIN_RED_CIRCUIT_BREAKER,
    override: null,
  };
}

export function emitMainRedCircuitBreaker(
  verdict,
  result,
  mode,
  environment = process.env,
) {
  const summary = formatBreakerSummary(verdict, mode);
  const audit =
    result.override == null
      ? ""
      : ` actor=${result.override.actor} actor_id=${result.override.actorId} event_id=${result.override.eventId} timestamp=${result.override.timestamp}`;
  const blocker = result.blocker ? ` blocker=${result.blocker}` : "";
  appendGateSummary(
    `${summary}\n\n- **Decision:** ${result.status}${blocker}${audit}`,
    environment,
  );

  if (!verdict.present) {
    console.log(
      `::notice::Main-red circuit breaker (${annotationValue(mode)}): no completed app/mobile verdict; missing verdict passes.${verdict.mergeBaseSha ? ` merge-base=${annotationValue(verdict.mergeBaseSha)}.` : ""}${verdict.reason ? ` reason=${annotationValue(verdict.reason)}` : ""}`,
    );
    return;
  }
  if (result.status === "failed_observed") {
    console.log(
      `::warning::Main-red circuit breaker (observe): app/mobile verdict failed on run ${annotationValue(verdict.run?.id ?? "unknown")}; merge remains unblocked.`,
    );
    return;
  }
  if (result.status === "overridden") {
    console.log(
      `::notice::Main-red circuit breaker overridden by ${annotationValue(result.override.actor)} (actor_id=${annotationValue(result.override.actorId)}, event_id=${annotationValue(result.override.eventId)}, timestamp=${annotationValue(result.override.timestamp)}).`,
    );
    return;
  }
  if (result.status === "failed") {
    console.error(
      `::error::${MAIN_RED_CIRCUIT_BREAKER}: completed app/mobile verdict failed on run ${annotationValue(verdict.run?.id ?? "unknown")}; no valid ${CI_FREEZE_OVERRIDE_LABEL} override.`,
    );
    return;
  }
  console.log(
    `::notice::Main-red circuit breaker (${annotationValue(mode)}): completed app/mobile verdict ${annotationValue(verdict.conclusion)} on run ${annotationValue(verdict.run?.id ?? "unknown")}.`,
  );
}

export function evaluateGate(required, observations, options = {}) {
  const treatCancelledAsFailed = options.treatCancelledAsFailed === true;
  const missing = [];
  const pending = [];
  const failed = [];
  const passed = [];
  for (const context of required) {
    const item = observations.get(context);
    if (!item) missing.push(context);
    else if (PASSING.has(item.conclusion)) passed.push(context);
    else if (item.conclusion === "cancelled") {
      if (treatCancelledAsFailed) {
        failed.push({
          context,
          conclusion: item.conclusion,
          url: item.url,
        });
      } else {
        pending.push({
          context,
          status: "replacement_pending",
          url: item.url,
        });
      }
    } else if (FAILING.has(item.conclusion))
      failed.push({ context, conclusion: item.conclusion, url: item.url });
    else
      pending.push({
        context,
        status: item.status,
        url: item.url,
        ...(item.startedAt ? { startedAt: item.startedAt } : {}),
      });
  }
  return {
    ready: missing.length === 0 && pending.length === 0 && failed.length === 0,
    missing,
    pending,
    failed,
    passed,
  };
}

// Workflow timeout clocks start independently: this evaluator's deadline is
// anchored to the umbrella's start, while a component such as the AgentLens
// app suite may spend a long time behind its dependency jobs and hosted macOS
// runner queueing before its own timeout clock even begins. Comparing static
// execution caps therefore cannot guarantee the umbrella outlives the
// component. Once every remaining required context is an observed, started
// run, the wait is re-anchored to the latest observed component start plus the
// configured per-component runtime budget and polling headroom.
export function pendingComponentAllowanceMs(pending, options = {}) {
  const componentBudgetMs = options.componentBudgetMs ?? 0;
  const headroomMs = options.headroomMs ?? 0;
  if (componentBudgetMs <= 0 || pending.length === 0) return null;
  let latest = null;
  for (const item of pending) {
    if (!item.startedAt) return null;
    const startedMs = Date.parse(item.startedAt);
    if (!Number.isFinite(startedMs)) return null;
    latest = Math.max(latest ?? 0, startedMs + componentBudgetMs + headroomMs);
  }
  return latest;
}

const sleep = (milliseconds) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

// A single transient GitHub API hiccup (a mid-poll 502, a rate-limit burst, a
// dropped connection) must not burn hours of otherwise healthy waiting, so
// transient failures are retried with exponential backoff before the poll
// gives up. Non-transient responses (bad token, missing repo) still fail
// immediately: retrying cannot fix them and would only hide a real
// misconfiguration until the deadline.
export function isTransientGithubStatus(status) {
  return status === 429 || status >= 500;
}

export async function githubJson(url, token, options = {}) {
  const attempts = options.attempts ?? 5;
  const baseBackoffMs = options.baseBackoffMs ?? 5_000;
  const wait = options.sleep ?? sleep;
  for (let attempt = 1; ; attempt += 1) {
    let response = null;
    let failure = null;
    try {
      response = await fetch(url, {
        headers: {
          Accept: "application/vnd.github+json",
          Authorization: `Bearer ${token}`,
          "X-GitHub-Api-Version": "2022-11-28",
        },
      });
    } catch (error) {
      failure = new Error(`GitHub API request failed: ${error.message}`);
    }
    if (response) {
      if (response.ok) return response.json();
      failure = new Error(
        `GitHub API ${response.status}: ${await response.text()}`,
      );
      if (!isTransientGithubStatus(response.status)) throw failure;
    }
    if (attempt >= attempts) throw failure;
    const delayMs = baseBackoffMs * 2 ** (attempt - 1);
    console.log(
      `Transient GitHub API failure (attempt ${attempt}/${attempts}), retrying in ${delayMs / 1000}s: ${failure.message}`,
    );
    await wait(delayMs);
  }
}

async function githubPages(url, key, token, fetchJson = githubJson) {
  const values = [];
  for (let page = 1; ; page += 1) {
    const separator = url.includes("?") ? "&" : "?";
    const payload = await fetchJson(
      `${url}${separator}per_page=100&page=${page}`,
      token,
    );
    const batch = payload[key] ?? [];
    values.push(...batch);
    if (batch.length < 100) return values;
  }
}

async function githubArrayPages(url, token, fetchJson = githubJson) {
  const values = [];
  for (let page = 1; ; page += 1) {
    const separator = url.includes("?") ? "&" : "?";
    const payload = await fetchJson(
      `${url}${separator}per_page=100&page=${page}`,
      token,
    );
    const batch = Array.isArray(payload) ? payload : [];
    values.push(...batch);
    if (batch.length < 100) return values;
  }
}

export async function collectObservations(repository, sha, token) {
  const [checks, statuses] = await Promise.all([
    githubPages(
      `https://api.github.com/repos/${repository}/commits/${sha}/check-runs`,
      "check_runs",
      token,
    ),
    githubPages(
      `https://api.github.com/repos/${repository}/commits/${sha}/status`,
      "statuses",
      token,
    ),
  ]);
  const observations = new Map();
  for (const check of [...checks].sort((a, b) => a.id - b.id)) {
    observations.set(check.name, {
      status: check.status,
      conclusion: check.conclusion,
      startedAt: check.started_at,
      completedAt: check.completed_at,
      url: check.html_url,
    });
  }
  // The combined-status API returns newest first. Keep the first observation
  // for each context so stale retries cannot override the current result.
  for (const status of statuses) {
    if (!observations.has(status.context)) {
      observations.set(status.context, {
        status: status.state === "pending" ? "in_progress" : "completed",
        conclusion:
          status.state === "pending"
            ? null
            : status.state === "error"
              ? "failure"
              : status.state,
        url: status.target_url,
      });
    }
  }
  return observations;
}

// MARK: - Stalled check-run reconciliation
//
// A check run can freeze at `status: "in_progress"` with a null conclusion even
// though the work behind it finished. GitHub never publishes the terminal
// state, so the check run is *stale* rather than slow and polling it can never
// resolve. Twice on 2026-08-11 that stranded the whole merge queue:
// `PR Native Gate` sat non-terminal with a failed step inside it, and
// `App build + test (AgentLens)` — a job that normally finishes in seconds —
// sat non-terminal for four hours with every step successful. Both times the
// gate burned its full 4.5h budget and would have fail-closed, ejecting healthy
// candidates for a result that already existed.
//
// The tell in both incidents was identical: every step inside the job had
// reached a terminal conclusion while the job envelope had not. Steps describe
// work that demonstrably ran, so they are the more authoritative record and
// this reconciles against them.
//
// Deliberately asymmetric, to stay fail-closed:
//
//   * A terminal *failing* step resolves immediately — the evidence is
//     unambiguous, and waiting only delays a failure the gate must report.
//     (Incident 1 would have failed in ~3 minutes rather than hanging 4.5h.)
//   * An all-successful job resolves only after a grace period, so ordinary lag
//     between the last step and the published conclusion is never mistaken for
//     a zombie.
//
// Anything else — a step still running, a non-Actions check, an unreadable job
// — reconciles to nothing and the normal polling path continues unchanged.

/// Extract the Actions run/job identifiers a check run's URL points at.
/// Returns `null` for checks not backed by an Actions job (external reporters,
/// commit statuses), which are left to the normal path.
export function parseActionsJobRef(url) {
  const match = /\/actions\/runs\/(\d+)\/job\/(\d+)(?:[/?#]|$)/.exec(url ?? "");
  return match ? { runId: match[1], jobId: match[2] } : null;
}

/// Derive the conclusion a stalled job's steps already prove, or `null` when
/// the job is not stalled or its steps cannot settle the question.
export function stalledJobConclusion(job, options = {}) {
  // A job that published its own conclusion is not stalled; the check run will
  // catch up, and second-guessing it here would be strictly less accurate.
  if (!job || job.conclusion) return null;
  const steps = Array.isArray(job.steps) ? job.steps : [];
  if (steps.length === 0) return null;
  if (!steps.every((step) => step.status === "completed")) return null;

  const failing = steps.find((step) => FAILING.has(step.conclusion));
  if (failing)
    return { conclusion: "failure", reason: `step "${failing.name}" failed` };

  if (!steps.every((step) => PASSING.has(step.conclusion))) return null;
  const stalledSinceMs = Date.parse(
    job.completed_at ?? job.started_at ?? options.startedAt ?? "",
  );
  const graceMs = options.graceMs ?? 0;
  const now = options.now ?? Date.now();
  if (!Number.isFinite(stalledSinceMs) || now - stalledSinceMs < graceMs)
    return null;
  const stalledMinutes = Math.round((now - stalledSinceMs) / 60_000);
  return {
    conclusion: "success",
    reason: `every step completed successfully and no conclusion was published for ${stalledMinutes}m`,
  };
}

/// Resolve pending contexts whose backing Actions job has already finished.
/// Returns a Map of context name to a reconciled observation.
export async function reconcileStalledChecks(pending, options = {}) {
  const { repository, token, graceMs = 0, now = Date.now() } = options;
  const fetchJob =
    options.fetchJob ??
    ((jobId) =>
      githubJson(
        `https://api.github.com/repos/${repository}/actions/jobs/${jobId}`,
        token,
      ));
  const reconciled = new Map();
  for (const item of pending) {
    const ref = parseActionsJobRef(item.url);
    if (!ref) continue;
    let job = null;
    try {
      job = await fetchJob(ref.jobId, ref.runId);
    } catch (error) {
      // A job we cannot read is not evidence of anything; keep waiting.
      console.log(
        `Could not read job ${ref.jobId} for "${item.context}": ${error.message}`,
      );
      continue;
    }
    const resolution = stalledJobConclusion(job, {
      graceMs,
      now,
      startedAt: item.startedAt,
    });
    if (!resolution) continue;
    console.log(
      `Reconciled stalled check "${item.context}" to ${resolution.conclusion}: ${resolution.reason}.`,
    );
    reconciled.set(item.context, {
      status: "completed",
      conclusion: resolution.conclusion,
      url: item.url,
      reconciled: true,
    });
  }
  return reconciled;
}

function knownRunEvent(value) {
  switch (value) {
    case "push":
      return "push";
    case "pull_request":
      return "pull_request";
    case "pull_request_target":
      return "pull_request_target";
    case "merge_group":
      return "merge_group";
    case "workflow_dispatch":
      return "workflow_dispatch";
    case "schedule":
      return "schedule";
    case "workflow_run":
      return "workflow_run";
    default:
      return "other";
  }
}

function reasonCode(sample) {
  if (sample?.present === true) return "present";
  const reason = String(sample?.reason ?? "");
  if (reason.startsWith("workflow run status is")) return "run-not-completed";
  if (reason.startsWith("jobs unreadable")) return "jobs-unreadable";
  if (reason.length === 0) return "none";
  return "verdict-absent";
}

function isoTimestamp(value) {
  const ms = Date.parse(String(value ?? ""));
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

// The availability report is derived from GitHub API responses. What reaches
// the file system is a typed projection (numbers, booleans, timestamps, and
// enumerated codes); the full strings stay in the job log.
export function diskSafeAvailabilityReport(report) {
  const rate =
    report?.verdictPresentRate == null ? null : Number(report.verdictPresentRate);
  return {
    window: typeof report?.window === "string" ? report.window : null,
    generatedAt: isoTimestamp(report?.generatedAt),
    samples: positiveInteger(report?.samples) ?? 0,
    presentCount: positiveInteger(report?.presentCount) ?? 0,
    verdictPresentRate: Number.isFinite(rate) ? rate : null,
    unverified: report?.unverified === true,
    runs: (Array.isArray(report?.runs) ? report.runs : []).map((sample) => ({
      runId: positiveInteger(sample?.runId),
      createdAt: isoTimestamp(sample?.createdAt),
      event: knownRunEvent(sample?.event),
      present: sample?.present === true,
      reasonCode: reasonCode(sample),
    })),
  };
}

function writeAvailabilityReport(reportPath, report) {
  writeFileSync(
    reportPath,
    `${JSON.stringify(diskSafeAvailabilityReport(report), null, 2)}\n`,
  );
}

async function runVerdictAvailabilityReport({
  repository,
  token,
  replayWindow,
  reportPath,
}) {
  let report;
  try {
    report = await measureVerdictAvailability({
      repository,
      token,
      replayWindow,
    });
  } catch (error) {
    report = {
      window: replayWindow,
      generatedAt: new Date().toISOString(),
      samples: 0,
      presentCount: 0,
      verdictPresentRate: null,
      unverified: true,
      error: error instanceof Error ? error.message : String(error),
      runs: [],
    };
    console.error(
      `::warning::Verdict availability is UNVERIFIED: ${annotationValue(report.error)}`,
    );
  }
  writeAvailabilityReport(reportPath, report);
  console.log(
    `Verdict availability: ${report.presentCount}/${report.samples} samples present (${report.verdictPresentRate ?? "n/a"}).${report.unverified ? " UNVERIFIED." : ""} Report: ${reportPath}`,
  );
}

async function main() {
  const args = parseCliArguments(process.argv.slice(2));
  const config = JSON.parse(readFileSync(args.configPath, "utf8"));
  const repository = process.env.GITHUB_REPOSITORY;
  const sha = resolveObservedSha();
  const baseSha = resolveBaseSha() || sha;
  const token = process.env.GITHUB_TOKEN;
  if (args.replayWindow) {
    if (!args.reportPath)
      throw new Error("--replay-window requires --report <path>");
    if (!repository || !token) {
      const report = {
        window: args.replayWindow,
        generatedAt: new Date().toISOString(),
        samples: 0,
        presentCount: 0,
        verdictPresentRate: null,
        unverified: true,
        error:
          "GITHUB_REPOSITORY and GITHUB_TOKEN are required for --replay-window",
        runs: [],
      };
      console.error(
        `::warning::Verdict availability is UNVERIFIED: ${annotationValue(report.error)}`,
      );
      writeAvailabilityReport(args.reportPath, report);
      console.log(
        `Verdict availability: 0/0 samples present (n/a). UNVERIFIED. Report: ${args.reportPath}`,
      );
      return;
    }
    await runVerdictAvailabilityReport({
      repository,
      token,
      replayWindow: args.replayWindow,
      reportPath: args.reportPath,
    });
    return;
  }
  if (!sha) {
    throw new Error("BURNBAR_CI_SHA or GITHUB_SHA is required");
  }

  const mode = config.circuitBreaker?.mode ?? "observe";
  if (mode !== "observe" && mode !== "enforce") {
    throw new Error(`circuitBreaker.mode must be observe or enforce, got "${mode}"`);
  }
  if (!repository || !token) {
    if (process.env.GITHUB_ACTIONS === "true") {
      throw new Error(
        "GITHUB_REPOSITORY and GITHUB_TOKEN are required inside GitHub Actions",
      );
    }
    const mainVerdict = {
      present: false,
      reason:
        "main verdict lookup unavailable: GITHUB_REPOSITORY and GITHUB_TOKEN are not set",
      mergeBaseSha: null,
    };
    const breaker = evaluateMainRedCircuitBreaker(mainVerdict, { mode });
    emitMainRedCircuitBreaker(mainVerdict, breaker, mode);
    return;
  }
  let mainVerdict;
  try {
    mainVerdict = await resolveMainAppGateVerdict({
      repository,
      baseSha,
      token,
    });
  } catch (error) {
    // The breaker is explicitly observing-first: an unavailable lookup is no
    // completed verdict, so it is reported as missing in both modes rather
    // than being mistaken for a green or red main.
    mainVerdict = {
      present: false,
      reason: `main verdict lookup unavailable: ${
        error instanceof Error ? error.message : String(error)
      }`,
      mergeBaseSha: null,
    };
    console.error(`::warning::${annotationValue(mainVerdict.reason)}`);
  }
  let override = null;
  const pullRequestNumber = resolvePullRequestNumber();
  if (
    mode === "enforce" &&
    mainVerdict.present &&
    mainVerdict.conclusion === "failure" &&
    pullRequestNumber !== null
  ) {
    try {
      override = await findFreezeOverride(
        repository,
        pullRequestNumber,
        token,
        {
          overrideActors: config.circuitBreaker?.overrideActors,
        },
      );
    } catch (error) {
      console.error(
        `::warning::Unable to read ${CI_FREEZE_OVERRIDE_LABEL} timeline for PR #${pullRequestNumber}: ${annotationValue(
          error instanceof Error ? error.message : String(error),
        )}`,
      );
    }
  }
  const breaker = evaluateMainRedCircuitBreaker(mainVerdict, {
    mode,
    override,
  });
  emitMainRedCircuitBreaker(mainVerdict, breaker, mode);
  if (!breaker.pass) {
    process.exitCode = 1;
    return;
  }

  const deadline = Date.now() + Number(config.timeout_minutes) * 60_000;
  const componentBudgetMs =
    Number(config.component_runtime_budget_minutes ?? 0) * 60_000;
  const componentHeadroomMs = 5 * 60_000;
  const stalledGraceMs =
    Number(config.stalled_check_grace_minutes ?? 10) * 60_000;
  while (true) {
    const observations = await collectObservations(repository, sha, token);
    let state = evaluateGate(config.required_contexts, observations);
    // A pending context whose job already finished is stale, not slow. Fold the
    // job's own verdict in before deciding to keep waiting, so a check run that
    // will never publish a conclusion cannot burn the whole budget.
    if (!state.ready && state.pending.length > 0) {
      const reconciled = await reconcileStalledChecks(state.pending, {
        repository,
        token,
        graceMs: stalledGraceMs,
      });
      if (reconciled.size > 0) {
        for (const [context, observation] of reconciled)
          observations.set(context, observation);
        state = evaluateGate(config.required_contexts, observations);
      }
    }
    if (state.failed.length > 0) {
      console.error(JSON.stringify(state, null, 2));
      process.exitCode = 1;
      return;
    }
    if (state.ready) {
      console.log(
        `All ${state.passed.length} component contexts passed for ${sha}.`,
      );
      return;
    }
    if (Date.now() >= deadline) {
      const allowanceMs =
        state.missing.length === 0
          ? pendingComponentAllowanceMs(state.pending, {
              componentBudgetMs,
              headroomMs: componentHeadroomMs,
            })
          : null;
      if (allowanceMs === null || Date.now() >= allowanceMs) {
        // At the hard deadline, cancelled replacements that never arrived
        // become terminal failures so the gate still fails closed.
        const timedOut = evaluateGate(
          config.required_contexts,
          await collectObservations(repository, sha, token),
          { treatCancelledAsFailed: true },
        );
        // The refreshed read can observe a final check completing between the
        // first observation and the deadline re-check; a fully ready state is
        // a pass, not a timeout.
        if (timedOut.ready) {
          console.log(
            `All ${timedOut.passed.length} component contexts passed for ${sha}.`,
          );
          return;
        }
        console.error(
          JSON.stringify({ error: "CI gate timed out", ...timedOut }, null, 2),
        );
        process.exitCode = 1;
        return;
      }
      console.log(
        `Deadline passed but every pending component has started; waiting until ${new Date(allowanceMs).toISOString()}.`,
      );
    }
    console.log(
      `Waiting: ${state.missing.length} missing, ${state.pending.length} pending, ${state.passed.length} passed.`,
    );
    await sleep(Number(config.poll_interval_seconds) * 1000);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  main();
