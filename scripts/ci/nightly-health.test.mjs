import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  NIGHTLY_LANES,
  buildHealthReport,
  buildLaneHealth,
  collectNightlyHealth,
  main,
} from "./nightly-health.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const lane = NIGHTLY_LANES[0];
const now = "2026-09-01T00:00:00.000Z";

function successRun(id, createdAt) {
  return {
    id,
    status: "completed",
    conclusion: "success",
    created_at: createdAt,
    updated_at: createdAt,
    head_sha: `sha-${id}`,
    html_url: `https://github.com/Imagine-That-Ai/BurnBar/actions/runs/${id}`,
  };
}

test("the nightly trend has exactly six stable lanes", () => {
  assert.deepEqual(
    NIGHTLY_LANES.map((definition) => definition.lane),
    [
      "openburnbar-pr-harness",
      "app-pr-gate",
      "nightly-e2e",
      "codeql",
      "linux-nightly",
      "codex-nightly-ci-repair",
    ],
  );
});

test("lane health counts consecutive red runs and preserves infra versus budget class", () => {
  const health = buildLaneHealth(lane, [
    {
      id: 30,
      status: "completed",
      conclusion: "failure",
      created_at: "2026-09-03T00:00:00.000Z",
      reasonCode: "budget-failed",
    },
    {
      id: 29,
      status: "completed",
      conclusion: "infra-failed",
      reasonCode: "helper-timeout",
      created_at: "2026-09-02T00:00:00.000Z",
    },
    successRun(28, "2026-09-01T00:00:00.000Z"),
  ]);
  assert.equal(health.red, true);
  assert.equal(health.classification, "budget");
  assert.equal(health.failureClass, "budget");
  assert.equal(health.reasonCode, "budget-failed");
  assert.equal(health.consecutive_red, 2);
  assert.equal(health.last_green_run_id, 28);
  assert.equal(health.runs[1].failureClass, "infra");
  assert.equal(health.runs[1].reasonCode, "helper-timeout");
});

test("a lane with no scheduled run is red infrastructure, never an implicit green", () => {
  const health = buildLaneHealth(lane, []);
  assert.equal(health.red, true);
  assert.equal(health.status, "infra-failed");
  assert.equal(health.classification, "infra");
  assert.equal(health.reasonCode, "no-scheduled-run");
  assert.equal(health.consecutive_red, 1);
  assert.equal(health.run_id, null);
});

test("a stale scheduled run is red infrastructure", () => {
  const health = buildLaneHealth(
    lane,
    [successRun(30, "2026-08-30T00:00:00.000Z")],
    {},
    2,
    { observedAt: Date.parse(now) },
  );
  assert.equal(health.red, true);
  assert.equal(health.failureClass, "infra");
  assert.equal(health.reasonCode, "scheduled-run-stale");
});

test("a successful run without identity metadata is red infrastructure", () => {
  const health = buildLaneHealth(lane, [{
    id: 31,
    status: "completed",
    conclusion: "success",
  }]);
  assert.equal(health.red, true);
  assert.equal(health.failureClass, "infra");
  assert.equal(health.reasonCode, "run-metadata-missing");
});

test("run-scoped skipped jobs override an otherwise successful workflow", () => {
  const run = successRun(32, now);
  const health = buildLaneHealth(lane, [run], {
    [run.id]: {
      status: "skipped",
      conclusion: "skipped",
      reasonCode: "job-skipped",
    },
  });
  assert.equal(health.red, true);
  assert.equal(health.failureClass, "infra");
  assert.equal(health.reasonCode, "job-skipped");
});

test("deploy companion health participates in aggregate status without changing six lanes", () => {
  const greenLanes = NIGHTLY_LANES.map((definition, index) => (
    buildLaneHealth(definition, [successRun(index + 1, now)])
  ));
  const report = buildHealthReport(greenLanes, {
    generatedAt: now,
    deployLaneHealth: {
      status: "red",
      consecutive_red: 3,
      reasonCode: "production-health-failed",
    },
  });
  assert.equal(report.status, "red");
  assert.equal(report.lanes.length, 6);
  assert.equal(report.deployLaneHealth.status, "red");
  assert.match(report.markdown, /Deploy companion: \*\*RED\*\*/u);
});

test("an incomplete deploy companion cannot claim green", () => {
  const greenLanes = NIGHTLY_LANES.map((definition, index) => (
    buildLaneHealth(definition, [successRun(index + 1, now)])
  ));
  const report = buildHealthReport(greenLanes, {
    generatedAt: now,
    deployLaneHealth: { status: "green", lanes: [] },
  });
  assert.equal(report.status, "red");
  assert.equal(report.deployLaneHealth.reasonCode, "deploy-health-companion-invalid");
});

test("a valid deploy companion preserves aggregate green", () => {
  const greenLanes = NIGHTLY_LANES.map((definition, index) => (
    buildLaneHealth(definition, [successRun(index + 1, now)])
  ));
  const deployLaneHealth = {
    status: "green",
    lanes: [1, 2].map((runId) => ({
      red: false,
      status: "success",
      classification: "healthy",
      failureClass: null,
      run_id: runId,
      runs: [{ red: false, conclusion: "success" }],
      probes: [{ ok: true }],
    })),
  };
  const report = buildHealthReport(greenLanes, { generatedAt: now, deployLaneHealth });
  assert.equal(report.status, "green");
  assert.equal(report.deployLaneHealth.status, "green");
  assert.equal(report.deployLaneHealth.reasonCode, null);
});

test("offline fixture mode produces a machine-readable six-lane red report", async () => {
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-nightly-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    const outputPath = path.join(tempDirectory, "nightly-health.json");
    await writeFile(fixturePath, JSON.stringify({
      generatedAt: now,
      lanes: NIGHTLY_LANES.map((definition, index) => ({
        lane: definition.lane,
        runs: [index === 2
          ? {
            id: 90,
            status: "completed",
            conclusion: "infra-failed",
            reasonCode: "emulator-not-ready",
            created_at: now,
          }
          : successRun(index + 1, now)],
      })),
    }));
    const report = await main(["--fixture", fixturePath, "--out", outputPath]);
    const persisted = JSON.parse(await readFile(outputPath, "utf8"));
    assert.equal(report.status, "red");
    assert.deepEqual(report.red_lanes, ["nightly-e2e"]);
    assert.equal(persisted.lanes.length, 6);
    assert.equal(persisted.lanes[2].failureClass, "infra");
    assert.equal(persisted.lanes[2].reasonCode, "emulator-not-ready");
    assert.match(persisted.markdown, /Offline fixture mode/u);
    const cli = spawnSync(process.execPath, [
      path.join("scripts", "ci", "nightly-health.mjs"),
      "--fixture",
      fixturePath,
      "--out",
      path.join(tempDirectory, "nightly-health-cli.json"),
    ], {
      cwd: root,
      encoding: "utf8",
      env: { ...process.env, GH_TOKEN: "", GITHUB_TOKEN: "" },
    });
    assert.equal(cli.status, 1, `${cli.stdout}\n${cli.stderr}`);
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("live mode queries workflow runs and the Checks API for reason metadata", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url) => {
    requests.push(String(url));
    if (String(url).includes("/check-runs")) {
      return new Response(JSON.stringify({
        check_runs: [{
          name: "P-PERF-3",
          output: { summary: "status: infra-failed reasonCode: helper-timeout" },
        }],
      }), { status: 200, headers: { "content-type": "application/json" } });
    }
    if (String(url).includes("/actions/runs/")) {
      return new Response(JSON.stringify({
        jobs: [{ status: "completed", conclusion: "success", name: "nightly job" }],
      }), { status: 200, headers: { "content-type": "application/json" } });
    }
    return new Response(JSON.stringify({
      workflow_runs: [{ ...successRun(700, now), conclusion: "failure" }],
    }), { status: 200, headers: { "content-type": "application/json" } });
  };
  try {
    const report = await collectNightlyHealth({
      apiBase: "https://api.github.test",
      limit: 2,
      repo: "Imagine-That-Ai/BurnBar",
      token: "test-token",
      deployLaneHealth: null,
    });
    assert.equal(report.source.mode, "github");
    assert.equal(report.status, "red");
    assert.equal(report.lanes[0].reasonCode, "helper-timeout");
    assert.equal(report.lanes[0].failureClass, "infra");
    assert.equal(report.lanes.length, 6);
    assert.equal(requests.filter((url) => url.includes("/actions/workflows/")).length, 6);
    assert.equal(requests.filter((url) => url.includes("/check-runs")).length, 6);
    assert.equal(requests.filter((url) => url.includes("/actions/runs/")).length, 6);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("empty jobs and missing completed-job conclusions fail closed", async () => {
  const originalFetch = globalThis.fetch;
  try {
    for (const scenario of [
      { jobs: [], reasonCode: "job-metadata-missing" },
      { jobs: [{ status: "completed", name: "nightly job" }], reasonCode: "job-conclusion-missing" },
    ]) {
      globalThis.fetch = async (url) => {
        const requestUrl = String(url);
        if (requestUrl.includes("/check-runs")) {
          return new Response(JSON.stringify({ check_runs: [] }), { status: 200 });
        }
        if (requestUrl.includes("/actions/runs/")) {
          return new Response(JSON.stringify({ jobs: scenario.jobs }), { status: 200 });
        }
        return new Response(JSON.stringify({
          workflow_runs: [successRun(800, now)],
        }), { status: 200 });
      };
      const report = await collectNightlyHealth({
        apiBase: "https://api.github.test",
        limit: 1,
        repo: "Imagine-That-Ai/BurnBar",
        token: "test-token",
        deployLaneHealth: null,
      });
      assert.equal(report.status, "red");
      assert.equal(report.lanes[0].reasonCode, scenario.reasonCode);
      assert.equal(report.lanes[0].failureClass, "infra");
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});
