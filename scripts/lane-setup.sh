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

# Reuse the primary checkout's populated Vendor artifacts so headless
# swift/xcodebuild resolve offline. Symlink (not copy) so we never duplicate the
# multi-GB xcframeworks; the teardown script removes THESE symlinks before
# removing the worktree so `git worktree remove` cannot delete through them into
# the shared Vendor tree.
#
# CRITICAL (Codex PR #1559 thread): `Vendor/` is a TRACKED directory (it holds
# tracked GRDB-SQLCipher, the libsignal submodule path, and the *.aar files), so a
# normal `git worktree add` ALREADY creates `${worktree_dir}/Vendor`. The old
# `! -e "${worktree_dir}/Vendor"` guard was therefore always false and NOTHING got
# linked, leaving lane builds to resolve Package.swift with the tracked Vendor but
# WITHOUT the primary checkout's populated build artifacts (the gitignored
# `*.xcframework` bundles that gate the `has*XCFramework` manifest flags). Handle
# both shapes: if Vendor already exists in the worktree, link the individual
# untracked/gitignored artifacts INTO it; only symlink the whole Vendor dir when
# the worktree genuinely lacks one.
if [[ -e "${repo_root}/Vendor" ]]; then
  if [[ ! -e "${worktree_dir}/Vendor" ]]; then
    ln -s "${repo_root}/Vendor" "${worktree_dir}/Vendor"
    echo "Linked Vendor -> ${repo_root}/Vendor" >&2
  else
    # Vendor exists in the worktree (tracked dir). Link each populated, gitignored
    # artifact from the primary checkout that the fresh checkout lacks. The
    # xcframeworks flip the manifest's has*XCFramework flags, so a lane without
    # them resolves a DIFFERENT package graph than the primary checkout — exactly
    # the drift this helper exists to prevent. Enumerate the known artifact names
    # (mirrors the `.gitignore` Vendor/*.xcframework block) plus any other
    # untracked top-level Vendor entry present in the primary checkout.
    linked_any=0
    for artifact in \
      OpenBurnBarIroh.xcframework \
      OpenBurnBarSignalFfi.xcframework \
      BurnBarRemote.xcframework \
      OpenBurnBarSignalFfiIOS.xcframework \
      OpenBurnBarSignalFfiMac.xcframework; do
      src="${repo_root}/Vendor/${artifact}"
      dst="${worktree_dir}/Vendor/${artifact}"
      if [[ -e "${src}" && ! -e "${dst}" ]]; then
        ln -s "${src}" "${dst}"
        echo "Linked Vendor/${artifact} -> ${src}" >&2
        linked_any=1
      fi
    done
    # Also link any OTHER untracked top-level Vendor entry the primary checkout
    # carries (future artifacts not yet in the list above), so the lane never
    # silently misses one. Tracked entries (GRDB-SQLCipher, libsignal, *.aar) are
    # already present in the worktree checkout and are skipped by the `! -e` guard.
    while IFS= read -r entry; do
      [[ -z "${entry}" ]] && continue
      base="$(basename "${entry}")"
      src="${repo_root}/Vendor/${base}"
      dst="${worktree_dir}/Vendor/${base}"
      if [[ -e "${src}" && ! -e "${dst}" ]]; then
        ln -s "${src}" "${dst}"
        echo "Linked untracked Vendor/${base} -> ${src}" >&2
        linked_any=1
      fi
    done < <(cd "${repo_root}" && git ls-files --others --exclude-standard --directory -- Vendor 2>/dev/null | awk -F/ 'NF>=2{print $2}' | sort -u)
    if [[ "${linked_any}" -eq 0 ]]; then
      echo "Vendor exists in worktree; no populated artifacts to link from primary checkout." >&2
    fi
  fi
fi

echo "Lane ready:"
echo "  branch:   ${branch}"
echo "  worktree: ${worktree_dir}"
echo "  base:     ${base_ref}"
