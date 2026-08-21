#!/usr/bin/env node

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const verifier = join(
  dirname(fileURLToPath(import.meta.url)),
  "verify-github-action-pins.mjs",
);
const root = mkdtempSync(join(tmpdir(), "openburnbar-action-pins-"));
const workflows = join(root, ".github", "workflows");
mkdirSync(workflows, { recursive: true });

function run(name, source, expectedStatus) {
  for (const file of [
    "deploy-staging.yml",
    "other.yml",
  ]) {
    writeFileSync(join(workflows, file), file === name ? source : "on: push\njobs: {}\n");
  }
  const result = spawnSync(process.execPath, [verifier], {
    cwd: root,
    encoding: "utf8",
  });
  if (result.status !== expectedStatus) {
    throw new Error(
      `${name}: expected ${expectedStatus}, got ${result.status}\n${result.stdout}${result.stderr}`,
    );
  }
}

try {
  run(
    "deploy-staging.yml",
    "jobs:\n  deploy:\n    uses: Imagine-That-Ai/BurnBar/.github/workflows/deploy-staging-trusted.yml@main\n",
    0,
  );
  run(
    "other.yml",
    "jobs:\n  deploy:\n    uses: Imagine-That-Ai/BurnBar/.github/workflows/deploy-staging-trusted.yml@main\n",
    1,
  );
  run(
    "deploy-staging.yml",
    "jobs:\n  deploy:\n    uses: Imagine-That-Ai/BurnBar/.github/workflows/other.yml@main\n",
    1,
  );
  run(
    "other.yml",
    "jobs:\n  build:\n    steps:\n      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd\n",
    0,
  );
  // The compact `- uses:` list item is the common spelling; it must be checked,
  // not just tolerated. Without the negative case the line above passes even
  // when the ref is a mutable tag.
  run(
    "other.yml",
    "jobs:\n  build:\n    steps:\n      - uses: actions/checkout@v5\n",
    1,
  );
  run(
    "other.yml",
    "jobs:\n  build:\n    steps:\n      - name: Checkout\n        uses: actions/checkout@v5\n",
    1,
  );
  console.log("PASS: action pin exception is exact and fail-closed; both `uses:` spellings are checked.");
} finally {
  rmSync(root, { recursive: true, force: true });
}
