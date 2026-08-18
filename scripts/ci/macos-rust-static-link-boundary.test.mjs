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
const grdbSQLCipherPackageManifest = readFileSync(
  join(repositoryRoot, "Vendor/GRDB-SQLCipher/Package.swift"),
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

test("standalone daemon and CLI builds scope out the second Rust static runtime", () => {
  const daemonBuildPattern = new RegExp(
    `${seam}=1 swift build --package-path \\$\\(DAEMON_PACKAGE\\) -c release --product \\$\\(DAEMON_BIN\\)`,
    "gu",
  );
  const cliBuildPattern = new RegExp(
    `${seam}=1 swift build --package-path \\$\\(DAEMON_PACKAGE\\) -c release --product \\$\\(DAEMON_CLI_BIN\\)`,
    "gu",
  );
  assert.equal(
    [...makefile.matchAll(daemonBuildPattern)].length,
    2,
    "both build and build-signed must apply the seam to the standalone daemon",
  );
  assert.equal(
    [...makefile.matchAll(cliBuildPattern)].length,
    2,
    "both build and build-signed must apply the seam to the signed daemon CLI",
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
    /export FIREBASE_SOURCE_FIRESTORE="\$\{FIREBASE_SOURCE_FIRESTORE:-1\}"/u,
    "release smoke must preserve the repository's source-Firestore package graph",
  );
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
      < releaseSmoke.indexOf('make -C "$repo_root" build-signed'),
    "the seam must be cleared before the Release app build",
  );
  assert.doesNotMatch(releaseSmoke, new RegExp(`export ${seam}`, "u"));
});

test("release smoke exercises the signed daemon through the signed installed-layout CLI", () => {
  assert.match(
    releaseSmoke,
    /OpenBurnBar Release smoke requires an Apple Development code-signing identity/u,
  );
  assert.match(releaseSmoke, /make -C "\$repo_root" build-signed/u);
  assert.match(
    releaseSmoke,
    /cli_bin="\$app_path\/Contents\/Helpers\/OpenBurnBarCLI"/u,
  );
  assert.match(
    releaseSmoke,
    /installed_cli_bin="\$installed_daemon_dir\/OpenBurnBarCLI"/u,
  );
  assert.match(releaseSmoke, /--socket-auth-token-file/u);
  assert.match(
    releaseSmoke,
    /OPENBURNBAR_DAEMON_SOCKET_PATH="\$socket_path"/u,
  );
  assert.match(releaseSmoke, /python3 - "\$installed_cli_bin"/u);
  assert.match(releaseSmoke, /\[cli, "health"\]/u);
  assert.match(
    releaseSmoke,
    /Authenticated daemon health RPC passed via installed-layout OpenBurnBarCLI/u,
  );
  assert.doesNotMatch(releaseSmoke, /import socket/u);
  assert.doesNotMatch(releaseSmoke, /"method": "daemon\.health"/u);
  assert.doesNotMatch(
    releaseSmoke,
    /"OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN": "\$\{socket_auth_token\}"/u,
  );
});

test("Apple daemon builds use the packaged SQLCipher framework without a second system runtime", () => {
  assert.match(
    grdbSQLCipherPackageManifest,
    /pkgConfig: useSystemSQLCipher && explicitSQLCipherLibrary == nil \? "sqlcipher" : nil/u,
    "pkg-config must be limited to explicit system-SQLCipher builds",
  );
  assert.match(
    grdbSQLCipherPackageManifest,
    /The SQLCipher\.swift binary target supplies the Apple-platform/u,
  );
  assert.doesNotMatch(
    grdbSQLCipherPackageManifest,
    /pkgConfig: explicitSQLCipherLibrary == nil \? "sqlcipher" : nil/u,
    "default Apple builds must not inherit a machine-local Homebrew SQLCipher dylib",
  );
});

test("release smoke verifies the core runtime according to the actual Mach-O graph", () => {
  assert.match(
    releaseSmoke,
    /verify_optional_runtime_dependency\(\) \{[\s\S]*otool -L "\$binary" \| grep -Fq "\$dependency_fragment"/u,
  );
  assert.match(
    releaseSmoke,
    /Verified \$description is statically linked into \$binary/u,
  );
  assert.match(
    releaseSmoke,
    /verify_optional_runtime_dependency \\\n  "\$daemon_bin" \\\n  "libOpenBurnBarCore\.dylib"/u,
  );
  assert.match(
    releaseSmoke,
    /verify_optional_runtime_dependency \\\n  "\$app_bin" \\\n  "OpenBurnBarCore\.framework"/u,
  );
  assert.doesNotMatch(
    releaseSmoke,
    /if \[\[ ! -f "\$daemon_core_dylib" \]\]/u,
  );
  assert.doesNotMatch(
    releaseSmoke,
    /if \[\[ ! -d "\$app_core_framework" \]\]/u,
  );
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
