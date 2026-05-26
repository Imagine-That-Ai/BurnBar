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
check "$repo_root/homebrew/burnbar.rb" '^[[:space:]]*version "([^"]+)".*' "Homebrew cask"
check "$repo_root/OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonConfiguration.swift" '.*current = "([^"]+)".*' "Daemon version enum"
check "$repo_root/SECURITY.md" '.*repo metadata \(`([^`]+)`.*' "SECURITY.md supported version"

if [[ $fail -ne 0 ]]; then
  echo "Version consistency check FAILED." >&2
  exit 1
fi

echo "Version consistency check PASSED."
