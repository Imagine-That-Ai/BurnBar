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
const realWorkflow = join(
  repoRoot,
  ".github",
  "workflows",
  "deploy-staging.yml",
);
const realTargetManifest = join(
  repoRoot,
  "functions",
  "staging-deploy-targets.json",
);
const fixtureRoot = mkdtempSync(
  join(tmpdir(), "openburnbar-staging-boundary-"),
);
const fixtureWorkflow = join(
  fixtureRoot,
  ".github",
  "workflows",
  "deploy-staging.yml",
);
const fixtureTargetManifest = join(
  fixtureRoot,
  "functions",
  "staging-deploy-targets.json",
);

mkdirSync(dirname(fixtureWorkflow), { recursive: true });
cpSync(realWorkflow, fixtureWorkflow);
mkdirSync(dirname(fixtureTargetManifest), { recursive: true });
cpSync(realTargetManifest, fixtureTargetManifest);
const pristine = readFileSync(fixtureWorkflow, "utf8");
const pristineTargetManifest = readFileSync(fixtureTargetManifest, "utf8");

function runGate() {
  return spawnSync(process.execPath, [gate], {
    encoding: "utf8",
    env: { ...process.env, STAGING_DEPLOY_BOUNDARY_ROOT: fixtureRoot },
  });
}

function expectPass(label) {
  const result = runGate();
  if (result.status !== 0) {
    throw new Error(
      `${label}: expected PASS\n${result.stdout}${result.stderr}`,
    );
  }
}

function expectFailure(label, mutate) {
  writeFileSync(fixtureWorkflow, mutate(pristine));
  const result = runGate();
  if (result.status === 0) {
    throw new Error(`${label}: expected failure`);
  }
  writeFileSync(fixtureWorkflow, pristine);
}

function expectManifestFailure(label, mutate) {
  writeFileSync(fixtureTargetManifest, mutate(pristineTargetManifest));
  const result = runGate();
  if (result.status === 0) {
    throw new Error(`${label}: expected failure`);
  }
  writeFileSync(fixtureTargetManifest, pristineTargetManifest);
}

try {
  expectPass("real workflow");
  expectFailure("self-overwrite", (source) =>
    source.replace('} > "$TEMP_ENV_FILE"', '} > "$ENV_FILE"'),
  );
  expectFailure("unvalidated targets", (source) =>
    source.replace(
      "^functions:[A-Za-z][A-Za-z0-9_-]*(,functions:[A-Za-z][A-Za-z0-9_-]*)*$",
      ".*",
    ),
  );
  expectFailure("unquoted deploy scope", (source) =>
    source.replace('--only "$deploy_scope"', "--only $deploy_scope"),
  );
  expectFailure("direct expression interpolation", (source) =>
    source.replace(
      'deploy_scope="$FUNCTION_TARGETS"',
      'deploy_scope="${{ github.event.inputs.function_targets }}"',
    ),
  );
  expectFailure("missing scoped entrypoint", (source) =>
    source.replace(
      `          node scripts/ci/prepare-scoped-functions-deploy.mjs \\
            --targets "$FUNCTION_TARGETS" \\
            --functions-dir functions
`,
      "",
    ),
  );
  expectFailure("scoping after auth", (source) => {
    const command = `          node scripts/ci/prepare-scoped-functions-deploy.mjs \\
            --targets "$FUNCTION_TARGETS" \\
            --functions-dir functions
`;
    return source
      .replace(command, "")
      .replace(
        "      - name: Deploy Cloud Functions (staging)\n",
        `${command}      - name: Deploy Cloud Functions (staging)\n`,
      );
  });
  expectManifestFailure("missing commercial target", (source) => {
    const manifest = JSON.parse(source);
    delete manifest.targets.stripeBurnBarProWebhook;
    return `${JSON.stringify(manifest, null, 2)}\n`;
  });
  expectManifestFailure("misbound commercial target", (source) => {
    const manifest = JSON.parse(source);
    manifest.targets.verifyCloudProTopUp.module = "./callables/stripe.js";
    return `${JSON.stringify(manifest, null, 2)}\n`;
  });
  console.log("PASS: staging Functions deploy boundary self-test.");
} finally {
  rmSync(fixtureRoot, { recursive: true, force: true });
}
