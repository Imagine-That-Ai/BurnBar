#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$repo_root/.spm-cache" "$repo_root/.derived-data"
mkdir -p "$repo_root/.factory/validation"

# --- Stale derived-data pruning ---
# Remove subdirectories under .derived-data/ that are older than 4 hours.
# This cleans up historical build artifacts from prior runs (ci-typecheck,
# ci-build, mission-resolve, etc.) without touching actively-used directories.
# Per-invocation temp dirs (mktemp .derived-data/NAME.XXXXXX) should self-clean
# via trap on normal exit but can linger if the process was killed or timed out.
#
# Safe because:
#   - Only removes direct children of .derived-data/ (never the parent itself).
#   - Uses find -maxdepth 1 so nested structures aren't traversed unsafely.
#   - Age threshold (4h) is generous enough to avoid pruning a directory that
#     a concurrent validator is still building into.
#   - Idempotent: re-running is a no-op if nothing is stale.
DERIVED_DATA_DIR="$repo_root/.derived-data"
PRUNE_AGE_HOURS="${DERIVED_DATA_PRUNE_AGE_HOURS:-4}"

if [ -d "$DERIVED_DATA_DIR" ]; then
  pruned=0
  while IFS= read -r -d '' dir; do
    rm -rf "$dir"
    pruned=$((pruned + 1))
  done < <(find "$DERIVED_DATA_DIR" -maxdepth 1 -mindepth 1 -type d -not -newermt "${PRUNE_AGE_HOURS} hours ago" -print0 2>/dev/null || true)
  if [ "$pruned" -gt 0 ]; then
    echo "[init] Pruned $pruned stale derived-data directories (older than ${PRUNE_AGE_HOURS}h)"
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
