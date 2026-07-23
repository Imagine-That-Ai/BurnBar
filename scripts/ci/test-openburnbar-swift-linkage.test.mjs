#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const swiftHarness = readFileSync("scripts/test-openburnbar-swift.sh", "utf8");
const signalBuilder = readFileSync(
  "scripts/build-signal-ffi-xcframework.sh",
  "utf8",
);

test("macOS Swift tests build dynamic Signal FFI before linking domain-core Rust", () => {
  assert.match(
    swiftHarness,
    /SIGNAL_FFI_BUILD_TARGETS="\$\{host_target\}"[\s\S]*SIGNAL_FFI_BUILD_PROFILE=debug[\s\S]*build-signal-ffi-xcframework\.sh/u,
    "the fallback must use the reviewed macOS dynamic Signal XCFramework builder",
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

test("SwiftPM compatibility rewrite runs before a warm FFI cache can return", () => {
  const rewrite = swiftHarness.indexOf("perl -0pi -e");
  const cacheProbe = swiftHarness.indexOf(
    'if [[ -d "${macos_xcframework}" || -d "${legacy_xcframework}" ]]',
  );
  assert.ok(rewrite >= 0, "the AuthMessagesService compatibility rewrite must remain present");
  assert.ok(cacheProbe >= 0, "the XCFramework cache probe must remain present");
  assert.ok(
    rewrite < cacheProbe,
    "the compatibility rewrite must run before the warm-cache early return",
  );
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
    /stage_dynamic_target aarch64-apple-darwin macos-arm64/u,
  );
  assert.match(
    signalBuilder,
    /stage_dynamic_target x86_64-apple-darwin macos-x86_64/u,
  );
});
