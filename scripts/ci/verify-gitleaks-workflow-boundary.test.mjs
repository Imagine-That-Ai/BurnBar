#!/usr/bin/env node
/**
 * Positive controls for scripts/ci/verify-gitleaks-workflow-boundary.mjs.
 */

import { readFileSync } from "node:fs";
import {
  findGitleaksWorkflowBoundaryViolations,
} from "./verify-gitleaks-workflow-boundary.mjs";

const currentWorkflow = readFileSync(".github/workflows/security-pr.yml", "utf8");

let passed = 0;
let failed = 0;

function expect(label, workflowText, wantOk) {
  const failures = findGitleaksWorkflowBoundaryViolations(workflowText);
  const ok = failures.length === 0;
  if (ok === wantOk) {
    console.log(`  ok   ${label}`);
    passed += 1;
    return;
  }
  console.error(`  FAIL ${label}: ${failures.join("; ")}`);
  failed += 1;
}

console.log("Self-test: verify-gitleaks-workflow-boundary.mjs\n");

expect("current security-pr workflow passes", currentWorkflow, true);

expect(
  "regressed full-history timeout fails",
  currentWorkflow.replace("timeout-minutes: 60", "timeout-minutes: 15"),
  false,
);

expect(
  "direct head-branch config fails",
  currentWorkflow.replaceAll(
    '--config "${GITLEAKS_CONFIG_PATH}"',
    "--config .gitleaks.toml",
  ),
  false,
);

expect(
  "direct head-branch ignore file fails",
  currentWorkflow.replaceAll(
    '--gitleaks-ignore-path "${GITLEAKS_IGNORE_PATH}"',
    "--gitleaks-ignore-path .gitleaksignore",
  ),
  false,
);

expect(
  "missing base config checkout fails",
  currentWorkflow.replace(
    'git show "${BASE_SHA}:.gitleaks.toml" > "${GITLEAKS_CONFIG_PATH}"',
    'cp .gitleaks.toml "${GITLEAKS_CONFIG_PATH}"',
  ),
  false,
);

expect(
  "missing base ignore checkout fails",
  currentWorkflow.replace(
    'git show "${BASE_SHA}:.gitleaksignore" > "${GITLEAKS_IGNORE_PATH}"',
    'cp .gitleaksignore "${GITLEAKS_IGNORE_PATH}"',
  ),
  false,
);

expect(
  "missing fail-closed guard fails",
  currentWorkflow.replaceAll(
    'Refusing to use head .gitleaks.toml',
    "Falling back to head config",
  ),
  false,
);

expect(
  "missing ignore fail-closed guard fails",
  currentWorkflow.replaceAll(
    'Refusing to use head .gitleaksignore',
    "Falling back to head ignore file",
  ),
  false,
);

console.log(`\n${failed === 0 ? "PASS" : "FAIL"}: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
