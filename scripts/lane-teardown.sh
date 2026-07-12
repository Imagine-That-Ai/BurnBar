#!/usr/bin/env bash
# Core-decomposition lane teardown (docs/CORE_DECOMPOSITION_PROGRAM.md, machinery §2).
#
# Removes a lane worktree created by scripts/lane-setup.sh. CRITICAL ORDERING: it
# deletes the worktree's Vendor SYMLINK first, because `git worktree remove`
# follows the symlink and would otherwise delete THROUGH it into the shared
# primary Vendor tree (the vendor-symlink worktree-remove hazard). The branch is
# left intact (delete it separately once its PR merges).
#
# Usage:
#   scripts/lane-teardown.sh <lane-name>
#
#   <lane-name>  the same slug passed to scripts/lane-setup.sh; the worktree is
#               ../burnbar-lanes/<lane-name>.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "usage: scripts/lane-teardown.sh <lane-name>" >&2
  exit 2
fi

lane_name="$1"
worktree_dir="${repo_root}/../burnbar-lanes/${lane_name}"

cd "$repo_root"

if [[ ! -d "$worktree_dir" ]]; then
  echo "No worktree at ${worktree_dir}; nothing to tear down." >&2
  exit 0
fi

# Remove EVERY Vendor symlink BEFORE `git worktree remove` — deletion-through-symlink
# hazard. lane-setup links either the whole Vendor dir (when the worktree lacked
# one) OR, in a normal checkout where Vendor/ is a tracked directory, individual
# gitignored artifacts INSIDE Vendor/ (Vendor/<name>.xcframework -> primary). Both
# shapes must be unlinked here, else `git worktree remove` follows the inner
# symlinks and deletes THROUGH them into the shared primary Vendor tree.
#
# 1) Whole-Vendor symlink. `[ -L … ]` matches only a symlink, so a real (tracked)
#    Vendor directory is never removed here.
if [[ -L "${worktree_dir}/Vendor" ]]; then
  rm "${worktree_dir}/Vendor"
  echo "Removed Vendor symlink from ${worktree_dir}" >&2
elif [[ -d "${worktree_dir}/Vendor" ]]; then
  # 2) Per-artifact symlinks inside a real Vendor directory. Remove only symlinks
  #    (never the tracked GRDB-SQLCipher/libsignal/*.aar real entries). `find -maxdepth 1
  #    -type l` targets exactly the links lane-setup created.
  while IFS= read -r link; do
    [[ -z "${link}" ]] && continue
    rm "${link}"
    echo "Removed Vendor artifact symlink ${link}" >&2
  done < <(find "${worktree_dir}/Vendor" -maxdepth 1 -type l 2>/dev/null)
fi

git worktree remove "$worktree_dir"
echo "Removed worktree ${worktree_dir} (branch left intact)."
