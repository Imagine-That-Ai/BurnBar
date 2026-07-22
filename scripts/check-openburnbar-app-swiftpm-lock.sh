#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="$repo_root/OpenBurnBar.xcodeproj"
lockfile_path="$repo_root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
cache_dir="$repo_root/.spm-cache"

if [[ ! -f "$lockfile_path" ]]; then
  echo "Missing app SwiftPM lockfile at $lockfile_path" >&2
  exit 1
fi

mkdir -p "$repo_root/.derived-data"
mkdir -p "$cache_dir"

# xcodebuild's IDE project-model layer (IDEFoundation/DVTFoundation) intermittently
# aborts while loading the OpenBurnBar.xcodeproj group tree during
# -resolvePackageDependencies. It surfaces as:
#   *** -[NSMutableArray insertObjects:atIndexes:]: count of array (N) differs
#       from count of index set (N-1)
# followed by "Abort trap: 6" (exit 134). This is a transient Xcode 27 crash in
# the model-graph coalescing path, not a package-resolution failure or a repo
# defect: the same project resolves cleanly on retry with a fresh derived-data
# directory. Retry the resolve a few times so this flake can no longer wedge the
# post-test lockfile check (and, with it, the whole App XCTest harness job).
run_resolve() {
  local derived_data_dir
  # Use a unique derived-data path per invocation to avoid races when multiple
  # validator reruns run concurrently, and to give each retry a clean model graph.
  derived_data_dir="$(mktemp -d "$repo_root/.derived-data/openburnbar-lock-check.XXXXXX")"
  local status=0
  xcodebuild -resolvePackageDependencies \
    -project "$project_path" \
    -scheme "OpenBurnBar" \
    -clonedSourcePackagesDirPath "$cache_dir" \
    -derivedDataPath "$derived_data_dir" \
    >/dev/null || status=$?
  rm -rf "$derived_data_dir"
  return "$status"
}

max_attempts="${OPENBURNBAR_LOCK_CHECK_MAX_ATTEMPTS:-3}"
attempt=1
resolve_status=0
while (( attempt <= max_attempts )); do
  resolve_status=0
  run_resolve || resolve_status=$?
  if (( resolve_status == 0 )); then
    break
  fi
  # Exit 134 == SIGABRT: the known Xcode IDE model-graph crash. Anything else is a
  # real resolution failure (e.g. an unresolvable dependency) — surface it now.
  if (( resolve_status != 134 )); then
    echo "xcodebuild -resolvePackageDependencies failed with exit ${resolve_status}" >&2
    exit "$resolve_status"
  fi
  echo "xcodebuild -resolvePackageDependencies aborted (exit 134, transient Xcode IDE model-graph crash) on attempt ${attempt}/${max_attempts}; retrying with a fresh derived-data directory." >&2
  attempt=$(( attempt + 1 ))
done

if (( resolve_status != 0 )); then
  echo "xcodebuild -resolvePackageDependencies aborted (exit 134) on every one of ${max_attempts} attempts. This is the transient Xcode IDE model-graph crash, but it did not clear on retry." >&2
  exit "$resolve_status"
fi

git -C "$repo_root" diff --exit-code -- "$lockfile_path"
