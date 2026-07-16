import assert from "node:assert/strict";
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const SCRIPT = resolve(
  new URL("./run-domain-core-android-native-load.sh", import.meta.url).pathname,
);
const CANDIDATE = "a".repeat(40);

function fixture(context, mode = "success") {
  const directory = mkdtempSync(join(tmpdir(), "domain-core-adb-"));
  const adb = join(directory, "adb");
  const apk = join(directory, "domain-core-test.apk");
  const output = join(directory, "observed", "identity.json");
  writeFileSync(apk, "apk");
  writeFileSync(
    adb,
    `#!/usr/bin/env bash
set -euo pipefail
mode="\${FAKE_ADB_MODE:-success}"
if [[ "$1 $2 $3 $4" == "install -r -t ${apk}" ]]; then echo Success; exit 0; fi
if [[ "$1" == "uninstall" ]]; then echo Success; exit 0; fi
if [[ "$1 $2 $3 $4" == "shell pm list instrumentation"* ]]; then
  if [[ "$mode" == "missing" ]]; then
    echo 'instrumentation:example.other/Runner (target=example.target)'
  else
    echo 'instrumentation:example.other/Runner (target=example.target)'
    echo 'instrumentation:com.openburnbar.domaincore.test/androidx.test.runner.AndroidJUnitRunner (target=com.openburnbar.domaincore.test)'
  fi
  exit 0
fi
if [[ "$1 $2 $3" == "shell am instrument" ]]; then echo 'OK (5 tests)'; exit 0; fi
if [[ "$1 $2 $3" == "shell run-as com.openburnbar.domaincore.test" && "$4" == "pwd" ]]; then
  echo '/data/user/0/com.openburnbar.domaincore.test'; exit 0
fi
if [[ "$1 $2 $3 $4" == "exec-out run-as com.openburnbar.domaincore.test cat" ]]; then
  if [[ "$mode" == "invalid-json" ]]; then echo 'run-as: package not debuggable'; exit 0; fi
  if [[ "$mode" == "read-error" ]]; then echo 'remote cat failed' >&2; exit 9; fi
  printf '%s\n' '{"candidateCommit":"${CANDIDATE}","coreVersion":"0.3.0","abiVersion":3,"sourceSha256":"${"b".repeat(64)}","binarySha256":"${"c".repeat(64)}"}'
  exit 0
fi
echo "unexpected fake adb invocation: $*" >&2
exit 98
`,
  );
  chmodSync(adb, 0o755);
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  return { adb, apk, output, mode };
}

function execute(paths) {
  return spawnSync("bash", [SCRIPT, paths.apk, CANDIDATE, paths.output], {
    encoding: "utf8",
    env: { ...process.env, ADB: paths.adb, FAKE_ADB_MODE: paths.mode },
  });
}

test("installs, resolves, runs, and validates the exact instrumentation identity", (context) => {
  const paths = fixture(context);
  const result = execute(paths);
  assert.equal(result.status, 0, result.stderr);
  const identity = JSON.parse(readFileSync(paths.output, "utf8"));
  assert.equal(identity.candidateCommit, CANDIDATE);
  assert.equal(identity.binarySha256, "c".repeat(64));
  assert.match(result.stderr, /Verified loaded Android Rust identity/u);
});

test("rejects ambiguous or absent self-targeting instrumentation", (context) => {
  const paths = fixture(context, "missing");
  const result = execute(paths);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Expected exactly one installed self-targeting/u);
});

test("keeps run-as diagnostics out of the JSON contract", (context) => {
  const paths = fixture(context, "invalid-json");
  const result = execute(paths);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /invalid JSON/u);
});

test("reports extraction stderr instead of publishing a partial identity", (context) => {
  const paths = fixture(context, "read-error");
  const result = execute(paths);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Unable to read the observed Android Rust identity/u);
  assert.match(result.stderr, /remote cat failed/u);
});
