#!/usr/bin/env bash
#
# verify-version-consistency.sh — Fail if version surfaces diverge.
#
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

expected_version="$(grep -E '^\s+MARKETING_VERSION:' "$repo_root/project.yml" | head -1 | sed 's/.*: *//' | tr -d ' "' | tr -d "'")"

echo "Expected version (from project.yml): $expected_version"

requested_version="${OPENBURNBAR_EXPECTED_VERSION:-}"
if [[ -n "$requested_version" && "$requested_version" != "$expected_version" ]]; then
  echo "FAIL: requested release version — expected '$expected_version', found '$requested_version'" >&2
  fail=1
elif [[ -n "$requested_version" ]]; then
  echo "PASS: requested release version"
fi

# Windows has an independent release tag/version line. A Windows release must
# match the Win32 identity exactly without falsely advancing the macOS, mobile,
# daemon, extension, or public legal-release metadata.
requested_windows_version="${OPENBURNBAR_EXPECTED_WINDOWS_VERSION:-}"
if [[ -n "$requested_windows_version" ]]; then
  if ! [[ "$requested_windows_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "FAIL: requested Windows release version '$requested_windows_version' is not X.Y.Z" >&2
    fail=1
  else
    echo "Requested Windows release version: $requested_windows_version"
  fi
fi

check() {
  local file="$1"
  local pattern="$2"
  local desc="$3"
  local found
  found="$(sed -nE "s/$pattern/\\1/p" "$file" | head -1 || true)"
  if [[ -z "$found" ]]; then
    echo "FAIL: $desc — version not found in $file" >&2
    fail=1
    return
  fi
  if [[ "$found" != "$expected_version" ]]; then
    echo "FAIL: $desc — expected '$expected_version', found '$found' in $file" >&2
    fail=1
  else
    echo "PASS: $desc"
  fi
}

check "$repo_root/README.md" '.*Status:.*macOS `([^`]+)`.*' "README status line"
check "$repo_root/CHANGELOG.md" '^## \[([0-9][^]]*)\].*' "CHANGELOG heading"
check "$repo_root/extensions/openburnbar/package.json" '.*"version": "([^"]+)".*' "Extension package.json"
# The Safari web extension ships inside OpenBurnBar.app as an appex, so its
# version is the app's version. build.mjs stamps dist/manifest.json from
# package.json, so all three must agree with MARKETING_VERSION — dist/ drifted
# to 1.0.34 while the app shipped 1.0.40 before this gate existed.
check "$repo_root/extensions/safari/package.json" '.*"version": "([^"]+)".*' "Safari extension package.json"
check "$repo_root/extensions/safari/manifest.json" '.*"version": "([^"]+)".*' "Safari extension source manifest"
check "$repo_root/extensions/safari/dist/manifest.json" '.*"version": "([^"]+)".*' "Safari extension built manifest"

homebrew_file="$repo_root/homebrew/burnbar.rb"
homebrew_version="$(sed -nE 's/^[[:space:]]*version "([^"]+)".*/\1/p' "$homebrew_file" | head -1 || true)"
homebrew_sha="$(sed -nE 's/^[[:space:]]*sha256 "([^"]+)".*/\1/p' "$homebrew_file" | head -1 || true)"
placeholder_sha="0000000000000000000000000000000000000000000000000000000000000000"
canonical_repository="Imagine-That-Ai/BurnBar"
canonical_homebrew_url="https://github.com/${canonical_repository}/releases/download/v#{version}/OpenBurnBar-#{version}-macOS.dmg"
canonical_homebrew_homepage="https://github.com/${canonical_repository}"
require_current_homebrew="${OPENBURNBAR_REQUIRE_CURRENT_HOMEBREW_CASK:-0}"
tag_name=""
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  tag_name="${GITHUB_REF_NAME:-}"
elif [[ "${GITHUB_REF:-}" =~ ^refs/tags/(.+)$ ]]; then
  tag_name="${BASH_REMATCH[1]}"
fi
# A Windows release tag must not block on the macOS-only Homebrew cask. The
# Windows gate below enforces the Windows app identity independently; the
# macOS release workflow still requires the cask on ordinary v* tags.
if [[ -n "$tag_name" && "$tag_name" != windows-v* ]]; then
  require_current_homebrew=1
fi
if [[ -z "$homebrew_version" ]]; then
  echo "FAIL: Homebrew cask — version not found in $homebrew_file" >&2
  fail=1
elif [[ "$homebrew_version" == "$expected_version" && "$homebrew_sha" == "$placeholder_sha" ]]; then
  if [[ "$require_current_homebrew" == "1" ]]; then
    echo "FAIL: Homebrew cask — version '$expected_version' still has placeholder sha256 in $homebrew_file" >&2
    echo "      Run scripts/update-homebrew.sh $expected_version after the notarized DMG exists." >&2
    fail=1
  else
    echo "PASS: Homebrew cask deferred (version '$expected_version' has no DMG checksum until the macOS release exists)"
  fi
elif [[ "$homebrew_version" != "$expected_version" ]]; then
  if [[ "$require_current_homebrew" == "1" ]]; then
    echo "FAIL: Homebrew cask — expected '$expected_version', found '$homebrew_version' in $homebrew_file" >&2
    echo "      Run scripts/update-homebrew.sh $expected_version after the notarized DMG exists." >&2
    fail=1
  else
    echo "PASS: Homebrew cask deferred (currently '$homebrew_version'; update after v$expected_version DMG checksum exists)"
  fi
else
  echo "PASS: Homebrew cask"
fi

if ! grep -Fqx "  url \"$canonical_homebrew_url\"" "$homebrew_file"; then
  echo "FAIL: Homebrew cask — release URL must use canonical repository '$canonical_repository'" >&2
  fail=1
else
  echo "PASS: Homebrew cask release repository"
fi

if ! grep -Fqx "  homepage \"$canonical_homebrew_homepage\"" "$homebrew_file"; then
  echo "FAIL: Homebrew cask — homepage must use canonical repository '$canonical_repository'" >&2
  fail=1
else
  echo "PASS: Homebrew cask homepage repository"
fi

homebrew_updater="$repo_root/scripts/update-homebrew.sh"
if [[ ! -f "$homebrew_updater" ]]; then
  echo "FAIL: Homebrew updater — file not found at $homebrew_updater" >&2
  fail=1
elif ! grep -Fqx 'OWNER="Imagine-That-Ai"' "$homebrew_updater" \
  || ! grep -Fqx 'REPO="BurnBar"' "$homebrew_updater"; then
  echo "FAIL: Homebrew updater — release downloads must use canonical repository '$canonical_repository'" >&2
  fail=1
else
  echo "PASS: Homebrew updater release repository"
fi

check "$repo_root/OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonConfiguration.swift" '.*current = "([^"]+)".*' "Daemon version enum"
check "$repo_root/SECURITY.md" '.*repo metadata \(`([^`]+)`.*' "SECURITY.md supported version"

# ── Windows direct-download channel (deferred until the Windows release ships) ──
# The WinUI app identity version lives in windows/app/OpenBurnBar.App/app.manifest
# (assemblyIdentity version="A.B.C.D"). It is compared on its first three components against
# the requested Windows release version when supplied, otherwise the macOS marketing version.
# Like the Homebrew cask, it is DEFERRED (pass with a notice)
# until the Windows channel actually ships — the Windows app needs the W0 Authenticode cert +
# a Windows build host first — and becomes REQUIRED for windows-v* tags or when
# OPENBURNBAR_REQUIRE_CURRENT_WINDOWS_VERSION=1.
windows_manifest="$repo_root/windows/app/OpenBurnBar.App/app.manifest"
require_current_windows="${OPENBURNBAR_REQUIRE_CURRENT_WINDOWS_VERSION:-0}"
windows_expected_version="${requested_windows_version:-$expected_version}"
if [[ "$tag_name" == windows-v* ]]; then
  require_current_windows=1
fi
if [[ ! -f "$windows_manifest" ]]; then
  echo "FAIL: Windows app manifest — file not found at $windows_manifest" >&2
  fail=1
else
  # Match the 4-part assemblyIdentity version only (manifestVersion="1.0" is 2-part and the
  # leading non-letter guard excludes the "manifestVersion" attribute name).
  windows_version_full="$(sed -nE 's/.*[^A-Za-z]version="([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$windows_manifest" | head -1 || true)"
  windows_version_core="$(printf '%s' "$windows_version_full" | cut -d. -f1-3)"
  if [[ -z "$windows_version_core" ]]; then
    echo "FAIL: Windows app manifest — assemblyIdentity version not found in $windows_manifest" >&2
    fail=1
  elif [[ "$windows_version_core" == "$windows_expected_version" ]]; then
    echo "PASS: Windows app manifest"
  elif [[ "$require_current_windows" == "1" ]]; then
    echo "FAIL: Windows app manifest — expected '$windows_expected_version', found '$windows_version_core' in $windows_manifest" >&2
    echo "      Bump the assemblyIdentity version to ${windows_expected_version}.0 when cutting the Windows release." >&2
    fail=1
  else
    echo "PASS: Windows app manifest deferred (currently '$windows_version_core'; align with v$windows_expected_version when cutting that Windows release)"
  fi
fi

if [[ $fail -ne 0 ]]; then
  echo "Version consistency check FAILED." >&2
  exit 1
fi

echo "Version consistency check PASSED."
