import assert from "node:assert/strict";
import test from "node:test";

import { verifyFunctionsDeployRun } from "./verify-domain-core-functions-deploy-run.mjs";

const COMMIT = "a".repeat(40);
const TAG = "v1.2.3";
const RUN_ID = 303;
const RUN_ATTEMPT = 4;

function run(event = "push") {
  return {
    id: RUN_ID,
    repository: { full_name: "Imagine-That-Ai/BurnBar" },
    path: ".github/workflows/deploy-production.yml",
    head_sha: COMMIT,
    head_branch: TAG,
    event,
    run_attempt: RUN_ATTEMPT,
    status: "completed",
    conclusion: "success",
  };
}

function jobs(profile = "public-production") {
  const authorization =
    profile === "public-production-rollback" ? "success" : "skipped";
  const values = [
    ["authorize-domain-core-rollback", authorization],
    ["deploy-functions", "success"],
    ["functions-health-gate", "success"],
    ["dispatch-domain-core-functions-evidence", "success"],
  ].map(([name, conclusion]) => ({
    name,
    conclusion,
    status: "completed",
    run_id: RUN_ID,
    head_sha: COMMIT,
  }));
  return { total_count: values.length, jobs: values };
}

function input(profile = "public-production") {
  return {
    run:
      profile === "public-production-rollback"
        ? run("workflow_dispatch")
        : run(),
    jobsDocument: jobs(profile),
    tag: TAG,
    commit: COMMIT,
    deployRunId: RUN_ID,
    deployRunAttempt: RUN_ATTEMPT,
    profile,
  };
}

test("binds a completed successful normal deploy to its exact sorted job set", () => {
  const first = verifyFunctionsDeployRun(input());
  const reversed = input();
  reversed.jobsDocument.jobs.reverse();
  const second = verifyFunctionsDeployRun(reversed);
  assert.deepEqual(first, second);
  assert.deepEqual(first.deployRun, {
    repository: "Imagine-That-Ai/BurnBar",
    workflowPath: ".github/workflows/deploy-production.yml",
    runId: RUN_ID,
    runAttempt: RUN_ATTEMPT,
    event: "push",
    ref: `refs/tags/${TAG}`,
    headSha: COMMIT,
    jobSetSha256: first.deployRun.jobSetSha256,
  });
  assert.match(first.deployRun.jobSetSha256, /^[0-9a-f]{64}$/u);
});

test("requires protected rollback authorization in the exact manual matrix", () => {
  const verified = verifyFunctionsDeployRun(
    input("public-production-rollback"),
  );
  assert.equal(verified.deployRun.event, "workflow_dispatch");

  const push = input("public-production-rollback");
  push.run.event = "push";
  assert.throws(() => verifyFunctionsDeployRun(push));

  const skipped = input("public-production-rollback");
  skipped.jobsDocument.jobs[0].conclusion = "skipped";
  assert.throws(() => verifyFunctionsDeployRun(skipped));
});

test("rejects incomplete, failed, substituted, and non-exact deploy attempts", () => {
  const cases = [
    (value) => {
      value.run.status = "in_progress";
      value.run.conclusion = null;
    },
    (value) => {
      value.run.conclusion = "failure";
    },
    (value) => {
      value.run.run_attempt += 1;
    },
    (value) => {
      value.run.head_sha = "0".repeat(40);
    },
    (value) => {
      value.jobsDocument.jobs.push({
        name: "unexpected-job",
        status: "completed",
        conclusion: "failure",
        run_id: RUN_ID,
        head_sha: COMMIT,
      });
      value.jobsDocument.total_count += 1;
    },
    (value) => {
      value.jobsDocument.jobs.pop();
      value.jobsDocument.total_count -= 1;
    },
    (value) => {
      value.jobsDocument.jobs[1].name = value.jobsDocument.jobs[0].name;
    },
    (value) => {
      value.jobsDocument.jobs[1].status = "in_progress";
      value.jobsDocument.jobs[1].conclusion = null;
    },
    (value) => {
      value.jobsDocument.jobs[1].conclusion = "failure";
    },
    (value) => {
      value.jobsDocument.jobs[1].run_id += 1;
    },
    (value) => {
      value.jobsDocument.jobs[1].head_sha = "0".repeat(40);
    },
    (value) => {
      value.jobsDocument.total_count += 1;
    },
  ];
  for (const mutate of cases) {
    const value = input();
    mutate(value);
    assert.throws(() => verifyFunctionsDeployRun(value));
  }
});
