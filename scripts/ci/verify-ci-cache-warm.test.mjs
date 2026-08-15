#!/usr/bin/env node
/**
 * Contract tests for .github/workflows/ci-cache-warm.yml.
 *
 * Caches written on PR/MQ refs are invisible to other refs. This warm workflow
 * is the only writer that puts Signal FFI + SPM entries on `main` so every
 * App PR Gate / merge-queue restore can hit. These assertions pin the trigger
 * paths and the exact consumer key/path expressions so a drift cannot silently
 * re-cold every MQ candidate.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const WARM = ".github/workflows/ci-cache-warm.yml";
const APP_GATE = ".github/workflows/app-pr-gate.yml";

const SPM_HASH_FILES =
  "hashFiles('OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', 'OpenBurnBarCore/Package.resolved', 'OpenBurnBarDaemon/Package.resolved', 'Vendor/GRDB-SQLCipher/Package.resolved')";

const APP_SPM_KEY = '${{ runner.os }}-app-spm-${{ ' + SPM_HASH_FILES + ' }}';
const MOBILE_SPM_KEY = '${{ runner.os }}-mobile-spm-${{ ' + SPM_HASH_FILES + ' }}';

const PACKAGE_RESOLVED_TRIGGERS = [
  "OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
  "OpenBurnBarCore/Package.resolved",
  "OpenBurnBarDaemon/Package.resolved",
  "Vendor/GRDB-SQLCipher/Package.resolved",
];

const warm = readFileSync(WARM, "utf8");
const appGate = readFileSync(APP_GATE, "utf8");

test("ci-cache-warm keeps daily cron + workflow_dispatch", () => {
  assert.match(warm, /^\s+- cron:\s+"0 7 \* \* \*"\s*$/mu);
  assert.match(warm, /^  workflow_dispatch:\s*$/mu);
  assert.match(warm, /^  push:\s*$/mu);
  assert.match(warm, /^\s+branches:\s*\[main\]\s*$/mu);
});

test("ci-cache-warm push.paths cover Signal FFI inputs and Package.resolved locks", () => {
  for (const path of [
    "Vendor/libsignal",
    ".gitmodules",
    "scripts/build-signal-ffi-xcframework.sh",
    "scripts/lib/prepare-signal-ffi-xcframework.sh",
    ".github/workflows/ci-cache-warm.yml",
    ...PACKAGE_RESOLVED_TRIGGERS,
  ]) {
    assert.match(
      warm,
      new RegExp(`^\\s+- "${path.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\$&")}"\\s*$`, "mu"),
      `${WARM} push.paths must include ${path}`,
    );
  }
});

test("Signal FFI warm job stays on hosted macos-26 with consumer keys", () => {
  assert.match(warm, /^  signal-ffi:\s*$/mu);
  assert.match(
    warm,
    /key:\s+\$\{\{ runner\.os \}\}-signal-ffi-macos-\$\{\{ steps\.signal-ffi-cache\.outputs\.sha \}\}-\$\{\{ hashFiles\('scripts\/build-signal-ffi-xcframework\.sh', 'scripts\/lib\/prepare-signal-ffi-xcframework\.sh'\) \}\}/u,
  );
  assert.match(
    warm,
    /key:\s+\$\{\{ runner\.os \}\}-signal-ffi-ios-\$\{\{ steps\.signal-ffi-cache\.outputs\.sha \}\}-\$\{\{ hashFiles\('scripts\/build-signal-ffi-xcframework\.sh', 'scripts\/lib\/prepare-signal-ffi-xcframework\.sh'\) \}\}/u,
  );
  // Warm must never route through MACOS_GATE_POOL (must stay free / hosted image).
  assert.doesNotMatch(
    warm,
    /vars\.MACOS_GATE_POOL|runs-on:\s*\$\{\{\s*vars\.MACOS_GATE_POOL/u,
    "ci-cache-warm must not route via MACOS_GATE_POOL",
  );
  const signalJob = warm.split(/^  spm:\s*$/mu)[0] ?? warm;
  assert.match(signalJob, /^\s+runs-on:\s+macos-26\s*$/mu);
});

test("SPM warm job saves the exact app-pr-gate app-spm and mobile-spm keys", () => {
  assert.match(warm, /^  spm:\s*$/mu);
  assert.match(warm, /^\s+runs-on:\s+macos-26\s*$/mu);

  assert.equal(
    (appGate.match(new RegExp(APP_SPM_KEY.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g")) || []).length,
    1,
    `${APP_GATE} must declare the AgentLens app-spm key exactly once`,
  );
  assert.equal(
    (appGate.match(new RegExp(MOBILE_SPM_KEY.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g")) || []).length,
    1,
    `${APP_GATE} must declare the Mobile mobile-spm key exactly once`,
  );

  // Warm saves (and restores) each key; require at least one save occurrence each.
  assert.match(warm, new RegExp(APP_SPM_KEY.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "u"));
  assert.match(warm, new RegExp(MOBILE_SPM_KEY.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "u"));
  assert.equal(
    (warm.match(new RegExp(APP_SPM_KEY.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g")) || []).length,
    2,
    `${WARM} must restore+save app-spm with the consumer key (2 occurrences)`,
  );
  assert.equal(
    (warm.match(new RegExp(MOBILE_SPM_KEY.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g")) || []).length,
    2,
    `${WARM} must restore+save mobile-spm with the consumer key (2 occurrences)`,
  );
});

test("SPM warm paths cover consumer checkout/download caches without a full app build", () => {
  const spmSection = warm.split(/^  spm:\s*$/mu)[1] ?? "";
  assert.ok(spmSection.length > 0, `${WARM} must define an spm job`);

  for (const path of [".spm-cache-new", ".derived-data", "~/.cache/org.swift.swiftpm"]) {
    assert.match(
      spmSection,
      new RegExp(`^\\s+${path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*$`, "mu"),
      `spm job must cache ${path}`,
    );
  }

  assert.match(
    spmSection,
    /xcodebuild -resolvePackageDependencies/u,
    "prefer resolvePackageDependencies over a full app build for SPM warm",
  );
  assert.doesNotMatch(
    spmSection,
    /^\s+xcodebuild (?:build|build-for-testing|test)\b/mu,
    "SPM warm must not run a full app compile",
  );
  assert.match(
    spmSection,
    /FIREBASE_SOURCE_FIRESTORE/u,
    "resolve must pin the source-built Firestore graph",
  );
  assert.match(
    spmSection,
    /-clonedSourcePackagesDirPath \.spm-cache-new/u,
  );
});
