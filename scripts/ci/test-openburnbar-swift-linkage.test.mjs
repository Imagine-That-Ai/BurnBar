#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const swiftHarness = readFileSync("scripts/test-openburnbar-swift.sh", "utf8");
const remoteSmokeHarness = readFileSync(
  "scripts/test-burnbar-remote-swift-smoke.sh",
  "utf8",
);
const signalBuilder = readFileSync(
  "scripts/build-signal-ffi-xcframework.sh",
  "utf8",
);

test("aggregate Core tests split colliding Rust static archives without losing native remote coverage", () => {
  assert.match(
    swiftHarness,
    /Vendor\/OpenBurnBarIroh\.xcframework[\s\S]*Vendor\/BurnBarRemote\.xcframework[\s\S]*OPENBURNBAR_DISABLE_BURNBAR_REMOTE_XCFRAMEWORK=1/u,
    "the aggregate package-test executable must contain only one Rust static runtime",
  );
  assert.match(
    swiftHarness,
    /scripts\/test-burnbar-remote-swift-smoke\.sh/u,
    "the real BurnBarRemote archive must still receive its dedicated native smoke coverage",
  );
  assert.match(
    swiftHarness,
    /OPENBURNBAR_SKIP_BURNBAR_REMOTE_SWIFT_SMOKE/u,
    "focused callers need an explicit way to skip the additional native smoke",
  );
  assert.match(
    remoteSmokeHarness,
    /OPENBURNBAR_SWIFT_SCRATCH_ROOT/u,
    "the dedicated native smoke must share the caller's concurrency-safe scratch root",
  );
});

test("macOS Swift tests build dynamic Signal FFI before linking domain-core Rust", () => {
  assert.match(
    swiftHarness,
    /SIGNAL_FFI_BUILD_TARGETS="\$\{host_target\}"[\s\S]*SIGNAL_FFI_BUILD_PROFILE=debug[\s\S]*scripts\/lib\/prepare-signal-ffi-xcframework\.sh/u,
    "the harness must request a host-target debug build through the reviewed shared preparer",
  );
  assert.match(swiftHarness, /arm64\) host_target="aarch64-apple-darwin"/u);
  assert.match(swiftHarness, /x86_64\) host_target="x86_64-apple-darwin"/u);
  assert.doesNotMatch(
    swiftHarness,
    /--crate-type staticlib/u,
    "a second Rust static archive duplicates rust_eh_personality with domain core",
  );
  assert.doesNotMatch(
    swiftHarness,
    /Vendor\/libsignal\/target\/debug/u,
    "SwiftPM must not receive the legacy static libsignal search path",
  );
});

test("warm FFI caches are validated instead of trusted on directory existence", () => {
  // The shared cache key has single-target writers (the CodeQL Swift lanes
  // build x86_64-only), so a restored XCFramework directory is not proof the
  // host architecture can link it. The harness must delegate to the shared
  // preparer, which checks the embedded target/profile metadata and rebuilds
  // on mismatch — never early-return on a bare `-d` probe.
  assert.match(
    swiftHarness,
    /scripts\/lib\/prepare-signal-ffi-xcframework\.sh/u,
    "the harness must reuse the metadata-validating shared preparer",
  );
  assert.doesNotMatch(
    swiftHarness,
    /if \[\[ -d "\$\{macos_xcframework\}"/u,
    "a bare directory probe trusts poisoned cache restores from single-target writers",
  );
});

test("SwiftPM compatibility rewrite runs before a warm FFI cache can return", () => {
  const rewrite = swiftHarness.indexOf("perl -0pi -e");
  const preparer = swiftHarness.indexOf(
    "scripts/lib/prepare-signal-ffi-xcframework.sh",
  );
  assert.ok(rewrite >= 0, "the AuthMessagesService compatibility rewrite must remain present");
  assert.ok(preparer >= 0, "the shared FFI preparer invocation must remain present");
  assert.ok(
    rewrite < preparer,
    "the compatibility rewrite must run before the preparer's warm-cache early return",
  );
});

test("single-target CodeQL Swift lane never saves the shared Signal FFI key", () => {
  // Swift CodeQL runs only on nightly codeql.yml (not codeql-pr.yml).
  const workflow = ".github/workflows/codeql.yml";
  const source = readFileSync(workflow, "utf8");
  assert.match(
    source,
    /uses:\s+actions\/cache\/restore@[0-9a-f]{40}[^\n]*\n\s+with:\n\s+path:\s+Vendor\/OpenBurnBarSignalFfiMac\.xcframework/u,
    `${workflow} must restore the Signal FFI artifact without saving it`,
  );
  assert.doesNotMatch(
    source,
    /uses:\s+actions\/cache@[0-9a-f]{40}[^\n]*\n\s+with:\n\s+path:\s+Vendor\/OpenBurnBarSignalFfiMac\.xcframework/u,
    `${workflow} builds x86_64-only and must not save under the shared superset key`,
  );
});

test("CodeQL PR gate does not run Swift (nightly-only)", () => {
  const source = readFileSync(".github/workflows/codeql-pr.yml", "utf8");
  assert.doesNotMatch(
    source,
    /^\s+- language:\s*swift\s*$/mu,
    "codeql-pr.yml must not include a Swift matrix entry; Swift stays on nightly codeql.yml",
  );
  assert.doesNotMatch(
    source,
    /prepare-signal-ffi-xcframework\.sh/u,
    "codeql-pr.yml must not build Signal FFI after Swift demotion",
  );
  assert.match(source, /^\s+- language:\s*javascript-typescript\s*$/mu);
  assert.match(source, /^\s+- language:\s*python\s*$/mu);
  assert.match(source, /^\s+- language:\s*java-kotlin\s*$/mu);
  assert.match(source, /^  merge_group:\s*$/mu);
});

test("Signal FFI caches never restore across builder-script changes", () => {
  for (const workflow of [
    ".github/workflows/app-pr-gate.yml",
    ".github/workflows/computer-use-loopback-test.yml",
    ".github/workflows/headless-app-build.yml",
    ".github/workflows/pr-native-fast.yml",
    ".github/workflows/codeql.yml",
  ]) {
    const source = readFileSync(workflow, "utf8");
    assert.doesNotMatch(
      source,
      /key:\s+\$\{\{ runner\.os \}\}-signal-ffi-[^\n]+\n\s+restore-keys:\s+\|\n\s+\$\{\{ runner\.os \}\}-signal-ffi-[^\n]+/u,
      `${workflow} must not use a broad Signal FFI restore key`,
    );
  }
});

test("the selected Signal builder keeps macOS FFI dynamic", () => {
  assert.match(signalBuilder, /macOS must stay dynamic/u);
  assert.match(
    signalBuilder,
    /stage_dynamic_target(?:_if_needed)? aarch64-apple-darwin macos-arm64/u,
  );
  assert.match(
    signalBuilder,
    /stage_dynamic_target(?:_if_needed)? x86_64-apple-darwin macos-x86_64/u,
  );
});
