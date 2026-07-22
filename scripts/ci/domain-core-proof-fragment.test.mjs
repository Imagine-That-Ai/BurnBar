import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const CLI = join(ROOT, "scripts/ci/domain-core-proof-fragment.mjs");
const SOURCE = "a".repeat(64);

function git(root, ...args) {
  return execFileSync("git", ["-C", root, ...args], { encoding: "utf8" }).trim();
}

function fixture(context) {
  const root = mkdtempSync(join(tmpdir(), "domain-core-fragment-cli-"));
  mkdirSync(join(root, "crates/openburnbar-domain-core"), { recursive: true });
  mkdirSync(join(root, "scripts/ci"), { recursive: true });
  writeFileSync(
    join(root, "crates/openburnbar-domain-core/union-abi-manifest.json"),
    `${JSON.stringify({ coreVersion: "0.1.0", abiVersion: 3, sourceSha256: SOURCE })}\n`,
  );
  writeFileSync(
    join(root, "scripts/ci/domain-core-union-gate.py"),
    `#!/usr/bin/env python3\nprint("${SOURCE}")\n`,
  );
  git(root, "init", "--quiet");
  git(root, "config", "user.email", "proof@example.invalid");
  git(root, "config", "user.name", "Proof Test");
  git(root, "add", ".");
  git(root, "commit", "--quiet", "-m", "candidate");
  const commit = git(root, "rev-parse", "HEAD");
  const suffix = basename(root);
  const report = join(root, "..", `report-${suffix}.log`);
  const output = join(root, "..", `fragment-${suffix}.json`);
  context.after(() => {
    rmSync(root, { recursive: true, force: true });
    rmSync(report, { force: true });
    rmSync(output, { force: true });
  });
  writeFileSync(report, "tests passed\n");
  return { root, commit, report, output };
}

function execute(paths, environment = {}) {
  return spawnSync(
    process.execPath,
    [
      CLI,
      "emit",
      "--repo-root",
      paths.root,
      "--expected-candidate-commit",
      paths.commit,
      "--job-id",
      "promotion-contracts",
      "--suite",
      `promotion-contracts=${paths.report}`,
      "--output",
      paths.output,
    ],
    {
      cwd: ROOT,
      encoding: "utf8",
      env: {
        ...process.env,
        GITHUB_ACTIONS: "true",
        GITHUB_EVENT_NAME: "push",
        GITHUB_RUN_ID: "123",
        GITHUB_RUN_ATTEMPT: "2",
        GITHUB_SHA: paths.commit,
        ...environment,
      },
    },
  );
}

test("emit CLI binds a non-empty suite report to the exact workflow attempt", (context) => {
  const paths = fixture(context);
  const result = execute(paths);
  assert.equal(result.status, 0, result.stderr);
  const fragment = JSON.parse(readFileSync(paths.output, "utf8"));
  assert.equal(fragment.jobId, "promotion-contracts");
  assert.equal(fragment.runId, 123);
  assert.equal(fragment.runAttempt, 2);
  assert.equal(fragment.candidate.candidateCommit, paths.commit);
  assert.match(fragment.suites[0].reportSha256, /^[0-9a-f]{64}$/u);
});

test("emit CLI fails closed outside Actions, for wrong SHA, and for an empty report", (context) => {
  const paths = fixture(context);
  for (const mutate of [
    () => ({ GITHUB_ACTIONS: "false" }),
    () => ({ GITHUB_SHA: "f".repeat(40) }),
    () => {
      writeFileSync(paths.report, "");
      return {};
    },
  ]) {
    rmSync(paths.output, { force: true });
    const result = execute(paths, mutate());
    assert.equal(result.status, 1);
    assert.equal(existsSync(paths.output), false);
  }
});

test("emit CLI binds headSha to the validated candidate checkout when GITHUB_SHA is a synthetic merge SHA", (context) => {
  // Regression: on pull_request events GitHub sets GITHUB_SHA to the synthetic
  // merge commit it creates, not the PR head. The proof fragment's headSha
  // must record the validated candidate checkout (the SHA the tests actually
  // ran against), not GITHUB_SHA. The current code passes GITHUB_SHA as
  // headSha unconditionally, then requires it to equal the candidate commit,
  // so a synthetic merge SHA causes a spurious "fragment head SHA must equal
  // candidate commit" failure on PR runs.
  //
  // The fix is event-aware: on pull_request events, headSha must be the
  // validated candidate checkout (identity.candidateCommit), not GITHUB_SHA.
  // On push events GITHUB_SHA IS the checkout, so the existing wrong-SHA
  // fail-closed contract (the mutation below sets GITHUB_SHA to a wrong SHA
  // on a push event) must still hold — a wrong GITHUB_SHA on push must fail.
  const paths = fixture(context);
  const syntheticMergeSha = "e".repeat(40);
  // Sanity: the synthetic merge SHA must differ from the checkout commit,
  // otherwise the test would not exercise the divergence.
  assert.notEqual(syntheticMergeSha, paths.commit);
  rmSync(paths.output, { force: true });
  const result = execute(paths, {
    GITHUB_EVENT_NAME: "pull_request",
    GITHUB_SHA: syntheticMergeSha,
  });
  assert.equal(result.status, 0, result.stderr);
  const fragment = JSON.parse(readFileSync(paths.output, "utf8"));
  // headSha must be the validated candidate checkout, not the synthetic merge SHA.
  assert.equal(fragment.headSha, paths.commit, "headSha must be the validated candidate checkout");
  assert.notEqual(fragment.headSha, syntheticMergeSha, "headSha must not be the synthetic merge SHA");
  assert.equal(fragment.candidate.candidateCommit, paths.commit);
});

test("emit CLI fails closed for a wrong GITHUB_SHA on a push event (headSha is GITHUB_SHA, not candidate checkout)", (context) => {
  // Counterpart: on push events GITHUB_SHA is the real checkout SHA, so headSha
  // must be GITHUB_SHA and must equal the candidate commit. A wrong GITHUB_SHA
  // on push must fail-closed — the event-aware fix must NOT relax the push-event
  // guard. This prevents the PR-event fix from accidentally accepting a wrong
  // SHA on push.
  const paths = fixture(context);
  const wrongSha = "f".repeat(40);
  assert.notEqual(wrongSha, paths.commit);
  rmSync(paths.output, { force: true });
  const result = execute(paths, {
    GITHUB_EVENT_NAME: "push",
    GITHUB_SHA: wrongSha,
  });
  assert.equal(result.status, 1);
  assert.equal(existsSync(paths.output), false);
});
