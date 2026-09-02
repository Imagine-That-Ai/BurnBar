import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";
import {
  classifyAppGateRun,
  collectObservations,
  emitMainRedCircuitBreaker,
  evaluateMainRedCircuitBreaker,
  evaluateGate,
  findFreezeOverride,
  formatBreakerSummary,
  githubJson,
  isTransientGithubStatus,
  parseActionsJobRef,
  parseQueuePullRequestNumber,
  pendingComponentAllowanceMs,
  reconcileStalledChecks,
  resolveMainAppGateVerdict,
  stalledJobConclusion,
  resolveObservedSha,
  selectValidFreezeOverride,
} from "./await-burnbar-ci-gate.mjs";

const MAIN_BASE_SHA = "base-sha";
const MAIN_COMMITS = [
  { sha: "main-tip" },
  { sha: "docs-only" },
  { sha: "code-red" },
  { sha: MAIN_BASE_SHA },
];

function appGateJobs(
  appConclusion = "success",
  mobileConclusion = "success",
  appLaneConclusion = "success",
) {
  return [
    {
      name: "App build + test (AgentLens)",
      status: "completed",
      conclusion: appConclusion,
      html_url: "https://github.com/o/r/actions/runs/1/job/1",
    },
    {
      name: "Mobile build + unit test",
      status: "completed",
      conclusion: mobileConclusion,
      html_url: "https://github.com/o/r/actions/runs/1/job/2",
    },
    {
      name: "AgentLens Rust + Swift build/test prerequisites",
      status: "completed",
      conclusion: appLaneConclusion,
      html_url: "https://github.com/o/r/actions/runs/1/job/3",
    },
  ];
}

function mainApiFixture({
  mergeBaseSha = MAIN_BASE_SHA,
  commits = MAIN_COMMITS,
  runs = [],
  jobsByRun = {},
  timelineByIssue = {},
  calls = [],
} = {}) {
  return async (url) => {
    calls.push(url);
    const parsed = new URL(url);
    const path = parsed.pathname;
    if (path.includes("/compare/")) {
      return { merge_base_commit: { sha: mergeBaseSha } };
    }
    if (path.endsWith("/commits")) return commits;
    if (path.includes("/actions/workflows/") && path.endsWith("/runs")) {
      const event = parsed.searchParams.get("event");
      return {
        workflow_runs: runs.filter(
          (run) => !event || run.event === event,
        ),
      };
    }
    const jobsMatch = /\/actions\/runs\/(\d+)\/jobs$/u.exec(path);
    if (jobsMatch) return { jobs: jobsByRun[jobsMatch[1]] ?? [] };
    const timelineMatch = /\/issues\/(\d+)\/timeline$/u.exec(path);
    if (timelineMatch) return timelineByIssue[timelineMatch[1]] ?? [];
    throw new Error(`unexpected fixture URL: ${url}`);
  };
}

test("workflow executes trusted base code and observes the exact candidate", () => {
  const workflow = readFileSync(
    new URL("../../.github/workflows/burnbar-ci-gate.yml", import.meta.url),
    "utf8",
  );
  // pull_request was intentionally removed 2026-07-31; only the trusted
  // pull_request_target + merge_group + workflow_dispatch triggers remain.
  assert.doesNotMatch(workflow, /\n  pull_request:\n/);
  assert.match(workflow, /\n  pull_request_target:\n/);
  assert.match(workflow, /\n  merge_group:\n/);
  assert.match(
    workflow,
    /ref: \$\{\{ github\.event\.pull_request\.base\.sha \|\| github\.event\.merge_group\.base_sha \|\| github\.sha \}\}/,
  );
  assert.match(
    workflow,
    /BURNBAR_CI_SHA: \$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.event\.merge_group\.head_sha \|\| github\.sha \}\}/,
  );
  assert.match(workflow, /persist-credentials: false/);
  assert.match(
    workflow,
    /\[\[ "\$\(git rev-parse HEAD\)" == "\$BURNBAR_BASE_SHA" \]\]/,
  );
});

test("umbrella timeout outlives the longest required component", () => {
  const workflow = readFileSync(
    new URL("../../.github/workflows/burnbar-ci-gate.yml", import.meta.url),
    "utf8",
  );
  const domainCore = readFileSync(
    new URL("../../.github/workflows/domain-core.yml", import.meta.url),
    "utf8",
  );
  const config = JSON.parse(
    readFileSync(
      new URL("../../governance/burnbar-ci-gate.json", import.meta.url),
      "utf8",
    ),
  );
  const umbrellaTimeout = Number(
    workflow.match(/^\s{4}timeout-minutes:\s*(\d+)\s*$/mu)?.[1],
  );
  const domainCoreGate = domainCore.match(
    /^\s{2}domain-core-pr-gate:\n([\s\S]*)$/mu,
  )?.[1];
  const longestRemaining = Number(
    domainCoreGate?.match(/^\s{4}timeout-minutes:\s*(\d+)\s*$/mu)?.[1],
  );

  assert.ok(Number.isSafeInteger(longestRemaining) && longestRemaining > 0);
  assert.ok(
    !config.required_contexts.includes("App build + test (AgentLens)"),
    "merge-queue inventory must not wait on post-merge AgentLens",
  );
  assert.ok(
    !config.required_contexts.includes("Mobile build + unit test"),
    "merge-queue inventory must not wait on post-merge mobile",
  );
  assert.ok(
    config.timeout_minutes >= longestRemaining + 15,
    "evaluator must outlive the longest remaining merge-queue component with polling headroom",
  );
  assert.ok(
    umbrellaTimeout >= config.timeout_minutes + 5,
    "workflow timeout must outlive the evaluator deadline",
  );
  assert.ok(
    config.component_runtime_budget_minutes >= longestRemaining,
    "started-component budget must cover the longest remaining component's runtime cap",
  );
  assert.ok(
    umbrellaTimeout > config.timeout_minutes + 15,
    "workflow timeout must fund queueing skew beyond the base deadline",
  );
  assert.ok(
    umbrellaTimeout < 300,
    "workflow must stay below the merge-queue response timeout",
  );
});

test("deadline re-anchors to the observed component start, never to unstarted work", () => {
  const componentBudgetMs = 240 * 60_000;
  const headroomMs = 5 * 60_000;
  // An app job that left the runner queue an hour after the umbrella started
  // is allowed its full runtime budget from its own observed start.
  assert.equal(
    pendingComponentAllowanceMs(
      [
        {
          context: "App build + test (AgentLens)",
          status: "in_progress",
          startedAt: "2026-07-28T13:00:00Z",
        },
      ],
      { componentBudgetMs, headroomMs },
    ),
    Date.parse("2026-07-28T13:00:00Z") + componentBudgetMs + headroomMs,
  );
  // The latest observed start bounds the wait when several components run.
  assert.equal(
    pendingComponentAllowanceMs(
      [
        {
          context: "early",
          status: "in_progress",
          startedAt: "2026-07-28T12:00:00Z",
        },
        {
          context: "late",
          status: "in_progress",
          startedAt: "2026-07-28T13:30:00Z",
        },
      ],
      { componentBudgetMs, headroomMs },
    ),
    Date.parse("2026-07-28T13:30:00Z") + componentBudgetMs + headroomMs,
  );
  // A pending context without an observed start gets no extension, so the
  // base deadline still fails closed for never-started or missing work.
  assert.equal(
    pendingComponentAllowanceMs(
      [
        {
          context: "started",
          status: "in_progress",
          startedAt: "2026-07-28T13:00:00Z",
        },
        { context: "unstarted", status: "replacement_pending" },
      ],
      { componentBudgetMs, headroomMs },
    ),
    null,
  );
  assert.equal(
    pendingComponentAllowanceMs([], { componentBudgetMs, headroomMs }),
    null,
  );
  // Without a configured budget the evaluator keeps its fixed deadline.
  assert.equal(
    pendingComponentAllowanceMs(
      [
        {
          context: "started",
          status: "in_progress",
          startedAt: "2026-07-28T13:00:00Z",
        },
      ],
      { componentBudgetMs: 0, headroomMs },
    ),
    null,
  );
});

test("evaluator surfaces observed component starts on pending contexts", () => {
  const state = evaluateGate(
    ["running"],
    new Map([
      [
        "running",
        {
          conclusion: null,
          status: "in_progress",
          startedAt: "2026-07-28T13:00:00Z",
          url: "run",
        },
      ],
    ]),
  );
  assert.deepEqual(state.pending, [
    {
      context: "running",
      status: "in_progress",
      url: "run",
      startedAt: "2026-07-28T13:00:00Z",
    },
  ]);
});

test("pull_request_target gate stays read-only and secret-free", () => {
  // This workflow runs on `pull_request_target`, which executes in the base
  // repository's context. The only reason that is safe is that it grants no
  // write scope and reads no secrets, so a malicious PR has nothing to reach:
  // it checks out the trusted base commit and merely observes the candidate.
  // Granting a write permission here (or wiring in a secret) would turn the
  // required gate into a pwn-request vector, so both are pinned by this test.
  const workflow = readFileSync(
    new URL("../../.github/workflows/burnbar-ci-gate.yml", import.meta.url),
    "utf8",
  );
  const permissions = workflow.match(/\npermissions:\n((?:  [^\n]*\n)+)/);
  assert.ok(permissions, "workflow must declare an explicit permissions block");
  const scopes = permissions[1]
    .split("\n")
    .filter((line) => line.trim())
    .map((line) => line.trim());
  assert.ok(scopes.length > 0, "permissions block must not be empty");
  for (const requiredReadScope of [
    "actions: read",
    "pull-requests: read",
    "issues: read",
  ]) {
    assert.ok(
      scopes.includes(requiredReadScope),
      `trusted gate must grant ${requiredReadScope} for main-verdict and override reads`,
    );
  }
  for (const scope of scopes) {
    assert.doesNotMatch(
      scope,
      /:\s*(write|write-all)$/,
      `pull_request_target gate must not grant write scope, found: ${scope}`,
    );
  }
  assert.doesNotMatch(
    workflow,
    /\$\{\{\s*secrets\./,
    "pull_request_target gate must not consume repository secrets",
  );
});

test("explicit observed SHA wins over GitHub's immutable merge-ref SHA", () => {
  assert.equal(
    resolveObservedSha({
      BURNBAR_CI_SHA: "pull-request-head",
      GITHUB_SHA: "ephemeral-merge-ref",
    }),
    "pull-request-head",
  );
  assert.equal(
    resolveObservedSha({ GITHUB_SHA: "merge-group" }),
    "merge-group",
  );
});

test("gate accepts successful, neutral, and intentionally skipped contexts", () => {
  const required = ["build", "advisory", "unowned lane"];
  const state = evaluateGate(
    required,
    new Map([
      ["build", { conclusion: "success" }],
      ["advisory", { conclusion: "neutral" }],
      ["unowned lane", { conclusion: "skipped" }],
    ]),
  );
  assert.equal(state.ready, true);
});

test("gate fails closed on terminal failures", () => {
  const state = evaluateGate(
    ["build"],
    new Map([["build", { conclusion: "timed_out", url: "run" }]]),
  );
  assert.equal(state.ready, false);
  assert.deepEqual(state.failed, [
    { context: "build", conclusion: "timed_out", url: "run" },
  ]);
});

test("gate waits for a replacement after a superseded run is cancelled", () => {
  const state = evaluateGate(
    ["build"],
    new Map([
      [
        "build",
        {
          conclusion: "cancelled",
          completedAt: "2026-07-26T21:45:08Z",
          url: "superseded-run",
        },
      ],
    ]),
  );
  assert.equal(state.failed.length, 0);
  assert.deepEqual(state.pending, [
    {
      context: "build",
      status: "replacement_pending",
      url: "superseded-run",
    },
  ]);
});

test("gate only treats cancelled as failed when the hard deadline asks for it", () => {
  const observations = new Map([
    [
      "build",
      {
        conclusion: "cancelled",
        completedAt: "2026-07-26T21:45:08Z",
        url: "cancelled-run",
      },
    ],
  ]);
  // During the normal poll loop, cancelled stays pending so merge-group
  // concurrency cancellations can be replaced without ejecting the PR.
  const pendingState = evaluateGate(["build"], observations);
  assert.equal(pendingState.failed.length, 0);
  assert.equal(pendingState.pending[0].status, "replacement_pending");

  // At the overall evaluator timeout the gate still fails closed.
  const timedOut = evaluateGate(["build"], observations, {
    treatCancelledAsFailed: true,
  });
  assert.deepEqual(timedOut.failed, [
    {
      context: "build",
      conclusion: "cancelled",
      url: "cancelled-run",
    },
  ]);
});

test("deadline re-check treats a fully completed state as a pass, not a timeout", () => {
  // A required check can complete between the deadline observation and the
  // refreshed read taken to classify the timeout. That refreshed state must
  // evaluate ready so the gate returns success instead of ejecting a healthy
  // candidate with a forced timeout failure.
  const state = evaluateGate(
    ["build", "late-finisher"],
    new Map([
      ["build", { conclusion: "success" }],
      ["late-finisher", { conclusion: "success" }],
    ]),
    { treatCancelledAsFailed: true },
  );
  assert.equal(state.ready, true);
  assert.equal(state.failed.length, 0);
});

test("gate waits for missing and in-progress contexts", () => {
  const state = evaluateGate(
    ["missing", "running"],
    new Map([["running", { conclusion: null, status: "in_progress" }]]),
  );
  assert.deepEqual(state.missing, ["missing"]);
  assert.equal(state.pending[0].context, "running");
  assert.equal(state.ready, false);
});

test("collector paginates repositories with more than 100 checks", async () => {
  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(url);
    const parsed = new URL(url);
    const page = Number(parsed.searchParams.get("page"));
    const checks = url.includes("check-runs");
    const body = checks
      ? {
          check_runs:
            page === 1
              ? Array.from({ length: 100 }, (_, index) => ({
                  id: index + 1,
                  name: `check-${index + 1}`,
                  status: "completed",
                  conclusion: "success",
                  completed_at: "2026-07-26T21:45:00Z",
                }))
              : [
                  {
                    id: 101,
                    name: "late-check",
                    status: "completed",
                    conclusion: "success",
                    completed_at: "2026-07-26T21:45:01Z",
                  },
                ],
        }
      : { statuses: [] };
    return { ok: true, json: async () => body };
  };
  try {
    const observations = await collectObservations(
      "owner/repo",
      "sha",
      "token",
    );
    assert.equal(observations.get("late-check").conclusion, "success");
    assert.equal(
      observations.get("late-check").completedAt,
      "2026-07-26T21:45:01Z",
    );
    assert.ok(
      calls.some((url) => url.includes("check-runs") && url.includes("page=2")),
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("transient API failures retry with backoff instead of killing the wait", async () => {
  // PR #2080's gate run died at minute 79 of an otherwise healthy wait when a
  // single poll hit a GitHub 502. Transient server errors, rate limits, and
  // dropped connections must be retried, not turned into a gate failure.
  const originalFetch = globalThis.fetch;
  const delays = [];
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    if (calls === 1)
      return { ok: false, status: 502, text: async () => "Server Error" };
    if (calls === 2) throw new TypeError("fetch failed");
    return { ok: true, json: async () => ({ value: "recovered" }) };
  };
  try {
    const payload = await githubJson("https://api.github.com/poll", "token", {
      attempts: 5,
      baseBackoffMs: 1_000,
      sleep: async (ms) => delays.push(ms),
    });
    assert.deepEqual(payload, { value: "recovered" });
    assert.equal(calls, 3);
    assert.deepEqual(
      delays,
      [1_000, 2_000],
      "backoff must grow between retries",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("exhausted transient retries surface the last failure", async () => {
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    return { ok: false, status: 502, text: async () => "Server Error" };
  };
  try {
    await assert.rejects(
      githubJson("https://api.github.com/poll", "token", {
        attempts: 3,
        baseBackoffMs: 0,
        sleep: async () => {},
      }),
      /GitHub API 502/,
    );
    assert.equal(calls, 3);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("non-transient API errors fail fast so misconfiguration stays loud", async () => {
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    return { ok: false, status: 401, text: async () => "Bad credentials" };
  };
  try {
    await assert.rejects(
      githubJson("https://api.github.com/poll", "token", {
        attempts: 5,
        baseBackoffMs: 0,
        sleep: async () => {
          throw new Error("must not retry a non-transient error");
        },
      }),
      /GitHub API 401/,
    );
    assert.equal(calls, 1, "a bad token must not be retried");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("transient status classification covers rate limits and server errors", () => {
  for (const status of [429, 500, 502, 503, 504]) {
    assert.equal(isTransientGithubStatus(status), true, String(status));
  }
  for (const status of [200, 301, 401, 403, 404, 422]) {
    assert.equal(isTransientGithubStatus(status), false, String(status));
  }
});

test("collector keeps the newest duplicate commit status", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => ({
    ok: true,
    json: async () =>
      url.includes("check-runs")
        ? { check_runs: [] }
        : {
            statuses: [
              {
                context: "external-gate",
                state: "success",
                target_url: "new",
              },
              {
                context: "external-gate",
                state: "failure",
                target_url: "old",
              },
            ],
          },
  });
  try {
    const observations = await collectObservations(
      "owner/repo",
      "sha",
      "token",
    );
    assert.deepEqual(observations.get("external-gate"), {
      status: "completed",
      conclusion: "success",
      url: "new",
    });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

// MARK: - Stalled check-run reconciliation
//
// Both 2026-08-11 merge-queue stalls had the same shape: a check run frozen
// non-terminal over a job whose steps had all finished. These pin that the
// gate now reads the steps rather than waiting out its full budget.

test("a stalled job whose step failed reconciles to failure immediately", () => {
  const resolution = stalledJobConclusion(
    {
      conclusion: null,
      completed_at: "2026-08-11T03:02:59Z",
      steps: [
        { name: "Set up job", status: "completed", conclusion: "success" },
        {
          name: "Check native jobs passed (or were correctly skipped)",
          status: "completed",
          conclusion: "failure",
        },
        { name: "Complete job", status: "completed", conclusion: "success" },
      ],
    },
    // No grace is consumed: a failed step is unambiguous, and this is the case
    // that hung PR Native Gate for 4.5h.
    { graceMs: 60 * 60_000, now: Date.parse("2026-08-11T03:06:00Z") },
  );
  assert.equal(resolution?.conclusion, "failure");
  assert.match(resolution.reason, /Check native jobs passed/u);
});

test("a stalled all-successful job reconciles to success only after the grace", () => {
  const job = {
    conclusion: null,
    completed_at: "2026-08-11T03:54:30Z",
    steps: [
      { name: "Set up job", status: "completed", conclusion: "success" },
      {
        name: "Require every Rust and Swift prerequisite job",
        status: "completed",
        conclusion: "success",
      },
      { name: "Complete job", status: "completed", conclusion: "success" },
    ],
  };
  const graceMs = 10 * 60_000;
  // Inside the grace this is ordinary lag between the last step and the
  // published conclusion, not a zombie.
  assert.equal(
    stalledJobConclusion(job, {
      graceMs,
      now: Date.parse("2026-08-11T03:58:00Z"),
    }),
    null,
  );
  // Four hours later — the real App build + test (AgentLens) stall.
  const resolution = stalledJobConclusion(job, {
    graceMs,
    now: Date.parse("2026-08-11T07:43:00Z"),
  });
  assert.equal(resolution?.conclusion, "success");
});

test("a job that published its own conclusion is never second-guessed", () => {
  assert.equal(
    stalledJobConclusion(
      {
        conclusion: "failure",
        completed_at: "2026-08-11T03:00:00Z",
        steps: [
          { name: "Set up job", status: "completed", conclusion: "success" },
        ],
      },
      { graceMs: 0, now: Date.parse("2026-08-11T09:00:00Z") },
    ),
    null,
  );
});

test("a job with a step still running is not treated as stalled", () => {
  assert.equal(
    stalledJobConclusion(
      {
        conclusion: null,
        started_at: "2026-08-11T03:00:00Z",
        steps: [
          { name: "Set up job", status: "completed", conclusion: "success" },
          { name: "Build", status: "in_progress", conclusion: null },
        ],
      },
      { graceMs: 0, now: Date.parse("2026-08-11T09:00:00Z") },
    ),
    null,
  );
});

test("parseActionsJobRef only matches Actions job URLs", () => {
  assert.deepEqual(
    parseActionsJobRef(
      "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/31456785998/job/93672189722",
    ),
    { runId: "31456785998", jobId: "93672189722" },
  );
  // External reporters and commit statuses must fall through untouched.
  assert.equal(parseActionsJobRef("https://example.com/build/17"), null);
  assert.equal(parseActionsJobRef(undefined), null);
});

test("reconcileStalledChecks resolves a zombie and leaves healthy pending alone", async () => {
  const jobs = {
    93672189722: {
      conclusion: null,
      completed_at: "2026-08-11T03:54:30Z",
      steps: [
        { name: "Set up job", status: "completed", conclusion: "success" },
      ],
    },
    11111: {
      conclusion: null,
      started_at: "2026-08-11T07:40:00Z",
      steps: [{ name: "Build", status: "in_progress", conclusion: null }],
    },
  };
  const reconciled = await reconcileStalledChecks(
    [
      {
        context: "App build + test (AgentLens)",
        url: "https://github.com/o/r/actions/runs/1/job/93672189722",
      },
      {
        context: "Still genuinely running",
        url: "https://github.com/o/r/actions/runs/1/job/11111",
      },
      { context: "External reporter", url: "https://example.com/x" },
    ],
    {
      graceMs: 10 * 60_000,
      now: Date.parse("2026-08-11T07:43:00Z"),
      fetchJob: async (jobId) => jobs[jobId],
    },
  );
  assert.equal(reconciled.size, 1);
  assert.equal(
    reconciled.get("App build + test (AgentLens)").conclusion,
    "success",
  );
});

test("an unreadable job keeps waiting instead of inventing a verdict", async () => {
  const reconciled = await reconcileStalledChecks(
    [
      {
        context: "Flaky to read",
        url: "https://github.com/o/r/actions/runs/1/job/42",
      },
    ],
    {
      graceMs: 0,
      now: Date.now(),
      fetchJob: async () => {
        throw new Error("GitHub API 502");
      },
    },
  );
  assert.equal(reconciled.size, 0);
});

test("stacked queue entries pass both modes with a no-verdict summary", async () => {
  const calls = [];
  const fetchJson = mainApiFixture({ calls, runs: [] });
  const verdict = await resolveMainAppGateVerdict({
    repository: "owner/repo",
    baseSha: "temporary-merge-commit",
    token: "token",
    options: { fetchJson },
  });
  assert.equal(verdict.present, false);
  assert.match(verdict.reason, /no completed app\/mobile run/u);
  assert.ok(
    calls.some((url) =>
      url.includes(
        "/actions/workflows/app-pr-gate.yml/runs?branch=main&event=push",
      ),
    ),
  );
  for (const mode of ["observe", "enforce"]) {
    const decision = evaluateMainRedCircuitBreaker(verdict, { mode });
    assert.equal(decision.pass, true);
    assert.match(formatBreakerSummary(verdict, mode), /no completed/u);
  }
  const directory = mkdtempSync(join(tmpdir(), "burnbar-gate-missing-"));
  const summary = join(directory, "summary.md");
  try {
    emitMainRedCircuitBreaker(
      verdict,
      evaluateMainRedCircuitBreaker(verdict, { mode: "observe" }),
      "observe",
      { GITHUB_STEP_SUMMARY: summary },
    );
    assert.match(readFileSync(summary, "utf8"), /no completed app\/mobile verdict/u);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("docs-only main push is skipped and the walk finds the older executed run", async () => {
  const runs = [
    {
      id: 300,
      event: "push",
      status: "completed",
      conclusion: "success",
      head_sha: "docs-only",
      created_at: "2026-09-01T12:00:00Z",
    },
    {
      id: 299,
      event: "push",
      status: "completed",
      conclusion: "failure",
      head_sha: "code-red",
      created_at: "2026-09-01T11:00:00Z",
    },
  ];
  const verdict = await resolveMainAppGateVerdict({
    repository: "owner/repo",
    baseSha: MAIN_BASE_SHA,
    token: "token",
    options: {
      fetchJson: mainApiFixture({
        runs,
        jobsByRun: {
          300: appGateJobs("success", "skipped", "skipped"),
          299: appGateJobs("failure", "success", "failure"),
        },
      }),
    },
  });
  assert.equal(verdict.present, true);
  assert.equal(verdict.conclusion, "failure");
  assert.equal(verdict.run.id, 299);
  assert.deepEqual(
    verdict.rejectedRuns.map(({ run, reason }) => ({
      id: run.id,
      reason,
    })),
    [
      {
        id: 300,
        reason:
          "required jobs did not actually run: Mobile build + unit test, AgentLens Rust + Swift build/test prerequisites",
      },
    ],
  );
});

test("classifier-skipped app and mobile lanes are no verdict, never green", () => {
  const verdict = classifyAppGateRun(
    {
      id: 301,
      status: "completed",
      conclusion: "success",
    },
    appGateJobs("success", "skipped", "skipped"),
  );
  assert.equal(verdict.present, false);
  assert.equal(
    evaluateMainRedCircuitBreaker(verdict, { mode: "enforce" }).pass,
    true,
  );
});

test("completed failure passes in observe mode with a warning annotation", () => {
  const verdict = classifyAppGateRun(
    {
      id: 302,
      status: "completed",
      conclusion: "failure",
    },
    appGateJobs("failure", "success", "failure"),
  );
  assert.equal(verdict.present, true);
  const decision = evaluateMainRedCircuitBreaker(verdict, { mode: "observe" });
  assert.equal(decision.pass, true);
  assert.equal(decision.status, "failed_observed");

  const lines = [];
  const originalLog = console.log;
  console.log = (line) => lines.push(line);
  try {
    emitMainRedCircuitBreaker(verdict, decision, "observe");
  } finally {
    console.log = originalLog;
  }
  assert.ok(
    lines.some((line) => line.startsWith("::warning::")),
    "observe mode must emit a warning annotation for a completed red",
  );
});

test("completed failure fails enforce mode with the named blocker", () => {
  const verdict = classifyAppGateRun(
    {
      id: 303,
      status: "completed",
      conclusion: "failure",
    },
    appGateJobs("failure", "success", "failure"),
  );
  const decision = evaluateMainRedCircuitBreaker(verdict, {
    mode: "enforce",
  });
  assert.equal(decision.pass, false);
  assert.equal(decision.blocker, "main-red-circuit-breaker");
});

test("Ajnunezg-labelled override passes enforce mode and records its audit fields", async () => {
  const calls = [];
  const event = {
    event: "labeled",
    id: 9876,
    created_at: "2026-09-01T13:14:15Z",
    label: { name: "ci-freeze-override" },
    actor: { login: "Ajnunezg", id: 125839313 },
  };
  assert.equal(
    parseQueuePullRequestNumber("gh-readonly-queue/main/pr-2405-abc123"),
    2405,
  );
  const override = await findFreezeOverride(
    "owner/repo",
    2405,
    "token",
    {
      fetchJson: mainApiFixture({
        calls,
        timelineByIssue: { 2405: [event] },
      }),
    },
  );
  assert.deepEqual(override, {
    actor: "Ajnunezg",
    actorId: 125839313,
    eventId: 9876,
    timestamp: "2026-09-01T13:14:15Z",
    label: "ci-freeze-override",
  });
  const verdict = classifyAppGateRun(
    { id: 304, status: "completed", conclusion: "failure" },
    appGateJobs("failure", "success", "failure"),
  );
  const decision = evaluateMainRedCircuitBreaker(verdict, {
    mode: "enforce",
    override,
  });
  assert.equal(decision.pass, true);
  assert.equal(decision.status, "overridden");

  const directory = mkdtempSync(join(tmpdir(), "burnbar-gate-summary-"));
  const summary = join(directory, "summary.md");
  try {
    emitMainRedCircuitBreaker(verdict, decision, "enforce", {
      GITHUB_STEP_SUMMARY: summary,
    });
    const body = readFileSync(summary, "utf8");
    assert.match(body, /actor=Ajnunezg/u);
    assert.match(body, /event_id=9876/u);
    assert.match(body, /timestamp=2026-09-01T13:14:15Z/u);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
  assert.ok(
    calls.some((url) => url.includes("/issues/2405/timeline")),
    "override must be read from the PR timeline",
  );
});

test("override label applied by another actor is ignored", () => {
  const unauthorized = selectValidFreezeOverride([
    {
      event: "labeled",
      id: 9877,
      created_at: "2026-09-01T13:14:16Z",
      label: { name: "ci-freeze-override" },
      actor: { login: "someone-else", id: 42 },
    },
  ]);
  assert.equal(unauthorized, null);
  const verdict = classifyAppGateRun(
    { id: 305, status: "completed", conclusion: "failure" },
    appGateJobs("failure", "success", "failure"),
  );
  const decision = evaluateMainRedCircuitBreaker(verdict, {
    mode: "enforce",
    override: unauthorized,
  });
  assert.equal(decision.pass, false);
  assert.equal(decision.blocker, "main-red-circuit-breaker");
});
