import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  collectObservations,
  evaluateGate,
  githubJson,
  isTransientGithubStatus,
  pendingComponentAllowanceMs,
  resolveObservedSha,
} from "./await-burnbar-ci-gate.mjs";

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
  const appWorkflow = readFileSync(
    new URL("../../.github/workflows/app-pr-gate.yml", import.meta.url),
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
  const appJob = appWorkflow.match(
    /^\s{2}app-build-test:\n([\s\S]*?)^\s{2}mobile-build-gate:/mu,
  )?.[1];
  const appTimeout = Number(
    appJob?.match(/^\s{4}timeout-minutes:\s*(\d+)\s*$/mu)?.[1],
  );

  assert.ok(Number.isSafeInteger(appTimeout) && appTimeout > 0);
  assert.ok(
    config.timeout_minutes >= appTimeout + 15,
    "evaluator must outlive the longest component with polling headroom",
  );
  assert.ok(
    umbrellaTimeout >= config.timeout_minutes + 5,
    "workflow timeout must outlive the evaluator deadline",
  );
  assert.ok(
    config.component_runtime_budget_minutes >= appTimeout,
    "started-component budget must cover the longest component's runtime cap",
  );
  assert.ok(
    umbrellaTimeout > config.timeout_minutes + 15,
    "workflow timeout must fund queueing skew beyond the base deadline",
  );
  assert.ok(umbrellaTimeout < 300, "workflow must stay below the merge-queue response timeout");
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
        { context: "early", status: "in_progress", startedAt: "2026-07-28T12:00:00Z" },
        { context: "late", status: "in_progress", startedAt: "2026-07-28T13:30:00Z" },
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
        { context: "started", status: "in_progress", startedAt: "2026-07-28T13:00:00Z" },
        { context: "unstarted", status: "replacement_pending" },
      ],
      { componentBudgetMs, headroomMs },
    ),
    null,
  );
  assert.equal(pendingComponentAllowanceMs([], { componentBudgetMs, headroomMs }), null);
  // Without a configured budget the evaluator keeps its fixed deadline.
  assert.equal(
    pendingComponentAllowanceMs(
      [{ context: "started", status: "in_progress", startedAt: "2026-07-28T13:00:00Z" }],
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
    if (calls === 1) return { ok: false, status: 502, text: async () => "Server Error" };
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
    assert.deepEqual(delays, [1_000, 2_000], "backoff must grow between retries");
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
