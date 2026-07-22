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
