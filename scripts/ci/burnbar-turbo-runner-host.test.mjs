import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const scriptPath = new URL("./burnbar-turbo-runner-host.sh", import.meta.url);
const script = await readFile(scriptPath, "utf8");
const guestScriptPath = new URL("./burnbar-turbo-runner-guest.sh", import.meta.url);
const guestScript = await readFile(guestScriptPath, "utf8");

test("pins the repository, base image, runner version, and runner checksum", () => {
  assert.match(script, /EXPECTED_REPOSITORY="Imagine-That-Ai\/BurnBar"/);
  assert.match(script, /BASE_IMAGE="ghcr\.io\/cirruslabs\/macos-tahoe-xcode@sha256:[0-9a-f]{64}"/);
  assert.match(script, /RUNNER_VERSION="2\.336\.0"/);
  assert.match(script, /RUNNER_SHA256="[0-9a-f]{64}"/);
});

test("runs a one-job runner without default labels or update drift", () => {
  for (const flag of ["--ephemeral", "--disableupdate", "--no-default-labels", "--runnergroup"]) {
    assert.ok(guestScript.includes(flag), `missing ${flag}`);
  }
});

test("keeps the host credential out of the guest command line", () => {
  assert.match(script, /printf '%s\\n' "\$registration_token" \| tart exec -i/);
  assert.doesNotMatch(script, /GH_TOKEN=.*tart exec/);
  assert.match(script, /unset registration_token/);
  assert.match(guestScript, /IFS= read -r registration_token/);
});

test("uses Softnet with no host directory mount", () => {
  assert.match(script, /tart run --no-graphics --net-softnet "\$vm_name"/);
  assert.doesNotMatch(script, /tart run[^\n]*--dir/);
});

test("checks the complete macOS mode for Softnet setuid", () => {
  assert.match(script, /stat -f '%p' "\$softnet_path"/);
  assert.match(script, /softnet_mode & 04000/);
  assert.doesNotMatch(script, /stat -f '%OLp' "\$softnet_path"/);
});

test("archives diagnostics before deleting the exact disposable VM", () => {
  const workerIndex = script.indexOf("run_worker() {");
  const archiveIndex = script.indexOf("\n  archive_diagnostics\n", workerIndex);
  const cleanupIndex = script.indexOf("\n  cleanup_vm\n", archiveIndex);
  assert.ok(archiveIndex >= 0);
  assert.ok(cleanupIndex > archiveIndex);
  assert.match(script, /tart delete "\$cleanup_name"/);
  assert.match(script, /grep -Fxq "\$cleanup_name"/);
});

test("serializes each physical worker slot with an atomic lock", () => {
  assert.match(script, /mkdir "\$lock_dir" 2>\/dev\/null/);
  assert.match(script, /worker \$profile\/\$slot already has an active controller lock/);
});
