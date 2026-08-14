#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const PASSING = new Set(["success", "neutral", "skipped"]);
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

export function resolveObservedSha(environment = process.env) {
  return environment.BURNBAR_CI_SHA || environment.GITHUB_SHA;
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

async function githubPages(url, key, token) {
  const values = [];
  for (let page = 1; ; page += 1) {
    const separator = url.includes("?") ? "&" : "?";
    const payload = await githubJson(
      `${url}${separator}per_page=100&page=${page}`,
      token,
    );
    const batch = payload[key] ?? [];
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

async function main() {
  const config = JSON.parse(
    readFileSync(process.argv[2] ?? "governance/burnbar-ci-gate.json", "utf8"),
  );
  const repository = process.env.GITHUB_REPOSITORY;
  const sha = resolveObservedSha();
  const token = process.env.GITHUB_TOKEN;
  if (!repository || !sha || !token)
    throw new Error(
      "GITHUB_REPOSITORY, BURNBAR_CI_SHA (or GITHUB_SHA), and GITHUB_TOKEN are required",
    );
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
