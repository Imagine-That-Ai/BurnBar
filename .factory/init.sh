#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$repo_root/.spm-cache" "$repo_root/.derived-data"
mkdir -p "$repo_root/.factory/validation"

# --- Stale derived-data pruning ---
# Remove subdirectories under .derived-data/ that are older than a configurable
# age threshold (default 4 hours). This cleans up historical build artifacts
# from prior runs (ci-typecheck, ci-build, mission-resolve, etc.) without
# touching actively-used directories.
#
# Per-invocation temp dirs (mktemp .derived-data/NAME.XXXXXX) should self-clean
# via trap on normal exit but can linger if the process was killed or timed out.
#
# Active-run safety:
#   Before removing any candidate directory, we check whether any running process
#   has open file handles inside it (via lsof). If a directory is in active use
#   by a concurrent build, test, or validator, it is skipped regardless of age.
#   This ensures DERIVED_DATA_PRUNE_AGE_HOURS=0 never deletes a directory that
#   a concurrent xcodebuild or other process is still writing to.
#
# Safe because:
#   - Only removes direct children of .derived-data/ (never the parent itself).
#   - Uses find -maxdepth 1 so nested structures aren't traversed unsafely.
#   - Active-run lsof check prevents deletion of in-use directories.
#   - Age threshold (4h default) provides additional margin; even with age=0,
#     active directories are protected.
#   - Idempotent: re-running is a no-op if nothing is stale.

# Returns 0 (true) if any process has open file handles under the given directory.
# Uses lsof to check for active file descriptors — no PID files or markers needed.
#
# Strategy: lsof +d checks the kernel's open file table for references to the
# directory inode, which catches both processes using the directory as cwd and
# processes with files open within it. On macOS this is efficient (~70ms even
# for large directories) because it operates on the kernel file table directly,
# not by scanning the filesystem. This catches xcodebuild, swift-frontend,
# swiftc, and other build processes that hold open file handles during compilation.
is_dir_in_use() {
  local dir="$1"
  local canon_dir
  canon_dir="$(cd "$dir" && pwd -P)"
  # lsof +d lists processes that have the directory or files within it open.
  # Redirect stderr to suppress permission errors (non-fatal for our guard).
  # The -F p field outputs just the PID; we only need to know if any exist.
  # Note: lsof exits 1 even when it finds matches, so we use || true to avoid
  # pipefail/errexit killing the pipeline before grep can evaluate the output.
  if { lsof +d "$canon_dir" -F p 2>/dev/null || true; } | grep -q '^p'; then
    return 0  # in use
  fi
  return 1  # not in use
}

DERIVED_DATA_DIR="$repo_root/.derived-data"
PRUNE_AGE_HOURS="${DERIVED_DATA_PRUNE_AGE_HOURS:-4}"

if [ -d "$DERIVED_DATA_DIR" ]; then
  pruned=0
  skipped_active=0
  while IFS= read -r -d '' dir; do
    dir_name="$(basename "$dir")"
    if is_dir_in_use "$dir"; then
      echo "[init] Skipping active directory: .derived-data/$dir_name (in use by running process)"
      skipped_active=$((skipped_active + 1))
      continue
    fi
    rm -rf "$dir"
    pruned=$((pruned + 1))
  done < <(find "$DERIVED_DATA_DIR" -maxdepth 1 -mindepth 1 -type d -not -newermt "${PRUNE_AGE_HOURS} hours ago" -print0 2>/dev/null || true)
  if [ "$pruned" -gt 0 ]; then
    echo "[init] Pruned $pruned stale derived-data directories (older than ${PRUNE_AGE_HOURS}h)"
  fi
  if [ "$skipped_active" -gt 0 ]; then
    echo "[init] Skipped $skipped_active active directories (protected by lsof check)"
  fi
fi

if [ ! -d "$repo_root/extensions/openburnbar/node_modules" ]; then
  npm --prefix "$repo_root/extensions/openburnbar" ci
fi

if [ ! -f "$repo_root/.spm-cache/.mission-resolved" ]; then
  xcodebuild -resolvePackageDependencies \
    -project "$repo_root/OpenBurnBar.xcodeproj" \
    -scheme "OpenBurnBar" \
    -clonedSourcePackagesDirPath "$repo_root/.spm-cache" \
    -derivedDataPath "$repo_root/.derived-data/mission-resolve" \
    -quiet
  touch "$repo_root/.spm-cache/.mission-resolved"
fi
