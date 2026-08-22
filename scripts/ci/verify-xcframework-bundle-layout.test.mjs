// Regression coverage for the platform-specific framework bundle layouts in
// scripts/build-domain-core-xcframework.sh.
//
// repair.14's release run reached the app-embed step for the first time ever
// and Xcode rejected the macOS slice: "contains Info.plist, expected
// Versions/Current/Resources/Info.plist since the platform does not use
// shallow bundles". The fix made make_framework take a required layout
// parameter (deep for macos-* slices, shallow for iOS/simulator). This test
// executes the REAL make_framework function extracted from the script — not a
// reimplementation — against a stub library and asserts both shapes, so a
// future edit cannot silently give either platform the other's layout again.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, mkdtempSync, readFileSync, readlinkSync, writeFileSync, mkdirSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SCRIPT = join(ROOT, "scripts", "build-domain-core-xcframework.sh");
const MODULE = "openburnbar_domain_ffiFFI";

function extractMakeFramework() {
  const source = readFileSync(SCRIPT, "utf8");
  // The function body contains heredocs whose content includes bare "}" lines
  // (the modulemap), so a non-greedy match to the first ^}$ truncates it.
  // Anchor on the function's actual final statement instead.
  const match = source.match(
    /^make_framework\(\) \{$[\s\S]*?^ {2}build_xcframework_args\+=\(-framework "\$\{framework_dir\}"\)$\n\}/mu,
  );
  assert.ok(match, "make_framework() not found in build-domain-core-xcframework.sh");
  return match[0];
}

function runMakeFramework(layout) {
  // realpathSync: macOS tmpdir lives behind a /var symlink; un-resolved paths
  // break path assertions (same trap as the firestore-rules-size fixture).
  const work = realpathSync(mkdtempSync(join(tmpdir(), "bundle-layout-")));
  const generated = join(work, "generated");
  const out = join(work, "out");
  mkdirSync(generated, { recursive: true });
  mkdirSync(out, { recursive: true });
  writeFileSync(join(generated, `${MODULE}.h`), "// stub umbrella header\n");
  const lib = join(work, "libstub.a");
  writeFileSync(lib, "!<arch>\n");
  // Paths and the layout reach bash strictly through the environment (never
  // interpolated into the command string) — the only inlined text is the
  // function body read from our own repo file.
  const harness = [
    "set -euo pipefail",
    'FRAMEWORK_MODULE_NAME="$TEST_MODULE"',
    'GENERATED_DIR="$TEST_GENERATED_DIR"',
    "build_xcframework_args=()",
    extractMakeFramework(),
    'make_framework "$TEST_LIB" "$TEST_OUT" "$TEST_LAYOUT"',
  ].join("\n");
  execFileSync("bash", ["-c", harness], {
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      TEST_MODULE: MODULE,
      TEST_GENERATED_DIR: generated,
      TEST_LIB: lib,
      TEST_OUT: out,
      TEST_LAYOUT: layout,
    },
  });
  return join(out, `${MODULE}.framework`);
}

test("macOS layout is a deep bundle: Versions/A content, Resources/Info.plist, relative symlinks", () => {
  const fw = runMakeFramework("deep");
  assert.ok(existsSync(join(fw, "Versions", "A", MODULE)), "binary under Versions/A");
  assert.ok(existsSync(join(fw, "Versions", "A", "Headers", `${MODULE}.h`)), "headers under Versions/A");
  assert.ok(existsSync(join(fw, "Versions", "A", "Modules", "module.modulemap")), "modulemap under Versions/A");
  assert.ok(existsSync(join(fw, "Versions", "A", "Resources", "Info.plist")), "Info.plist under Versions/A/Resources");
  assert.ok(!existsSync(join(fw, "Versions", "A", "Info.plist")), "no flat Info.plist inside Versions/A");
  assert.equal(readlinkSync(join(fw, "Versions", "Current")), "A", "Versions/Current -> A");
  for (const [link, target] of [
    [MODULE, `Versions/Current/${MODULE}`],
    ["Headers", "Versions/Current/Headers"],
    ["Modules", "Versions/Current/Modules"],
    ["Resources", "Versions/Current/Resources"],
  ]) {
    assert.ok(lstatSync(join(fw, link)).isSymbolicLink(), `${link} is a symlink`);
    assert.equal(readlinkSync(join(fw, link)), target, `${link} -> ${target}`);
  }
  // The exact failure repair.14 hit was a real Info.plist file at the
  // framework root. lstat (not exists) so a symlink can't satisfy this.
  assert.throws(() => lstatSync(join(fw, "Info.plist")), /ENOENT/u, "no root Info.plist entry of any kind");
});

test("iOS layout stays a shallow bundle: everything at the framework root, no Versions/", () => {
  const fw = runMakeFramework("shallow");
  assert.ok(existsSync(join(fw, MODULE)), "binary at root");
  assert.ok(lstatSync(join(fw, MODULE)).isFile(), "root binary is a real file, not a symlink");
  assert.ok(existsSync(join(fw, "Headers", `${MODULE}.h`)), "headers at root");
  assert.ok(existsSync(join(fw, "Modules", "module.modulemap")), "modulemap at root");
  assert.ok(existsSync(join(fw, "Info.plist")), "flat Info.plist at root (iOS shape)");
  assert.ok(!existsSync(join(fw, "Versions")), "no Versions/ directory in a shallow bundle");
});

test("make_framework refuses a missing layout argument", () => {
  assert.throws(() => runMakeFramework(""), /layout|parameter|unbound/iu);
});

test("call sites bind layouts to the right platforms", () => {
  const source = readFileSync(SCRIPT, "utf8");
  assert.match(source, /make_framework "\$\{MAC_DIR\}\/libopenburnbar_domain_ffi\.a" "\$\{MAC_DIR\}" deep/u);
  assert.match(source, /make_framework "\$\{SIM_DIR\}\/libopenburnbar_domain_ffi\.a" "\$\{SIM_DIR\}" shallow/u);
  assert.match(source, /case "\$\{platform_id\}" in macos-\*\) fw_layout="deep" ;; esac/u);
});
