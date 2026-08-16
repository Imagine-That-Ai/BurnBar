#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = join(scriptDirectory, "..", "..");
const makefile = readFileSync(join(repositoryRoot, "Makefile"), "utf8");
const releaseSmoke = readFileSync(
  join(repositoryRoot, "scripts/test-openburnbar-release-smoke.sh"),
  "utf8",
);
const corePackageManifest = readFileSync(
  join(repositoryRoot, "OpenBurnBarCore/Package.swift"),
  "utf8",
);
const remoteEngineSupport = readFileSync(
  join(
    repositoryRoot,
    "OpenBurnBarCore/Sources/BurnBarRemoteEngine/BurnBarRemoteEngineSupport.swift",
  ),
  "utf8",
);
const seam = "OPENBURNBAR_DISABLE_BURNBAR_REMOTE_XCFRAMEWORK";
const remoteFeature = "OPENBURNBAR_HAS_BURNBAR_REMOTE_FFI";

test("standalone daemon builds scope out the second Rust static runtime", () => {
  const daemonBuildPattern = new RegExp(
    `${seam}=1 swift build --package-path \\$\\(DAEMON_PACKAGE\\) -c release`,
    "gu",
  );
  assert.equal(
    [...makefile.matchAll(daemonBuildPattern)].length,
    2,
    "both build and build-signed must apply the seam only to the standalone daemon",
  );
});

test("Xcode app resolution and builds always restore the full binary graph", () => {
  const xcodeLines = makefile
    .split("\n")
    .filter((line) => /^\s*(?:\/usr\/bin\/env\b.*\s)?xcodebuild(?:\s|$)/u.test(line));
  assert.ok(xcodeLines.length >= 4, "expected package-resolution and app-build xcodebuild lines");
  for (const line of xcodeLines) {
    assert.match(
      line,
      new RegExp(`/usr/bin/env -u ${seam} xcodebuild`, "u"),
      `Xcode invocation inherited the standalone-daemon seam: ${line.trim()}`,
    );
  }
});

test("release smoke clears the seam before app and release-build proofs", () => {
  assert.match(
    releaseSmoke,
    new RegExp(`${seam}=1 \\\\\\n  "\\$repo_root/scripts/test-openburnbar-swift\\.sh"`, "u"),
  );
  assert.match(releaseSmoke, new RegExp(`unset ${seam}`, "u"));
  assert.ok(
    releaseSmoke.indexOf(`unset ${seam}`)
      < releaseSmoke.indexOf("OPENBURNBAR_APP_TEST_ATTEMPTS="),
    "the seam must be cleared before app tests",
  );
  assert.ok(
    releaseSmoke.indexOf(`unset ${seam}`)
      < releaseSmoke.indexOf('make -C "$repo_root" build'),
    "the seam must be cleared before the Release app build",
  );
  assert.doesNotMatch(releaseSmoke, new RegExp(`export ${seam}`, "u"));
});

test("remote-engine compilation follows the manifest graph instead of stale module discovery", () => {
  assert.match(
    corePackageManifest,
    new RegExp(
      `let burnBarRemoteEngineSwiftSettings: \\[SwiftSetting\\] = hasBurnBarRemoteXCFramework \\? \\[\\s+\\.define\\("${remoteFeature}"\\)\\s+\\] : \\[\\]`,
      "u",
    ),
  );
  assert.match(
    corePackageManifest,
    /name: "BurnBarRemoteEngine",\s+dependencies: burnBarRemoteEngineDependencies,\s+swiftSettings: burnBarRemoteEngineSwiftSettings/u,
  );
  assert.match(remoteEngineSupport, new RegExp(`#if ${remoteFeature}`, "u"));
  assert.doesNotMatch(
    remoteEngineSupport,
    /canImport\(BurnBarRemoteFFI\)/u,
    "a warm SwiftPM cache can make canImport see a wrapper excluded from the current manifest graph",
  );
});
