#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const swiftHarness = readFileSync("scripts/test-openburnbar-swift.sh", "utf8");
const libsignalCompat = readFileSync(
  "scripts/lib/libsignal-swift-compat.sh",
  "utf8",
);
const xcodeSourceClassification = readFileSync(
  "scripts/lib/xcode-source-classification.sh",
  "utf8",
);
const xcodeSourceClassificationConfig = readFileSync(
  "scripts/lib/xcode-source-classification.xcconfig",
  "utf8",
);
const googleSignInCompat = readFileSync(
  "scripts/lib/googlesignin-macos-compat.sh",
  "utf8",
);
const signalBuilder = readFileSync(
  "scripts/build-signal-ffi-xcframework.sh",
  "utf8",
);

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

test("SwiftPM compatibility rewrites run before a warm FFI cache can return", () => {
  const compatPreparation = swiftHarness.indexOf(
    "openburnbar_prepare_libsignal_swift_compat",
  );
  const preparer = swiftHarness.indexOf(
    "scripts/lib/prepare-signal-ffi-xcframework.sh",
  );
  assert.ok(
    compatPreparation >= 0,
    "the checksum-bound LibSignal compatibility preparation must remain present",
  );
  assert.match(
    libsignalCompat,
    /withExtendedLifetime\(contents\) \{\}/u,
    "the AuthMessagesService compatibility edit must remain exact",
  );
  assert.match(
    libsignalCompat,
    /PromiseStruct & SendableMetatype/u,
    "the TokioAsyncContext metatype-safety edit must remain exact",
  );
  assert.ok(preparer >= 0, "the shared FFI preparer invocation must remain present");
  assert.ok(
    compatPreparation < preparer,
    "compatibility preparation must run before the preparer's warm-cache early return",
  );
  assert.match(
    swiftHarness,
    /openburnbar_restore_libsignal_swift_compat/u,
    "the Swift wrapper must restore the public submodule on exit",
  );
  assert.match(
    libsignalCompat,
    /Refusing to overwrite an unknown TokioAsyncContext\.swift edit/u,
    "interrupted-run recovery must fail closed on unknown source changes",
  );
});

test("canonical Xcode entry points repair transitive package inventories without warning suppression", () => {
  assert.match(
    xcodeSourceClassificationConfig,
    /EXCLUDED_SOURCE_FILE_NAMES = \*\.inc \*\.lds \*\.podspec\.gen\.py/u,
    "Abseil include fragments and package metadata must not be treated as standalone sources",
  );
  assert.doesNotMatch(
    xcodeSourceClassificationConfig,
    /GIDAppCheckError|GIDSignInButton/u,
    "GoogleSignIn public headers must remain in the package inventory",
  );
  assert.match(
    xcodeSourceClassification,
    /OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS=\(\s+-xcconfig/u,
    "Abseil source classification must flow through Xcode's xcconfig parser",
  );
  assert.match(
    xcodeSourceClassification,
    /source "\$_openburnbar_xcode_source_classification_dir\/googlesignin-macos-compat\.sh"/u,
    "the shared Xcode contract must load GoogleSignIn's compatibility lifecycle",
  );
  assert.match(
    googleSignInCompat,
    /65fb3f1aa6ffbfdc79c4e22178a55cd91561f5e9/u,
    "GoogleSignIn compatibility must remain bound to the locked 8.0.0 revision",
  );
  assert.match(
    googleSignInCompat,
    /cb46fbe32639d27db6f8ba9eaaa457525a407816f82265050da211821dadecbd/u,
    "GoogleSignIn compatibility must verify the reviewed original umbrella hash",
  );
  assert.match(
    googleSignInCompat,
    /ff4060c31e9770fc45d2a276d794543aac3adf06ecd29036336dee2484ac9026/u,
    "GoogleSignIn compatibility must verify the reviewed patched umbrella hash",
  );
  assert.match(
    googleSignInCompat,
    /Refusing to overwrite an unknown GoogleSignIn\.h edit/u,
    "interrupted compatibility recovery must fail closed on unknown header changes",
  );
  assert.doesNotMatch(
    `${xcodeSourceClassification}\n${xcodeSourceClassificationConfig}\n${googleSignInCompat}`,
    /-Wno-|CLANG_WARN_[A-Z_]+=NO|SWIFT_SUPPRESS_WARNINGS/u,
    "transitive package compatibility must not become warning suppression",
  );

  for (const script of [
    "scripts/test-openburnbar-app.sh",
    "scripts/build.sh",
    "scripts/ci/headless-app-build.sh",
    "scripts/check-openburnbar-swift-warnings.sh",
    "scripts/dev-mac.sh",
    "scripts/build-macos-app-store-release.sh",
    "scripts/build-macos-website-release.sh",
  ]) {
    const source = readFileSync(script, "utf8");
    assert.match(
      source,
      /source .*scripts\/lib\/xcode-source-classification\.sh/u,
      `${script} must source the shared Xcode source-classification contract`,
    );
    assert.match(
      source,
      /"\$\{OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS\[@\]\}"/u,
      `${script} must pass the shared xcconfig argument to xcodebuild`,
    );
    assert.match(
      source,
      /xcodebuild -resolvePackageDependencies/u,
      `${script} must resolve the locked package graph before patching its checkout`,
    );
    assert.match(
      source,
      /openburnbar_prepare_google_sign_in_macos_compat/u,
      `${script} must prepare the checksum-bound GoogleSignIn umbrella repair`,
    );
    assert.match(
      source,
      /openburnbar_restore_google_sign_in_macos_compat/u,
      `${script} must restore the GoogleSignIn checkout on exit`,
    );
    assert.match(
      source,
      /-disableAutomaticPackageResolution/u,
      `${script} must keep Xcode from replacing the prepared checkout mid-build`,
    );
    assert.match(
      source,
      /-clonedSourcePackagesDirPath/u,
      `${script} must bind resolution and build to the same package cache`,
    );
    assert.match(
      source,
      /openburnbar_configure_xcode_process_tmpdir/u,
      `${script} must keep Xcode and SwiftPM workspace locks on a writable local TMPDIR`,
    );
  }
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

test("daemon tests stage verified SQLCipher before building the XCTest graph", () => {
  const daemonBranch = swiftHarness.slice(
    swiftHarness.indexOf(
      'if [[ "$package_path" == "$repo_root/OpenBurnBarDaemon" ]]',
    ),
  );
  const plan = daemonBranch.indexOf("--plan-only");
  const firstStage = daemonBranch.indexOf(
    'python3 "$repo_root/scripts/lib/stage_sqlcipher_framework.py" "${stage_args[@]}"',
    plan,
  );
  const build = daemonBranch.indexOf('swift build "${build_args[@]}"');
  const verifyAfterBuild = daemonBranch.indexOf(
    'python3 "$repo_root/scripts/lib/stage_sqlcipher_framework.py" "${stage_args[@]}"',
    firstStage + 1,
  );
  const test = daemonBranch.indexOf('swift test "${args[@]}" --skip-build');

  assert.ok(plan >= 0, "the wrapper must plan framework replacement");
  assert.ok(firstStage > plan, "the framework must be staged after its plan");
  assert.ok(build > firstStage, "SQLCipher must be staged before XCTest compilation");
  assert.ok(
    verifyAfterBuild > build,
    "the staged framework must be re-verified after SwiftPM finishes the build",
  );
  assert.ok(test > verifyAfterBuild, "tests must run only after post-build verification");
  assert.match(
    daemonBranch,
    /swift package "\$\{package_args\[@\]\}" clean/u,
    "replacement in an existing scratch must clean its exact SwiftPM build graph",
  );
  assert.doesNotMatch(
    daemonBranch,
    /rm -rf/u,
    "the wrapper must never broadly delete a caller-selected scratch tree",
  );
});
