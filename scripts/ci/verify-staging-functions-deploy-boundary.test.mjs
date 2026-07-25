#!/usr/bin/env node

import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(scriptDir, "..", "..");
const gate = join(scriptDir, "verify-staging-functions-deploy-boundary.mjs");
const fixtureRoot = mkdtempSync(join(tmpdir(), "openburnbar-staging-boundary-"));
const workflowDir = join(fixtureRoot, ".github", "workflows");
mkdirSync(workflowDir, { recursive: true });

for (const name of ["deploy-staging.yml", "deploy-staging-trusted.yml"]) {
  cpSync(
    join(repoRoot, ".github", "workflows", name),
    join(workflowDir, name),
  );
}
const callerPath = join(workflowDir, "deploy-staging.yml");
const trustedPath = join(workflowDir, "deploy-staging-trusted.yml");
const pristineCaller = readFileSync(callerPath, "utf8");
const pristineTrusted = readFileSync(trustedPath, "utf8");

function runGate() {
  return spawnSync(process.execPath, [gate], {
    encoding: "utf8",
    env: { ...process.env, STAGING_DEPLOY_BOUNDARY_ROOT: fixtureRoot },
  });
}

function expectPass(label) {
  const result = runGate();
  if (result.status !== 0) {
    throw new Error(`${label}: expected PASS\n${result.stdout}${result.stderr}`);
  }
}

function expectFailure(label, path, source) {
  writeFileSync(path, source);
  const result = runGate();
  if (result.status === 0) throw new Error(`${label}: expected failure`);
  writeFileSync(callerPath, pristineCaller);
  writeFileSync(trustedPath, pristineTrusted);
}

try {
  expectPass("real workflows");
  expectFailure(
    "unpinned reusable workflow",
    callerPath,
    pristineCaller.replace(
      "deploy-staging-trusted.yml@main",
      "deploy-staging-trusted.yml@feature",
    ),
  );
  expectFailure(
    "candidate auth",
    callerPath,
    `${pristineCaller}\n# google-github-actions/auth\n`,
  );
  expectFailure(
    "candidate scripts enabled",
    trustedPath,
    pristineTrusted.replace(" --ignore-scripts", ""),
  );
  expectFailure(
    "verification after auth",
    trustedPath,
    pristineTrusted
      .replace("Verify bounded candidate artifacts before authentication", "TEMP")
      .replace(
        "Authenticate to Google Cloud through trusted-main WIF",
        "Verify bounded candidate artifacts before authentication",
      )
      .replace("TEMP", "Authenticate to Google Cloud through trusted-main WIF"),
  );
  expectFailure(
    "unquoted deploy scope",
    trustedPath,
    pristineTrusted.replace('--only "$deploy_scope"', "--only $deploy_scope"),
  );
  console.log("PASS: staging deployment boundary self-test.");
} finally {
  rmSync(fixtureRoot, { recursive: true, force: true });
}
