#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const PASSING = new Set(["success", "neutral", "skipped"]);
const FAILING = new Set([
  "failure",
  "cancelled",
  "timed_out",
  "action_required",
  "startup_failure",
  "stale",
]);

export function resolveObservedSha(environment = process.env) {
  return environment.BURNBAR_CI_SHA || environment.GITHUB_SHA;
}

export function evaluateGate(required, observations, options = {}) {
  const nowMs = options.nowMs ?? Date.now();
  const cancelledGraceMs = options.cancelledGraceMs ?? 0;
  const missing = [];
  const pending = [];
  const failed = [];
  const passed = [];
  for (const context of required) {
    const item = observations.get(context);
    if (!item) missing.push(context);
    else if (PASSING.has(item.conclusion)) passed.push(context);
    else if (
      item.conclusion === "cancelled" &&
      item.completedAt &&
      Number.isFinite(Date.parse(item.completedAt)) &&
      nowMs - Date.parse(item.completedAt) < cancelledGraceMs
    ) {
      pending.push({
        context,
        status: "replacement_pending",
        url: item.url,
      });
    }     else if (FAILING.has(item.conclusion))
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

async function githubJson(url, token) {
  const response = await fetch(url, {
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "X-GitHub-Api-Version": "2022-11-28",
    },
  });
  if (!response.ok)
    throw new Error(`GitHub API ${response.status}: ${await response.text()}`);
  return response.json();
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

const sleep = (milliseconds) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

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
  while (true) {
    const state = evaluateGate(
      config.required_contexts,
      await collectObservations(repository, sha, token),
      {
        cancelledGraceMs: Number(config.cancelled_grace_seconds ?? 0) * 1000,
      },
    );
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
        console.error(
          JSON.stringify({ error: "CI gate timed out", ...state }, null, 2),
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
