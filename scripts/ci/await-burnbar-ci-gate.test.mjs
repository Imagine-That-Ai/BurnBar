import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { collectObservations, evaluateGate } from "./await-burnbar-ci-gate.mjs";

test("workflow observes the PR head and the merge-group candidate exactly", () => {
  const workflow = readFileSync(
    new URL("../../.github/workflows/burnbar-ci-gate.yml", import.meta.url),
    "utf8",
  );
  assert.match(
    workflow,
    /GITHUB_SHA: \$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}/,
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
