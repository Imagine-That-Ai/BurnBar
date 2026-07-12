#!/usr/bin/env bash
# Core-decomposition lane setup (docs/CORE_DECOMPOSITION_PROGRAM.md, machinery §2).
#
# Creates an isolated git worktree + branch for one move lane so parallel packets
# never collide in the shared checkout, and reuses main's populated .spm-cache
# with -disableAutomaticPackageResolution (the Xcode 27 headless constraint) via a
# Vendor symlink into the primary checkout.
#
# Usage:
#   scripts/lane-setup.sh <lane-name> [base-ref]
#
#   <lane-name>  worktree/branch slug, e.g. "lane-b-sqlitereader". The branch is
#                created as core-decomp/<lane-name>; the worktree lands at
#                ../burnbar-lanes/<lane-name>.
#   [base-ref]   branch/ref to fork from (default: origin/main).
#
# Teardown with scripts/lane-teardown.sh (it removes the Vendor symlink BEFORE
# `git worktree remove` — the deletion-through-symlink hazard).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "usage: scripts/lane-setup.sh <lane-name> [base-ref]" >&2
  exit 2
fi

lane_name="$1"
base_ref="${2:-origin/main}"
branch="core-decomp/${lane_name}"
worktree_dir="${repo_root}/../burnbar-lanes/${lane_name}"

cd "$repo_root"

git fetch origin main

if git show-ref --verify --quiet "refs/heads/${branch}"; then
  echo "Branch ${branch} already exists; reusing it." >&2
  git worktree add "$worktree_dir" "$branch"
else
  git worktree add -b "$branch" "$worktree_dir" "$base_ref"
fi

# Reuse the primary checkout's Vendor + .spm-cache so headless swift/xcodebuild
# resolve offline. Symlink (not copy) so we never duplicate the xcframeworks; the
# teardown script removes THIS symlink before removing the worktree so `git
# worktree remove` cannot delete through it into the shared Vendor tree.
if [[ -e "${repo_root}/Vendor" && ! -e "${worktree_dir}/Vendor" ]]; then
  ln -s "${repo_root}/Vendor" "${worktree_dir}/Vendor"
  echo "Linked Vendor -> ${repo_root}/Vendor" >&2
fi

echo "Lane ready:"
echo "  branch:   ${branch}"
echo "  worktree: ${worktree_dir}"
echo "  base:     ${base_ref}"
