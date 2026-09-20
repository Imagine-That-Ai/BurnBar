import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const repoRoot = path.resolve(import.meta.dirname, "../..");
const verifier = path.join(
  repoRoot,
  "scripts/ci/verify-ios-debug-bridge-release.sh",
);

async function makeApp({
  executable = "OpenBurnBarMobile",
  payload = "release-binary",
} = {}) {
  const root = await mkdtemp(
    path.join(tmpdir(), "openburnbar-ios-release-guard-"),
  );
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

/**
 * Build a real Mach-O whose symbol table carries `symbols`.
 *
 * The other tests write a text file as the executable, so `nm` returns nothing
 * and the symbol sweep in the verifier is never exercised. That gap is why a
 * broken FORCE_LOAD exemption regex shipped and failed 10 release attempts at
 * `Archive and export signed iOS app`, ~76 minutes into each one.
 */
async function makeAppWithSymbols(symbols) {
  const root = await mkdtemp(
    path.join(tmpdir(), "openburnbar-ios-release-guard-sym-"),
  );
  const asm = [
    ...symbols.flatMap((symbol) => [`.globl ${symbol}`, `${symbol}:`, "  ret"]),
    ".globl _main",
    "_main:",
    "  ret",
    "",
  ].join("\n");
  const asmPath = path.join(root, "symbols.s");
  await writeFile(asmPath, asm);

  const appPath = path.join(root, "OpenBurnBarMobile.app");
  await mkdir(appPath);
  await writeFile(
    path.join(appPath, "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>OpenBurnBarMobile</string></dict></plist>
`,
  );
  const executablePath = path.join(appPath, "OpenBurnBarMobile");
  const built = spawnSync(
    "clang",
    ["-arch", "arm64", "-o", executablePath, asmPath],
    {
      encoding: "utf8",
    },
  );
  if (built.status !== 0) return null;
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

// Regression: the shim segment of a Swift back-deployment marker can contain
// underscores (swift_Builtin_float). The exemption regex used
// [A-Za-z0-9]* for that segment, so this benign marker was reported as a
// forbidden QA symbol and every iOS Release archive failed.
test("exempts a Swift FORCE_LOAD marker whose shim segment contains underscores", async () => {
  const appPath = await makeAppWithSymbols([
    "__swift_FORCE_LOAD_$_swift_Builtin_float_$_DebugBridgeCore",
  ]);
  if (appPath === null) return; // no clang on this host
  const result = run(appPath);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /PASS/);
});

test("exempts a Swift FORCE_LOAD marker with a plain shim segment", async () => {
  const appPath = await makeAppWithSymbols([
    "__swift_FORCE_LOAD_$_swiftCompatibility56_$_DebugBridgeUI",
  ]);
  if (appPath === null) return;
  const result = run(appPath);
  assert.equal(result.status, 0, result.stderr);
});

test("still bans a QA symbol that merely embeds the FORCE_LOAD marker text", async () => {
  const appPath = await makeAppWithSymbols(["_swift_FORCE_LOAD_StateServer"]);
  if (appPath === null) return;
  const result = run(appPath);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /forbidden QA symbols/);
});

test("still bans genuine DebugBridge symbols alongside a legitimate marker", async () => {
  const appPath = await makeAppWithSymbols([
    "__swift_FORCE_LOAD_$_swift_Builtin_float_$_DebugBridgeCore",
    "_DebugBridgeUIShowOverlay",
  ]);
  if (appPath === null) return;
  const result = run(appPath);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /forbidden QA symbols/);
});
