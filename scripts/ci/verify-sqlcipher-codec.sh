#!/usr/bin/env bash
# Verifies the SQLCipher codec posture for the macOS app/daemon surfaces.
# Static checks run on normal PR CI; release CI sets OPENBURNBAR_REQUIRE_SQLCIPHER_CODEC=1
# to build the Release app target, verify SQLCipher is staged and linked through
# the app bundle, run the app-level GRDB cipher gate, and run the pinned
# SQLCipher package's runtime codec probe (`PRAGMA cipher_version` must return a row).
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_pattern() {
  local pattern="$1"
  local file="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$file"; then
    fail "$message ($file)"
  fi
}

require_absent() {
  local pattern="$1"
  local file="$2"
  local message="$3"
  if grep -Eq "$pattern" "$file"; then
    fail "$message ($file)"
  fi
}

require_tree_absent() {
  local pattern="$1"
  local path="$2"
  local message="$3"
  if grep -REq "$pattern" "$path"; then
    fail "$message ($path)"
  fi
}

is_non_database_helper_binary() {
  local candidate="$1"
  case "$(basename "$candidate")" in
    OpenBurnBarPrivilegedInputExecution | \
      OpenBurnBarPrivilegedInputKillSwitchWatchdog | \
      OpenBurnBarVirtualHIDBridge)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

find_sqlcipher_release_test_bundle() {
  local scratch_path="$1"
  local bundle_name
  local bundle_path

  for bundle_name in SQLCipherPackageTests.xctest SQLCipherTests.xctest; do
    bundle_path="$(
      find "$scratch_path" \
        -type d \
        -name "$bundle_name" \
        \( -path '*/release/*' -o -path '*/Release/*' \) \
        -print \
        -quit 2>/dev/null || true
    )"
    if [[ -n "$bundle_path" ]]; then
      printf '%s\n' "$bundle_path"
      return 0
    fi
  done

  return 1
}

run_self_test() {
  local scratch
  local expected
  local actual

  scratch="$(mktemp -d)"
  trap 'rm -rf "${scratch:-}"' EXIT

  expected="${scratch}/arm64-apple-macosx/release/SQLCipherPackageTests.xctest"
  mkdir -p "$expected"
  actual="$(find_sqlcipher_release_test_bundle "$scratch")"
  [[ "$actual" == "$expected" ]] || fail "modern SwiftPM bundle discovery returned ${actual:-<empty>}"

  rm -rf "$scratch"
  scratch="$(mktemp -d)"
  expected="${scratch}/out/Products/Release/SQLCipherTests.xctest"
  mkdir -p "$expected"
  actual="$(find_sqlcipher_release_test_bundle "$scratch")"
  [[ "$actual" == "$expected" ]] || fail "legacy SwiftPM bundle discovery returned ${actual:-<empty>}"

  rm -rf "$scratch"
  scratch="$(mktemp -d)"
  mkdir -p "${scratch}/arm64-apple-macosx/debug/SQLCipherPackageTests.xctest"
  if actual="$(find_sqlcipher_release_test_bundle "$scratch")"; then
    fail "debug SwiftPM bundle was incorrectly accepted: $actual"
  fi
  rm -rf "$scratch"

  echo "PASS: SQLCipher test bundle discovery self-test passed."
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit 0
fi

require_pattern 'SQLCipher:' project.yml "project.yml must declare the SQLCipher package"
require_pattern 'https://github\.com/sqlcipher/SQLCipher\.swift\.git' project.yml "project.yml must use the official SQLCipher Swift package"
require_pattern 'exactVersion: 4\.16\.0' project.yml "project.yml must pin SQLCipher exactly"
require_pattern 'product: SQLCipher' project.yml "OpenBurnBar targets must link the SQLCipher product"
require_pattern 'SQLITE_HAS_CODEC' project.yml "OpenBurnBar targets must define SQLITE_HAS_CODEC"
require_pattern 'path: Vendor/GRDB-SQLCipher' project.yml "project.yml must use the vendored SQLCipher-backed GRDB package"
require_pattern 'OTHER_CODE_SIGN_FLAGS: --identifier com\.openburnbar\.app --options runtime,library' project.yml "daemon must share the app designated requirement for the database-key Keychain ACL"
require_pattern 'verify-daemon-release-signing\.sh' scripts/build-macos-website-release.sh "website release must run the daemon signing and executable gate"
require_pattern 'verify-daemon-release-signing\.sh' scripts/ci/verify-public-macos-download-trust.sh "public artifact verification must launch-check the signed daemon"
require_pattern 'keychain-access-groups' scripts/ci/verify-daemon-release-signing.sh "daemon verifier must reject restricted Keychain entitlements on the bare helper"
require_pattern 'Usage: OpenBurnBarDaemon' scripts/ci/verify-daemon-release-signing.sh "daemon verifier must exercise the real executable entry point"
require_pattern 'OpenBurnBarPrivilegedInputKillSwitchWatchdog' scripts/build-macos-website-release.sh "website release must sign the bundled kill-switch watchdog"
require_pattern 'timestamped Developer ID signature' scripts/ci/verify-daemon-release-signing.sh "release verifier must reject an ad-hoc kill-switch watchdog"

require_pattern 'name: "GRDB-SQLCipher"' Vendor/GRDB-SQLCipher/Package.swift "vendored GRDB package identity must be explicit"
require_pattern 'https://github\.com/sqlcipher/SQLCipher\.swift\.git' Vendor/GRDB-SQLCipher/Package.swift "vendored GRDB must depend on official SQLCipher Swift package"
require_pattern 'exact: "4\.16\.0"' Vendor/GRDB-SQLCipher/Package.swift "vendored GRDB must pin SQLCipher exactly"
require_pattern 'define\("SQLITE_HAS_CODEC"\)' Vendor/GRDB-SQLCipher/Package.swift "vendored GRDB must compile SQLCipher codec paths"
require_pattern 'define\("GRDBCIPHER"\)' Vendor/GRDB-SQLCipher/Package.swift "vendored GRDB must compile GRDBCIPHER paths"
require_pattern 'product\(name: "SQLCipher"' Vendor/GRDB-SQLCipher/Package.swift "vendored GRDB target must depend on SQLCipher"
require_pattern '@_exported import SQLCipher' Vendor/GRDB-SQLCipher/GRDB/Export.swift "vendored GRDB must export SQLCipher symbols"
require_pattern '@_exported import CSQLite' Vendor/GRDB-SQLCipher/GRDB/Export.swift "vendored GRDB must retain the local SQLite shim"
require_pattern '#include <SQLCipher/SQLCipher\.h>' Vendor/GRDB-SQLCipher/Sources/CSQLite/shim.h "vendored GRDB shim must include SQLCipher headers"
require_absent 'link "sqlite3"' Vendor/GRDB-SQLCipher/Sources/CSQLite/module.modulemap "vendored GRDB shim must not link system sqlite3"

require_pattern 'package\(path: "\.\./Vendor/GRDB-SQLCipher"\)' OpenBurnBarDaemon/Package.swift "daemon package must use vendored SQLCipher-backed GRDB"
require_pattern 'https://github\.com/sqlcipher/SQLCipher\.swift\.git' OpenBurnBarDaemon/Package.swift "daemon package must use the official SQLCipher Swift package"
require_pattern 'exact: "4\.16\.0"' OpenBurnBarDaemon/Package.swift "daemon package must pin SQLCipher exactly"
require_pattern 'product\(name: "SQLCipher"' OpenBurnBarDaemon/Package.swift "daemon target must link the SQLCipher product"
require_pattern 'define\("SQLITE_HAS_CODEC"\)' OpenBurnBarDaemon/Package.swift "daemon target must define SQLITE_HAS_CODEC"

require_pattern 'case keychainPersistenceFailed' AgentLens/Services/DataStore/DatabaseEncryptionService.swift "DatabaseEncryptionService must expose typed Keychain persistence errors"
require_pattern 'getOrCreatePersistedKey' AgentLens/Services/DataStore/DatabaseEncryptionService.swift "DatabaseEncryptionService must provide throwing persisted-key setup"
require_pattern 'migratePlaintextDatabaseIfNeeded' AgentLens/Services/DataStore/DatabaseEncryptionService.swift "DatabaseEncryptionService must migrate legacy plaintext databases"
require_pattern 'requireLinkedSQLCipherForRelease' AgentLens/Services/DataStore/DatabaseEncryptionService.swift "DatabaseEncryptionService must expose a release SQLCipher gate"
require_pattern 'getOrCreatePersistedKey' AgentLens/Services/DataStore/DataStoreCoordinator.swift "DataStoreCoordinator must use the throwing persisted-key setup"
require_pattern 'migratePlaintextDatabaseIfNeeded' AgentLens/Services/DataStore/DataStoreCoordinator.swift "DataStoreCoordinator must run first-launch plaintext migration"
require_absent 'openDisclosedPlaintext|PlaintextFallbackAcknowledgement' AgentLens/Services/DataStore/DataStoreCoordinator.swift "encryption-requested startup must not keep plaintext fallback code"

require_pattern 'testGetOrCreatePersistedKey_throwsTypedErrorWhenKeychainAddFails' AgentLensTests/Active/DatabaseEncryptionServiceTests.swift "Keychain failure regression test is missing"
require_pattern 'testGRDBRuntimeReportsSQLCipherVersion' AgentLensTests/Active/DatabaseEncryptionServiceTests.swift "GRDB SQLCipher runtime regression test is missing"
require_pattern 'testKeyedOpen_writesEncryptedDatabase' AgentLensTests/Active/DatabaseEncryptionServiceTests.swift "keyed-open encryption regression test is missing"
require_pattern 'testReleaseGateRequiresActiveSQLCipherWhenEnabled' AgentLensTests/Active/DatabaseEncryptionServiceTests.swift "release SQLCipher regression test is missing"
require_pattern 'testCoordinatorMigratesLegacyPlaintextDatabaseWhenEncryptionPreferenceIsFalse' AgentLensTests/Active/DatabaseEncryptionServiceTests.swift "plaintext migration/rejection regression test is missing"

require_tree_absent '(^|[^[:alnum:]_])(sqlite3|GRDB|DatabaseQueue|DatabasePool|OpenBurnBarDataStore|BurnBarDaemonDatabaseCipher)([^[:alnum:]_]|$)' \
  OpenBurnBarDaemon/Sources/OpenBurnBarPrivilegedInputExecution \
  "privileged input execution helper must remain outside the database boundary"
require_tree_absent '(^|[^[:alnum:]_])(sqlite3|GRDB|DatabaseQueue|DatabasePool|OpenBurnBarDataStore|BurnBarDaemonDatabaseCipher)([^[:alnum:]_]|$)' \
  OpenBurnBarDaemon/Sources/OpenBurnBarPrivilegedInputKillSwitchWatchdog \
  "privileged input kill-switch watchdog must remain outside the database boundary"
require_tree_absent '(^|[^[:alnum:]_])(sqlite3|GRDB|DatabaseQueue|DatabasePool|OpenBurnBarDataStore|BurnBarDaemonDatabaseCipher)([^[:alnum:]_]|$)' \
  OpenBurnBarDaemon/Sources/OpenBurnBarVirtualHIDBridge \
  "virtual HID bridge helper must remain outside the database boundary"

if [[ "${OPENBURNBAR_REQUIRE_SQLCIPHER_CODEC:-}" == "1" ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "OPENBURNBAR_REQUIRE_SQLCIPHER_CODEC=1 requires a macOS runner"
  fi

  derived_data="${TMPDIR:-/tmp}/openburnbar-sqlcipher-codec-${RANDOM}-${RANDOM}"
  mkdir -p "$derived_data"
  sqlcipher_package=".spm-cache-new/checkouts/SQLCipher.swift"

  cleanup() {
    rm -rf "$derived_data"
  }
  trap cleanup EXIT

  bash scripts/lib/prepare-signal-ffi-xcframework.sh

  xcodebuild build \
    -quiet \
    -project OpenBurnBar.xcodeproj \
    -scheme OpenBurnBar \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -clonedSourcePackagesDirPath .spm-cache-new \
    -derivedDataPath "$derived_data" \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    SWIFT_COMPILATION_MODE=singlefile \
    SWIFT_ENABLE_BATCH_MODE=NO \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO

  app_bundle="${derived_data}/Build/Products/Release/OpenBurnBar.app"
  app_binary="${app_bundle}/Contents/MacOS/OpenBurnBar"
  if [[ ! -x "$app_binary" ]]; then
    fail "Release app binary was not produced at $app_binary"
  fi
  if ! find "${derived_data}/Build/Products/Release" -path '*SQLCipher.framework*' -print -quit | grep -q .; then
    fail "Release app build did not stage SQLCipher.framework"
  fi

  sqlcipher_loader_found=0
  system_sqlite_loaders=()
  external_sqlcipher_loaders=()
  while IFS= read -r -d '' candidate; do
    if ! file "$candidate" | grep -q 'Mach-O'; then
      continue
    fi
    deps="$(otool -L "$candidate" 2>/dev/null || true)"
    if grep -q 'SQLCipher.framework' <<<"$deps"; then
      sqlcipher_loader_found=1
    fi
    if grep -Eq 'libsqlcipher[^/]*\.dylib' <<<"$deps"; then
      external_sqlcipher_loaders+=("$candidate")
    fi
    if grep -q '/usr/lib/libsqlite3.dylib' <<<"$deps"; then
      if is_non_database_helper_binary "$candidate"; then
        continue
      fi
      system_sqlite_loaders+=("$candidate")
    fi
  done < <(find "$app_bundle" -type f -print0)

  if [[ "$sqlcipher_loader_found" != "1" ]]; then
    fail "Release app bundle has no Mach-O image loading SQLCipher.framework"
  fi
  if [[ "${#external_sqlcipher_loaders[@]}" -gt 0 ]]; then
    printf 'FAIL: Release app bundle still links an external SQLCipher dylib from:\n' >&2
    printf '  - %s\n' "${external_sqlcipher_loaders[@]}" >&2
    exit 1
  fi
  if [[ "${#system_sqlite_loaders[@]}" -gt 0 ]]; then
    printf 'FAIL: Release app bundle still links system sqlite3 from:\n' >&2
    printf '  - %s\n' "${system_sqlite_loaders[@]}" >&2
    exit 1
  fi
  if [[ ! -d "$sqlcipher_package" ]]; then
    fail "SQLCipher.swift checkout missing after Release build"
  fi
  sqlcipher_framework_dir=".spm-cache-new/artifacts/sqlcipher.swift/SQLCipher/SQLCipher.xcframework/macos-arm64_x86_64"
  if [[ ! -d "${sqlcipher_framework_dir}/SQLCipher.framework" ]]; then
    fail "SQLCipher macOS framework artifact missing after Release build"
  fi

  sqlcipher_scratch="${derived_data}/sqlcipher-package-build"
  swift build \
    --package-path "$sqlcipher_package" \
    --configuration release \
    --scratch-path "$sqlcipher_scratch" \
    --build-tests
  if ! sqlcipher_test_bundle="$(find_sqlcipher_release_test_bundle "$sqlcipher_scratch")"; then
    echo "SQLCipher Release test bundles found under scratch path:" >&2
    find "$sqlcipher_scratch" -type d -name '*.xctest' -print >&2 || true
    fail "SQLCipher Release test bundle was not produced"
  fi
  mkdir -p "${sqlcipher_test_bundle}/Contents/Frameworks"
  cp -R "${sqlcipher_framework_dir}/SQLCipher.framework" "${sqlcipher_test_bundle}/Contents/Frameworks/"
  swift test \
    --package-path "$sqlcipher_package" \
    --configuration release \
    --scratch-path "$sqlcipher_scratch" \
    --skip-build

  OPENBURNBAR_REQUIRE_SQLCIPHER_CODEC=1 ./scripts/test-openburnbar-app.sh \
    -only-testing:OpenBurnBarTests/DatabaseEncryptionServiceTests/testReleaseGateRequiresActiveSQLCipherWhenEnabled
fi

echo "PASS: SQLCipher codec policy checks passed."
