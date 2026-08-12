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

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-release-paths.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
mkdir -p "$repo"
repo="$(cd "$repo" && pwd -P)"
fixture_root="$(cd "$fixture_root" && pwd -P)"

relative_release="$(
  resolve_fresh_release_output_dir \
    "$repo" \
    "build/macos-website-1.2.3-456" \
    "Website release directory"
)"
if [[ "$relative_release" != "$repo/build/macos-website-1.2.3-456" ]]; then
  echo "FAIL: Fresh relative release path resolved to $relative_release" >&2
  exit 1
fi

external_release="$(
  resolve_fresh_release_output_dir \
    "$repo" \
    "$fixture_root/openburnbar-mas-candidate" \
    "Mac App Store release directory"
)"
if [[ "$external_release" != "$fixture_root/openburnbar-mas-candidate" ]]; then
  echo "FAIL: Fresh external release path resolved to $external_release" >&2
  exit 1
fi

expect_rejected() {
  local path="$1"
  local expected="$2"
  local output
  if output="$(
    resolve_fresh_release_output_dir "$repo" "$path" "Release directory" 2>&1
  )"; then
    echo "FAIL: Unsafe release path was accepted: $path" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "FAIL: Unsafe release path '$path' did not report '$expected':" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

expect_rejected "/" "filesystem root"
expect_rejected "$repo" "dedicated directory"
expect_rejected "$repo/build" "dedicated directory"
expect_rejected "$fixture_root" "must not contain the repository"
expect_rejected "$repo/docs/release" "inside the repository must be under"

mkdir -p "$repo/build/existing" "$fixture_root/real-parent"
expect_rejected "$repo/build/existing" "fresh path"

ln -s "$fixture_root/real-parent" "$fixture_root/symlink-parent"
expect_rejected \
  "$fixture_root/symlink-parent/openburnbar-release" \
  "must not traverse a symlink"

echo "PASS: Release paths are anchored, fresh, dedicated, and symlink-safe."
