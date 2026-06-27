#!/usr/bin/env bash
#
# verify-version-consistency.sh — Fail if version surfaces diverge.
#
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

expected_version="$(grep -E '^\s+MARKETING_VERSION:' "$repo_root/project.yml" | head -1 | sed 's/.*: *//' | tr -d ' "' | tr -d "'")"

echo "Expected version (from project.yml): $expected_version"

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

homebrew_file="$repo_root/homebrew/burnbar.rb"
homebrew_version="$(sed -nE 's/^[[:space:]]*version "([^"]+)".*/\1/p' "$homebrew_file" | head -1 || true)"
homebrew_sha="$(sed -nE 's/^[[:space:]]*sha256 "([^"]+)".*/\1/p' "$homebrew_file" | head -1 || true)"
placeholder_sha="0000000000000000000000000000000000000000000000000000000000000000"
require_current_homebrew="${OPENBURNBAR_REQUIRE_CURRENT_HOMEBREW_CASK:-0}"
if [[ "${GITHUB_REF_TYPE:-}" == "tag" || "${GITHUB_REF:-}" =~ refs/tags/ ]]; then
  require_current_homebrew=1
fi
if [[ -z "$homebrew_version" ]]; then
  echo "FAIL: Homebrew cask — version not found in $homebrew_file" >&2
  fail=1
elif [[ "$homebrew_version" == "$expected_version" && "$homebrew_sha" == "$placeholder_sha" ]]; then
  echo "FAIL: Homebrew cask — version '$expected_version' still has placeholder sha256 in $homebrew_file" >&2
  echo "      Run scripts/update-homebrew.sh $expected_version after the notarized DMG exists." >&2
  fail=1
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

check "$repo_root/OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonConfiguration.swift" '.*current = "([^"]+)".*' "Daemon version enum"
check "$repo_root/SECURITY.md" '.*repo metadata \(`([^`]+)`.*' "SECURITY.md supported version"

if [[ $fail -ne 0 ]]; then
  echo "Version consistency check FAILED." >&2
  exit 1
fi

echo "Version consistency check PASSED."
