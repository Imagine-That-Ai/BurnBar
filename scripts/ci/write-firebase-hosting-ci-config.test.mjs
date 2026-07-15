import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(
  new URL("./write-firebase-hosting-ci-config.mjs", import.meta.url),
);

function run(args) {
  return spawnSync(process.execPath, [script, ...args], {
    encoding: "utf8",
  });
}

test("portable Functions config resolves inside a distinct deploy artifact root", () => {
  const root = mkdtempSync(
    join(realpathSync(tmpdir()), "obb-functions-config-"),
  );
  try {
    const deployRoot = join(root, "deploy-runner", "prepared-artifact");
    mkdirSync(join(deployRoot, "functions"), { recursive: true });
    const output = join(deployRoot, "firebase-functions.ci.json");
    const result = run([
      "--mode",
      "functions",
      "--output",
      output,
      "--portable-functions-source",
      "--check",
    ]);
    assert.equal(result.status, 0, result.stderr || result.stdout);

    const config = JSON.parse(readFileSync(output, "utf8"));
    assert.equal(config.functions.source, "functions");
    assert.equal(
      resolve(dirname(output), config.functions.source),
      join(deployRoot, "functions"),
    );
    assert.notEqual(
      resolve(dirname(output), config.functions.source),
      resolve(dirname(script), "../..", "functions"),
    );
  } finally {
    rmSync(root, { force: true, recursive: true });
  }
});

test("portable Functions config fails when the staged source is absent", () => {
  const root = mkdtempSync(
    join(realpathSync(tmpdir()), "obb-functions-config-"),
  );
  try {
    const output = join(root, "firebase-functions.ci.json");
    const result = run([
      "--mode",
      "functions",
      "--output",
      output,
      "--portable-functions-source",
      "--check",
    ]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /does not resolve beside the output config/u);
  } finally {
    rmSync(root, { force: true, recursive: true });
  }
});
