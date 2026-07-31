#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  assertRuntimeLockfile,
  createRuntimePackageJson,
} from "./prepare-functions-runtime-package.mjs";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const preparer = join(scriptDir, "prepare-functions-runtime-package.mjs");
const root = mkdtempSync(join(tmpdir(), "openburnbar-runtime-package-"));

function writeFixture(directory, packageJson) {
  mkdirSync(directory, { recursive: true });
  writeFileSync(
    join(directory, "package.json"),
    `${JSON.stringify(packageJson, null, 2)}\n`,
  );
  writeFileSync(
    join(directory, "package-lock.json"),
    `${JSON.stringify(
      {
        name: packageJson.name,
        version: packageJson.version,
        lockfileVersion: 3,
        requires: true,
        packages: {
          "": {
            name: packageJson.name,
            version: packageJson.version,
            hasInstallScript: true,
            devDependencies: packageJson.devDependencies,
          },
          "node_modules/firebase-tools": {
            version: "15.23.0",
            dev: true,
          },
        },
      },
      null,
      2,
    )}\n`,
  );
}

function run(directory) {
  return spawnSync(process.execPath, [preparer, "--functions-dir", directory], {
    encoding: "utf8",
  });
}

try {
  const transformed = createRuntimePackageJson({
    name: "fixture",
    version: "1.0.0",
    scripts: { postinstall: "echo unsafe" },
    devDependencies: {
      "firebase-tools": "15.23.0",
      "openburnbar-brace-expansion-cjs": "file:vendor/shim.tgz",
    },
    overrides: {
      "brace-expansion@^1.1.7": "$openburnbar-brace-expansion-cjs",
      "brace-expansion": "^5.0.8",
      "firebase-tools@15.23.0": {
        "minimatch@^3.0.4": "3.1.5",
      },
    },
  });
  assert.deepEqual(transformed.scripts, {});
  assert.equal(transformed.devDependencies, undefined);
  assert.deepEqual(transformed.overrides, {
    "brace-expansion": "^5.0.8",
  });
  assert.throws(
    () =>
      createRuntimePackageJson({
        name: "fixture",
        version: "1.0.0",
        scripts: {},
        overrides: { unexpected: "$candidate-controlled-alias" },
      }),
    /retained npm dependency alias/u,
  );
  assert.doesNotThrow(() =>
    assertRuntimeLockfile(
      {
        lockfileVersion: 3,
        packages: {
          "": { dependencies: { alpha: "1.0.0", zebra: "2.0.0" } },
        },
      },
      { dependencies: { zebra: "2.0.0", alpha: "1.0.0" } },
    ),
  );

  const fixture = join(root, "valid");
  writeFixture(fixture, {
    name: "fixture",
    version: "1.0.0",
    scripts: { postinstall: "echo unsafe" },
    devDependencies: {
      "firebase-tools": "15.23.0",
    },
  });
  const first = run(fixture);
  assert.equal(first.status, 0, `${first.stdout}${first.stderr}`);
  const firstPackage = readFileSync(join(fixture, "package.json"), "utf8");
  const firstLock = readFileSync(join(fixture, "package-lock.json"), "utf8");
  const packageJson = JSON.parse(firstPackage);
  const lockfile = JSON.parse(firstLock);
  assert.deepEqual(packageJson.scripts, {});
  assert.equal(packageJson.devDependencies, undefined);
  assert.equal(lockfile.packages[""].devDependencies, undefined);
  assert.equal(lockfile.packages[""].hasInstallScript, undefined);
  assert.equal(lockfile.packages["node_modules/firebase-tools"], undefined);

  const second = run(fixture);
  assert.equal(second.status, 0, `${second.stdout}${second.stderr}`);
  assert.equal(
    readFileSync(join(fixture, "package.json"), "utf8"),
    firstPackage,
  );
  assert.equal(
    readFileSync(join(fixture, "package-lock.json"), "utf8"),
    firstLock,
  );

  console.log(
    "PASS: production-only Firebase Functions package preparation is deterministic and fail-closed.",
  );
} finally {
  rmSync(root, { recursive: true, force: true });
}
