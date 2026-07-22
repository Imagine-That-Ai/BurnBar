import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflow = readFileSync(
  new URL("../../.github/workflows/burnbar-turbo.yml", import.meta.url),
  "utf8",
);

test("turbo is manually dispatched from a trusted main workflow", () => {
  assert.match(workflow, /^  workflow_dispatch:/mu);
  assert.doesNotMatch(workflow, /^  pull_request(?:_target)?:/mu);
  assert.match(workflow, /context\.ref !== "refs\/heads\/main"/u);
  assert.match(workflow, /\["admin", "maintain", "write"\]/u);
});

test("candidate identity is exact, same-repository, and non-draft", () => {
  assert.match(workflow, /\^\[0-9a-f\]\{40\}\$/u);
  assert.match(workflow, /pull\.head\.sha === sha/u);
  assert.match(workflow, /pull\.head\.repo\?\.full_name === `\$\{owner\}\/\$\{repo\}`/u);
  assert.match(workflow, /pull\.draft === false/u);
});

test("native jobs can only reach the isolated turbo runner group", () => {
  assert.equal(
    [...workflow.matchAll(/group: burnbar-turbo-ephemeral/gu)].length,
    3,
  );
  assert.equal(
    [...workflow.matchAll(/persist-credentials: false/gu)].length,
    3,
  );
  assert.doesNotMatch(workflow, /secrets:\s*inherit/u);
});

test("app turbo lane retains the one-build DerivedData contract", () => {
  assert.match(workflow, /Build once for performance and XCTest reuse/u);
  assert.match(
    workflow,
    /OPENBURNBAR_APP_TEST_DERIVED_DATA_DIR="\$GITHUB_WORKSPACE\/\.derived-data\/macos-idle-occlusion-gate"/u,
  );
  assert.match(workflow, /check-executed-test-count\.sh/u);
  assert.match(workflow, /diff-coverage\.sh origin\/main/u);
});

test("all mode fans out app, mobile, and daemon before one fail-closed gate", () => {
  for (const lane of ["app", "mobile", "daemon"]) {
    assert.match(
      workflow,
      new RegExp(`needs\\.authorize\\.outputs\\.suite == 'all' \\|\\| needs\\.authorize\\.outputs\\.suite == '${lane}'`, "u"),
    );
  }
  assert.match(workflow, /needs: \[authorize, app, mobile, daemon\]/u);
  assert.match(workflow, /name: BurnBar Turbo Gate/u);
});
