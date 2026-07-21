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

export function evaluateGate(required, observations) {
  const missing = [];
  const pending = [];
  const failed = [];
  const passed = [];
  for (const context of required) {
    const item = observations.get(context);
    if (!item) missing.push(context);
    else if (PASSING.has(item.conclusion)) passed.push(context);
    else if (FAILING.has(item.conclusion))
      failed.push({ context, conclusion: item.conclusion, url: item.url });
    else pending.push({ context, status: item.status, url: item.url });
  }
  return {
    ready: missing.length === 0 && pending.length === 0 && failed.length === 0,
    missing,
    pending,
    failed,
    passed,
  };
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
      url: check.html_url,
    });
  }
  for (const status of [...statuses].reverse()) {
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
  const sha = process.env.GITHUB_SHA;
  const token = process.env.GITHUB_TOKEN;
  if (!repository || !sha || !token)
    throw new Error(
      "GITHUB_REPOSITORY, GITHUB_SHA, and GITHUB_TOKEN are required",
    );
  const deadline = Date.now() + Number(config.timeout_minutes) * 60_000;
  while (true) {
    const state = evaluateGate(
      config.required_contexts,
      await collectObservations(repository, sha, token),
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
      console.error(
        JSON.stringify({ error: "CI gate timed out", ...state }, null, 2),
      );
      process.exitCode = 1;
      return;
    }
    console.log(
      `Waiting: ${state.missing.length} missing, ${state.pending.length} pending, ${state.passed.length} passed.`,
    );
    await sleep(Number(config.poll_interval_seconds) * 1000);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  main();
