import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const workflow = readFileSync(path.join(root, ".github/workflows/nightly-dast-sandbox.yml"), "utf8");
const redTeam = readFileSync(path.join(root, "scripts/ci/privileged-socket-redteam-ci.sh"), "utf8");

test("DAST records explicit emulator readiness and skipped-scan reasons", () => {
  assert.match(workflow, /reason_code="emulator-not-ready"/u);
  assert.match(workflow, /emit_outcome "true" "infra" "dast-functions-scan-skipped"/u);
  assert.match(workflow, /emit_outcome "true" "infra" "dast-website-scan-skipped"/u);
  assert.match(workflow, /emulator-readiness\.txt/u);
  assert.match(workflow, /timeout 60 bash -c/u);
});

test("privileged red-team records missing binaries and uploads diagnostic evidence", () => {
  assert.match(redTeam, /privileged-binaries-missing/u);
  assert.match(redTeam, /"failureClass": \$\{failure_class_json\}/u);
  assert.match(redTeam, /"reasonCode": \$\{reason_code_json\}/u);
  assert.match(workflow, /openburnbar-dast-redteam/u);
  assert.match(workflow, /privileged-socket-redteam-\$\{\{ github\.run_id \}\}/u);
});

test("DAST preserves the existing blocking scan settings", () => {
  assert.match(workflow, /cmd_options: "-a -j -I"/u);
  assert.match(workflow, /fail_action: true/u);
  assert.doesNotMatch(workflow, /continue-on-error: true/u);
});
