#!/usr/bin/env node

import assert from "node:assert/strict";
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const runnerPath = resolve(repoRoot, "scripts/cross-platform/run-ios");
const source = readFileSync(runnerPath, "utf8");

const firestoreExport =
  'export FIREBASE_SOURCE_FIRESTORE="${FIREBASE_SOURCE_FIRESTORE:-1}"';
const exportIndex = source.indexOf(firestoreExport);
const buildIndex = source.indexOf("xcodebuild");

assert.notEqual(
  exportIndex,
  -1,
  "run-ios must force source-built Firestore unless the caller explicitly overrides it",
);
assert.notEqual(buildIndex, -1, "run-ios must invoke xcodebuild");
assert.ok(
  exportIndex < buildIndex,
  "FIREBASE_SOURCE_FIRESTORE must be exported before xcodebuild can resolve packages",
);
assert.match(
  source,
  /docs\/FIREBASE_IOS27_GRPC\.md/u,
  "run-ios must point maintainers to the source-built Firestore rationale",
);

const tempRoot = mkdtempSync(join(tmpdir(), "burnbar-ios-runner-test-"));
try {
  const markerPath = join(tempRoot, "firestore-env.txt");
  for (const command of ["xcodebuild", "xcrun", "open"]) {
    const commandPath = join(tempRoot, command);
    const body =
      command === "xcodebuild"
        ? '#!/bin/sh\nprintf "%s" "${FIREBASE_SOURCE_FIRESTORE:-}" > "$IOS_RUNNER_TEST_OUTPUT"\n'
        : "#!/bin/sh\nexit 0\n";
    writeFileSync(commandPath, body, "utf8");
    chmodSync(commandPath, 0o755);
  }

  const result = spawnSync("bash", [runnerPath, "CI-Mobile-Focused"], {
    cwd: repoRoot,
    encoding: "utf8",
    env: {
      ...process.env,
      FIREBASE_SOURCE_FIRESTORE: "",
      IOS_RUNNER_TEST_OUTPUT: markerPath,
      PATH: `${tempRoot}:${process.env.PATH ?? ""}`,
    },
  });

  assert.equal(
    result.status,
    0,
    `run-ios stubbed smoke failed:\n${result.stdout}\n${result.stderr}`,
  );
  assert.equal(
    readFileSync(markerPath, "utf8"),
    "1",
    "run-ios must pass FIREBASE_SOURCE_FIRESTORE=1 to xcodebuild by default",
  );
} finally {
  rmSync(tempRoot, { recursive: true, force: true });
}

console.log("cross-platform iOS runner source-Firestore contract passed");
