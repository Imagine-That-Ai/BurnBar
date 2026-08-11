#!/usr/bin/env bash

# Prepare the Xcode app's cloned-source SwiftPM cache without allowing ordinary
# builds to mutate Package.resolved.
#
# A complete cache is verified directly from Package.resolved,
# workspace-state.json, every checkout HEAD, and every recorded artifact. Xcode
# resolution is skipped entirely when that proof is complete. If the cache is
# genuinely incomplete, one explicit resolver is run with the checked-in lock,
# finite wall-clock containment, isolated DerivedData, and retry only for the
# known Xcode 27 IDE model-graph SIGABRT (exit 134).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_repo_root="$(cd "$script_dir/.." && pwd -P)"

repo_root="$default_repo_root"
project_path=""
scheme="OpenBurnBar"
cache_dir=""
derived_data_dir=""
check_only=0
force_resolve=0

usage() {
  cat <<'EOF'
Usage: scripts/prepare-openburnbar-app-swiftpm.sh [options]

Options:
  --cache-dir <path>      Cloned-source package cache (default: .spm-cache)
  --derived-data <path>   DerivedData root for guarded resolution
                          (default: .derived-data)
  --project <path>        Xcode project (default: OpenBurnBar.xcodeproj)
  --scheme <name>         Xcode scheme (default: OpenBurnBar)
  --check-only            Fail if the cache is incomplete; never resolve
  --force-resolve         Resolve even when the cache is already complete
  --repo-root <path>      Repository root override (primarily for fixtures)
  -h, --help              Show this help

Environment:
  OPENBURNBAR_SWIFTPM_RESOLVE_MAX_ATTEMPTS
                          Positive retry limit for exit 134 (default: 3)
  OPENBURNBAR_SWIFTPM_RESOLVE_TIMEOUT_SECONDS
                          Positive wall-clock limit per attempt (default: 900)
  OPENBURNBAR_SWIFTPM_LOCK_WAIT_SECONDS
                          Positive cache-lock wait limit (default: 1800)
  OPENBURNBAR_XCODE_PROCESS_TMPDIR
                          Writable local TMPDIR for Xcode (default: /tmp)
EOF
}

while (($# > 0)); do
  case "$1" in
    --cache-dir)
      cache_dir="${2:-}"
      shift 2
      ;;
    --derived-data)
      derived_data_dir="${2:-}"
      shift 2
      ;;
    --project)
      project_path="${2:-}"
      shift 2
      ;;
    --scheme)
      scheme="${2:-}"
      shift 2
      ;;
    --check-only)
      check_only=1
      shift
      ;;
    --force-resolve)
      force_resolve=1
      shift
      ;;
    --repo-root)
      repo_root="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "$repo_root" || -z "$scheme" ]]; then
  echo "Repository root and scheme must not be empty." >&2
  exit 64
fi
repo_root="$(cd "$repo_root" && pwd -P)"
project_path="${project_path:-$repo_root/OpenBurnBar.xcodeproj}"
cache_dir="${cache_dir:-$repo_root/.spm-cache}"
derived_data_dir="${derived_data_dir:-$repo_root/.derived-data}"

if [[ "$project_path" != /* ]]; then
  project_path="$repo_root/$project_path"
fi
if [[ "$cache_dir" != /* ]]; then
  cache_dir="$repo_root/$cache_dir"
fi
if [[ "$derived_data_dir" != /* ]]; then
  derived_data_dir="$repo_root/$derived_data_dir"
fi

lockfile_path="$repo_root/OpenBurnBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
verifier="$script_dir/ci/verify-openburnbar-app-swiftpm-cache.py"
supervisor="$script_dir/lib/run_xcodebuild_with_timeout_containment.py"

for required_path in "$lockfile_path" "$verifier" "$supervisor"; do
  if [[ ! -f "$required_path" ]]; then
    echo "Required SwiftPM preparation input is missing: $required_path" >&2
    exit 64
  fi
done
if [[ ! -d "$project_path" ]]; then
  echo "Xcode project is missing: $project_path" >&2
  exit 64
fi
for required_command in python3 xcodebuild; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command is unavailable: $required_command" >&2
    exit 69
  fi
done

# shellcheck source=scripts/lib/xcode-source-classification.sh
source "$script_dir/lib/xcode-source-classification.sh"
openburnbar_configure_xcode_process_tmpdir

# The committed graph deliberately uses source-built Firestore. Force the same
# graph for every resolver regardless of the caller's inherited environment.
export FIREBASE_SOURCE_FIRESTORE=1

positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer, found '$value'." >&2
    exit 64
  fi
}

max_attempts="${OPENBURNBAR_SWIFTPM_RESOLVE_MAX_ATTEMPTS:-3}"
resolve_timeout_seconds="${OPENBURNBAR_SWIFTPM_RESOLVE_TIMEOUT_SECONDS:-900}"
lock_wait_seconds="${OPENBURNBAR_SWIFTPM_LOCK_WAIT_SECONDS:-1800}"
positive_integer "OPENBURNBAR_SWIFTPM_RESOLVE_MAX_ATTEMPTS" "$max_attempts"
positive_integer "OPENBURNBAR_SWIFTPM_RESOLVE_TIMEOUT_SECONDS" "$resolve_timeout_seconds"
positive_integer "OPENBURNBAR_SWIFTPM_LOCK_WAIT_SECONDS" "$lock_wait_seconds"

mkdir -p "$cache_dir" "$derived_data_dir" "$repo_root/.derived-data"

lock_dir="$repo_root/.derived-data/openburnbar-app-swiftpm-prepare.lock"
lock_acquired=0
lockfile_snapshot=""
attempt_derived_data=""

acquire_lock() {
  local deadline=$((SECONDS + lock_wait_seconds))
  while ! mkdir "$lock_dir" 2>/dev/null; do
    local holder_pid=""
    if [[ -f "$lock_dir/pid" ]]; then
      holder_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    fi
    if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
      rm -rf "$lock_dir"
      continue
    fi
    if ((SECONDS >= deadline)); then
      echo "Timed out after ${lock_wait_seconds}s waiting for $lock_dir (held by pid ${holder_pid:-unknown})." >&2
      exit 75
    fi
    sleep 0.2
  done
  printf '%s\n' "$$" >"$lock_dir/pid"
  lock_acquired=1
}

restore_lockfile() {
  if [[ -n "$lockfile_snapshot" && -f "$lockfile_snapshot" ]]; then
    cp "$lockfile_snapshot" "$lockfile_path"
  fi
}

cleanup() {
  local original_status="${1:-0}"
  local cleanup_status=0
  restore_lockfile || cleanup_status=$?
  if [[ -n "$attempt_derived_data" && -d "$attempt_derived_data" ]]; then
    rm -rf "$attempt_derived_data" || cleanup_status=$?
  fi
  if [[ -n "$lockfile_snapshot" ]]; then
    rm -f "$lockfile_snapshot" || cleanup_status=$?
  fi
  if ((lock_acquired)); then
    rm -rf "$lock_dir" || cleanup_status=$?
  fi
  if ((original_status == 0 && cleanup_status != 0)); then
    return "$cleanup_status"
  fi
  return "$original_status"
}

cleanup_on_exit() {
  local original_status=$?
  trap - EXIT
  cleanup "$original_status"
  exit $?
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_lock
lockfile_snapshot="$(mktemp "$repo_root/.derived-data/openburnbar-app.Package.resolved.XXXXXX")"
cp "$lockfile_path" "$lockfile_snapshot"

evidence_dir="$derived_data_dir/.openburnbar-swiftpm-resolution"
mkdir -p "$evidence_dir"
rm -f \
  "$evidence_dir"/attempt-*.log \
  "$evidence_dir"/attempt-*-containment.json

verify_cache() {
  python3 "$verifier" \
    --lockfile "$lockfile_path" \
    --cache-dir "$cache_dir"
}

verification_status=0
verify_cache || verification_status=$?
if ((verification_status == 64)); then
  exit "$verification_status"
fi
if ((verification_status == 0 && force_resolve == 0)); then
  echo "SwiftPM cache is complete; package resolution was not run."
  exit 0
fi
if ((check_only)); then
  if ((verification_status == 0)); then
    echo "SwiftPM cache is complete; forced resolution was suppressed by --check-only."
    exit 0
  fi
  echo "SwiftPM cache is incomplete and --check-only forbids network or cache mutation." >&2
  exit 78
fi

if ((verification_status == 0)); then
  echo "SwiftPM cache is complete; running the explicitly requested lock-preserving resolve."
else
  echo "SwiftPM cache is incomplete; running a guarded lock-preserving resolve."
fi

attempt=1
resolve_status=0
while ((attempt <= max_attempts)); do
  restore_lockfile
  attempt_derived_data="$(mktemp -d "$derived_data_dir/.openburnbar-swiftpm-attempt-${attempt}.XXXXXX")"
  attempt_log="$evidence_dir/attempt-${attempt}.log"
  attempt_receipt="$evidence_dir/attempt-${attempt}-containment.json"
  rm -f "$attempt_log" "$attempt_receipt"

  resolve_status=0
  python3 "$supervisor" \
    --log "$attempt_log" \
    --receipt "$attempt_receipt" \
    --wall-timeout-seconds "$resolve_timeout_seconds" \
    -- \
    xcodebuild -resolvePackageDependencies \
      -project "$project_path" \
      -scheme "$scheme" \
      -clonedSourcePackagesDirPath "$cache_dir" \
      -derivedDataPath "$attempt_derived_data" \
      -onlyUsePackageVersionsFromResolvedFile \
      "${OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS[@]}" \
      || resolve_status=$?

  rm -rf "$attempt_derived_data"
  attempt_derived_data=""

  if ((resolve_status == 0)); then
    break
  fi
  restore_lockfile
  if ((resolve_status != 134)); then
    echo "Guarded SwiftPM resolution failed with status $resolve_status." >&2
    echo "Resolver log: $attempt_log" >&2
    if [[ -s "$attempt_receipt" ]]; then
      echo "Containment receipt: $attempt_receipt" >&2
    fi
    exit "$resolve_status"
  fi
  if ((attempt >= max_attempts)); then
    break
  fi
  echo "Xcode package resolution aborted with the known IDE model-graph exit 134 on attempt ${attempt}/${max_attempts}; retrying from the exact lockfile with fresh DerivedData." >&2
  attempt=$((attempt + 1))
done

if ((resolve_status != 0)); then
  echo "Xcode package resolution returned exit 134 on all ${max_attempts} attempts." >&2
  exit "$resolve_status"
fi

if ! cmp -s "$lockfile_snapshot" "$lockfile_path"; then
  echo "Guarded SwiftPM resolution mutated Package.resolved; restoring the exact source lock and failing closed." >&2
  diff -u "$lockfile_snapshot" "$lockfile_path" >&2 || true
  restore_lockfile
  exit 65
fi

verification_status=0
verify_cache || verification_status=$?
if ((verification_status != 0)); then
  echo "SwiftPM resolution exited successfully but the resulting cache is not complete." >&2
  exit "$verification_status"
fi

echo "SwiftPM cache was repaired without mutating Package.resolved."
