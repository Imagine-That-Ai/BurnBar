import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  collectObservations,
  evaluateGate,
  resolveObservedSha,
} from "./await-burnbar-ci-gate.mjs";

test("workflow executes trusted base code and observes the exact candidate", () => {
  const workflow = readFileSync(
    new URL("../../.github/workflows/burnbar-ci-gate.yml", import.meta.url),
    "utf8",
  );
  assert.match(workflow, /\n  pull_request:\n/);
  assert.match(workflow, /\n  pull_request_target:\n/);
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
  assert.equal(resolveObservedSha({ GITHUB_SHA: "merge-group" }), "merge-group");
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
                }))
              : [
                  {
                    id: 101,
                    name: "late-check",
                    status: "completed",
                    conclusion: "success",
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
    assert.ok(
      calls.some((url) => url.includes("check-runs") && url.includes("page=2")),
    );
  } finally {
    globalThis.fetch = originalFetch;
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
