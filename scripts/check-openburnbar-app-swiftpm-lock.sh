#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="$repo_root/OpenBurnBar.xcodeproj"
lockfile_path="$repo_root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
cache_dir="$repo_root/.spm-cache"

# The committed graph deliberately pins source-built Firestore. Firebase's
# default binary graph uses grpc-binary, which crashes on the supported iOS 27
# runtime. This verifier must therefore resolve the same safe graph regardless
# of the caller's inherited environment.
export FIREBASE_SOURCE_FIRESTORE=1

if [[ ! -f "$lockfile_path" ]]; then
  echo "Missing app SwiftPM lockfile at $lockfile_path" >&2
  exit 1
fi

mkdir -p "$repo_root/.derived-data"
mkdir -p "$cache_dir"

# Package.resolved is shared mutable state for every invocation running in this
# checkout. Without whole-check mutual exclusion, a failing invocation can
# restore its clean snapshot while a concurrently succeeding invocation is
# between writing legitimate resolver drift and diffing it, masking real drift
# as a clean exit. Serialize the entire snapshot/resolve/restore/diff sequence
# behind a directory lock so concurrent validator reruns queue instead of
# interleaving.
lock_dir="$repo_root/.derived-data/openburnbar-lock-check.lock"
lock_wait_seconds="${OPENBURNBAR_LOCK_CHECK_LOCK_WAIT_SECONDS:-1800}"
lock_acquired=0
lockfile_snapshot=""

acquire_lock() {
  local deadline=$(( SECONDS + lock_wait_seconds ))
  while ! mkdir "$lock_dir" 2>/dev/null; do
    local holder_pid=""
    if [[ -f "$lock_dir/pid" ]]; then
      holder_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    fi
    if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
      # The previous holder died without releasing (e.g. SIGKILL). Reclaim the
      # lock; if several waiters race here, exactly one wins the next mkdir.
      rm -rf "$lock_dir"
      continue
    fi
    if (( SECONDS >= deadline )); then
      echo "Timed out after ${lock_wait_seconds}s waiting for the SwiftPM lockfile check lock at ${lock_dir} (held by pid ${holder_pid:-unknown})." >&2
      exit 1
    fi
    sleep 0.2
  done
  printf '%s\n' "$$" >"$lock_dir/pid"
  lock_acquired=1
}

release_lock() {
  if (( lock_acquired )); then
    rm -rf "$lock_dir"
    lock_acquired=0
  fi
}

cleanup() {
  if [[ -n "$lockfile_snapshot" ]]; then
    rm -f "$lockfile_snapshot"
  fi
  release_lock
}

restore_lockfile() {
  cp "$lockfile_snapshot" "$lockfile_path"
}

trap cleanup EXIT

acquire_lock

# Floor validation reads Package.resolved. Do that only after the whole-check
# lock is held, otherwise a concurrent resolver can be mid-write and this
# JSON parser can crash on a truncated lockfile before it ever queues.
python3 - "$lockfile_path" <<'PY'
import json
import sys
from pathlib import Path

lockfile = Path(sys.argv[1])
pins = {
    pin["identity"]: pin["state"].get("version")
    for pin in json.loads(lockfile.read_text())["pins"]
}
minimum_versions = {
    # GoogleSignIn 9.0.0 + GTMAppAuth 5.0.0 moved macOS OAuth state
    # from the collision-prone global `auth` item in the file-based
    # Keychain to the app-scoped data-protection Keychain.
    "googlesignin-ios": (9, 0, 0),
    "gtmappauth": (5, 0, 0),
}

for identity, minimum in minimum_versions.items():
    version = pins.get(identity)
    if not version:
        raise SystemExit(f"Missing required SwiftPM pin: {identity}")
    try:
        actual = tuple(int(part) for part in version.split("."))
    except ValueError as error:
        raise SystemExit(f"Invalid semantic version for {identity}: {version}") from error
    if actual < minimum:
        required = ".".join(str(part) for part in minimum)
        raise SystemExit(
            f"{identity} {version} is below the macOS Keychain-safe minimum {required}"
        )
PY

lockfile_snapshot="$(mktemp "$repo_root/.derived-data/openburnbar-lock-check.Package.resolved.XXXXXX")"
cp "$lockfile_path" "$lockfile_snapshot"

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
    restore_lockfile
    echo "xcodebuild -resolvePackageDependencies failed with exit ${resolve_status}" >&2
    exit "$resolve_status"
  fi
  # Xcode can rewrite Package.resolved before its IDE model graph aborts. Do not
  # let a partial failed attempt become the input to the retry, or the retry can
  # successfully complete a different transitive package graph and report false
  # lockfile drift. Every retry must start from the exact committed lockfile.
  restore_lockfile
  echo "xcodebuild -resolvePackageDependencies aborted (exit 134, transient Xcode IDE model-graph crash) on attempt ${attempt}/${max_attempts}; retrying with a fresh derived-data directory." >&2
  attempt=$(( attempt + 1 ))
done

if (( resolve_status != 0 )); then
  restore_lockfile
  echo "xcodebuild -resolvePackageDependencies aborted (exit 134) on every one of ${max_attempts} attempts. This is the transient Xcode IDE model-graph crash, but it did not clear on retry." >&2
  exit "$resolve_status"
fi

git -C "$repo_root" diff --exit-code -- "$lockfile_path"
