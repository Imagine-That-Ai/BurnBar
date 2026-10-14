#!/usr/bin/env bash
# sweep-stale-worktrees.sh - remove provably-safe stale git worktrees.
#
# A worktree is removed ONLY when ALL of these hold:
#   1. It is a registered worktree of a reachable parent repo (no orphans, no main checkouts)
#   2. `git status` is clean (no modified, no untracked files)
#   3. It is not locked (`git worktree lock` coordination signals are respected)
#   4. No live process has its cwd inside it (protects running agents/builds)
#   5. Nothing under it was written in the last STALE_HOURS (default 24)
# Detached-HEAD trees get their commit pinned to saved/auto-<name>-<date> first,
# so removal can never orphan a commit. Branch checkouts keep their branch in
# the parent repo and can be re-created with one `git worktree add`.
#
# Runs every 30 min via ~/Library/LaunchAgents/ai.burnbar.worktree-sweeper.plist.
# Logs to ~/Library/Logs/wt-sweeper.log. Always exits 0.
#
# Usage: sweep-stale-worktrees.sh [--dry-run] [--quiet] [--daemon]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

ROOTS=(/Volumes/DevSSD/Developer/worktrees)
STALE_HOURS="${STALE_HOURS:-24}"
MAX_REMOVE="${MAX_REMOVE:-25}"
LOCKDIR=/tmp/wt-sweeper.lock.d
LOG=~/Library/Logs/wt-sweeper.log

DRY=0; QUIET=0; DAEMON=0
for a in "$@"; do
  case "$a" in --dry-run) DRY=1;; --quiet) QUIET=1;; --daemon) DAEMON=1;; esac
done

log() { [[ "$QUIET" == 1 ]] || echo "$(date '+%m-%d %H:%M:%S') $*"; }
if [[ "$DAEMON" == 1 ]]; then
  mkdir -p "$(dirname "$LOG")"
  exec >>"$LOG" 2>&1
fi

# Single-flight: skip run if previous sweep still active.
mkdir "$LOCKDIR" 2>/dev/null || { log "SKIP previous run active"; exit 0; }
trap 'rmdir "$LOCKDIR"' EXIT

REMOVED=0
CWD_SNAPSHOT=$(lsof -a -d cwd -Fn 2>/dev/null | grep '^n/' || true)

parent_of() { # $1 = worktree dir -> parent checkout dir; fails when orphaned
  local cdir main
  cdir=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [[ -d "$cdir" ]] || return 1
  main=$(dirname "$cdir")
  [[ -e "$main/.git" ]] || return 1
  echo "$main"
}

wt_entry() { # $1 parent, $2 worktree -> its `worktree list --porcelain` block, empty if unregistered
  git -C "$1" worktree list --porcelain 2>/dev/null | awk -v wt="worktree $2" '
    /^worktree / { p = ($0 == wt) } p'
}

is_live() { # $1 worktree -> 0 if some process cwd is inside it
  awk -v p="n$1" '$0 == p || index($0, p "/") == 1 { f=1 } END { exit !f }' <<<"$CWD_SNAPSHOT"
}

for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || { log "SKIP-ROOT missing $root"; continue; }
  for d in "$root"/*/; do
    [[ -d "$d" ]] || continue
    d=${d%/}; n=${d##*/}
    [[ -e "$d/.git" ]] || { log "SKIP-NOREPO $n"; continue; }
    parent=$(parent_of "$d") || { log "SKIP-DANGLING $n"; continue; }
    [[ "$d" == "$parent" ]] && { log "SKIP-MAINCHECKOUT $n"; continue; }
    entry=$(wt_entry "$parent" "$d" || true)
    [[ -n "$entry" ]] || { log "SKIP-UNREGISTERED $n"; continue; }
    grep -q '^locked' <<<"$entry" && { log "SKIP-LOCKED $n"; continue; }
    st=$(git -C "$d" status --porcelain 2>/dev/null) || { log "SKIP-STATUSFAIL $n"; continue; }
    [[ -z "$st" ]] || { log "SKIP-DIRTY $n"; continue; }
    is_live "$d" && { log "SKIP-LIVE $n"; continue; }
    [[ -z "$(find "$d" -mmin "-$((STALE_HOURS * 60))" -print -quit 2>/dev/null)" ]] || { log "SKIP-FRESH $n"; continue; }
    [[ "$DRY" == 0 ]] || { log "WOULD-REMOVE $n ($parent)"; continue; }
    [[ "$REMOVED" -lt "$MAX_REMOVE" ]] || { log "CAP-MAX_REMOVE reached, deferring rest"; break 2; }
    if [[ -z "$(git -C "$d" branch --show-current 2>/dev/null)" ]]; then
      git -C "$parent" branch "saved/auto-$n-$(date +%Y%m%d)" "$(git -C "$d" rev-parse HEAD)" 2>/dev/null \
        || { log "SKIP-PINFAIL $n"; continue; }
      log "PINNED detached $n"
    fi
    if git -C "$parent" worktree remove "$d" 2>/dev/null; then
      log "REMOVED $n ($parent)"
    elif rm -rf "$d" 2>/dev/null; then
      # e.g. trees containing submodules: clean+verified, so rm+prune is equivalent
      git -C "$parent" worktree prune 2>/dev/null || true
      log "REMOVED-RM $n ($parent)"
    else
      log "FAIL $n"; continue
    fi
    REMOVED=$((REMOVED+1))
  done
done

log "DONE removed=$REMOVED dry=$DRY"
exit 0
