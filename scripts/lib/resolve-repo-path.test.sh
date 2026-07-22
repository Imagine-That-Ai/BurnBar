#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$repo_root/scripts/lib/resolve-repo-path.sh"

relative="$(resolve_repo_path "/repo/root" "build/release")"
if [[ "$relative" != "/repo/root/build/release" ]]; then
  echo "FAIL: Relative release path resolved to $relative" >&2
  exit 1
fi

absolute="$(resolve_repo_path "/repo/root" "/private/tmp/release")"
if [[ "$absolute" != "/private/tmp/release" ]]; then
  echo "FAIL: Absolute release path was incorrectly prefixed: $absolute" >&2
  exit 1
fi

echo "PASS: Release output paths preserve absolute paths and anchor relative paths."
