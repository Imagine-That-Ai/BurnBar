import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const repoRoot = path.resolve(import.meta.dirname, "../..");
const verifier = path.join(repoRoot, "scripts/ci/verify-ios-debug-bridge-release.sh");

async function makeApp({ executable = "OpenBurnBarMobile", payload = "release-binary" } = {}) {
  const root = await mkdtemp(path.join(tmpdir(), "openburnbar-ios-release-guard-"));
  const appPath = path.join(root, "OpenBurnBarMobile.app");
  await mkdir(appPath);
  await writeFile(
    path.join(appPath, "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>${executable}</string></dict></plist>
`,
  );
  const executablePath = path.join(appPath, executable);
  await writeFile(executablePath, payload);
  await chmod(executablePath, 0o755);
  return appPath;
}

function run(appPath, env = {}) {
  return spawnSync("/bin/bash", [verifier, appPath], {
    cwd: repoRoot,
    encoding: "utf8",
    env: {
      ...process.env,
      CONFIGURATION: "Release",
      SWIFT_ACTIVE_COMPILATION_CONDITIONS: "",
      ...env,
    },
  });
}

test("passes a clean Release app", async () => {
  const result = run(await makeApp());
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /PASS/);
});

test("fails when Release conditions contain the QA opt-in", async () => {
  const result = run(await makeApp(), {
    SWIFT_ACTIVE_COMPILATION_CONDITIONS: "GSTACK_IOS_QA",
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /contains GSTACK_IOS_QA/);
});

test("fails when a forbidden QA marker is present in the executable", async () => {
  const result = run(await makeApp({ payload: "gstack-ios-qa bootstrap" }));
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /forbidden QA strings/);
});

test("fails when a DebugBridge artifact is bundled", async () => {
  const appPath = await makeApp();
  await writeFile(path.join(appPath, "DebugBridgeCore.framework"), "forbidden");
  const result = run(appPath);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /forbidden QA artifact is bundled/);
});

test("skips non-Release builds", async () => {
  const result = run(await makeApp({ payload: "gstack-ios-qa bootstrap" }), {
    CONFIGURATION: "Debug",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /skipped for Debug/);
});

test("allows a Swift force-load marker whose shim name contains underscores", async () => {
  const result = run(
    await makeApp({
      payload: "__swift_FORCE_LOAD_$_swift_Builtin_float_$_DebugBridgeCore\n",
    }),
  );
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /PASS/);
});

test("still bans a DebugBridgeCore token that is not a complete force-load marker", async () => {
  const result = run(await makeApp({ payload: "DebugBridgeCore\n" }));
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /forbidden QA strings/);
});

test("still bans a force-load-shaped QA symbol that is not a complete marker", async () => {
  const result = run(await makeApp({ payload: "swift_FORCE_LOAD_StateServer\n" }));
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /forbidden QA strings/);
});
