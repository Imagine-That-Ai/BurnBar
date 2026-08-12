#!/usr/bin/env bash

# Configure one authoritative Git view for release/certification commands.
#
# Ordinary clean checkouts need no special environment. Isolated candidates
# that use a separate object store or index must provide both:
#
#   OPENBURNBAR_CANDIDATE_GIT_DIR=/absolute/path/to/.git
#   OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE=/absolute/path/to/index
#
# The configured GIT_* variables are exported so subprocesses such as SBOM and
# corresponding-source generators enumerate the same candidate as their parent.

openburnbar_configure_exact_candidate_git() {
  local repo_root="$1"
  local candidate_git_dir="${OPENBURNBAR_CANDIDATE_GIT_DIR:-}"
  local candidate_git_index="${OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE:-}"
  local git_bin="${OPENBURNBAR_GIT_BIN:-git}"
  local configured_count=0

  if [[ ! -d "$repo_root" || -L "$repo_root" ]]; then
    echo "ERROR: Exact-candidate Git work tree must be a real directory: $repo_root" >&2
    return 1
  fi
  repo_root="$(cd "$repo_root" && pwd -P)"

  [[ -n "$candidate_git_dir" ]] && configured_count=$((configured_count + 1))
  [[ -n "$candidate_git_index" ]] && configured_count=$((configured_count + 1))
  if [[ "$configured_count" -eq 1 ]]; then
    echo "ERROR: OPENBURNBAR_CANDIDATE_GIT_DIR and OPENBURNBAR_CANDIDATE_GIT_INDEX_FILE must be provided together." >&2
    return 1
  fi
  if [[ "$configured_count" -eq 0 ]] \
    && [[ -n "${GIT_DIR:-}" || -n "${GIT_WORK_TREE:-}" || -n "${GIT_INDEX_FILE:-}" ]]; then
    echo "ERROR: Generic GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE overrides are not accepted implicitly. Use the OPENBURNBAR_CANDIDATE_GIT_* inputs." >&2
    return 1
  fi

  if [[ "$configured_count" -eq 2 ]]; then
    if [[ "$candidate_git_dir" != /* || "$candidate_git_index" != /* ]]; then
      echo "ERROR: Exact-candidate Git directory and index paths must be absolute." >&2
      return 1
    fi
    if [[ ! -d "$candidate_git_dir" || -L "$candidate_git_dir" ]]; then
      echo "ERROR: Exact-candidate Git directory must be a real directory: $candidate_git_dir" >&2
      return 1
    fi
    if [[ ! -f "$candidate_git_index" || -L "$candidate_git_index" ]]; then
      echo "ERROR: Exact-candidate Git index must be a real file: $candidate_git_index" >&2
      return 1
    fi
    candidate_git_dir="$(cd "$candidate_git_dir" && pwd -P)"
    candidate_git_index="$(
      cd "$(dirname "$candidate_git_index")" \
        && printf '%s/%s\n' "$(pwd -P)" "$(basename "$candidate_git_index")"
    )"
    export GIT_DIR="$candidate_git_dir"
    export GIT_WORK_TREE="$repo_root"
    export GIT_INDEX_FILE="$candidate_git_index"
    export OPENBURNBAR_EXACT_CANDIDATE_GIT_MODE="alternate-index"
  else
    export OPENBURNBAR_EXACT_CANDIDATE_GIT_MODE="checkout"
  fi

  export OPENBURNBAR_EXACT_CANDIDATE_WORK_TREE="$repo_root"
  export OPENBURNBAR_EXACT_CANDIDATE_GIT_BIN="$git_bin"

  local observed_work_tree
  if ! observed_work_tree="$("$git_bin" -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "ERROR: Exact-candidate Git authority could not resolve the work tree at $repo_root." >&2
    return 1
  fi
  observed_work_tree="$(cd "$observed_work_tree" && pwd -P)"
  if [[ "$observed_work_tree" != "$repo_root" ]]; then
    echo "ERROR: Exact-candidate Git authority resolved work tree $observed_work_tree instead of $repo_root." >&2
    return 1
  fi
}

openburnbar_candidate_git() {
  if [[ -z "${OPENBURNBAR_EXACT_CANDIDATE_WORK_TREE:-}" \
    || -z "${OPENBURNBAR_EXACT_CANDIDATE_GIT_BIN:-}" ]]; then
    echo "ERROR: Exact-candidate Git has not been configured." >&2
    return 1
  fi
  "$OPENBURNBAR_EXACT_CANDIDATE_GIT_BIN" \
    -C "$OPENBURNBAR_EXACT_CANDIDATE_WORK_TREE" \
    "$@"
}

# Run repository-level operations such as `worktree add/remove` without the
# candidate's explicit work-tree index. Passing GIT_INDEX_FILE into `git
# worktree add` can stage deletions in that authoritative index while Git
# initializes the linked worktree. This helper keeps the selected object store
# and HEAD but deliberately removes index/work-tree overrides.
openburnbar_candidate_repository_git() {
  if [[ -z "${OPENBURNBAR_EXACT_CANDIDATE_WORK_TREE:-}" \
    || -z "${OPENBURNBAR_EXACT_CANDIDATE_GIT_BIN:-}" \
    || -z "${OPENBURNBAR_EXACT_CANDIDATE_GIT_MODE:-}" ]]; then
    echo "ERROR: Exact-candidate Git has not been configured." >&2
    return 1
  fi

  if [[ "$OPENBURNBAR_EXACT_CANDIDATE_GIT_MODE" == "alternate-index" ]]; then
    env -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      "$OPENBURNBAR_EXACT_CANDIDATE_GIT_BIN" \
      --git-dir="$GIT_DIR" \
      "$@"
  else
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      "$OPENBURNBAR_EXACT_CANDIDATE_GIT_BIN" \
      -C "$OPENBURNBAR_EXACT_CANDIDATE_WORK_TREE" \
      "$@"
  fi
}

# Run a tool that owns its own Git repository discovery without leaking the
# exact candidate's generic Git process overrides into it.
#
# Release entrypoints export GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE so ordinary
# repository-aware subprocesses remain bound to the selected candidate.
# SwiftPM and Xcode, however, invoke Git inside dependency checkouts. If those
# generic variables leak into such tools, every dependency checkout appears to
# resolve through the candidate repository and its HEAD. Preserve the explicit
# OPENBURNBAR_CANDIDATE_GIT_* inputs so a child that deliberately opts into the
# candidate adapter can still do so, while removing only the ambient Git
# overrides that would corrupt independent repository discovery.
openburnbar_without_candidate_git_environment() {
  env \
    -u GIT_DIR \
    -u GIT_WORK_TREE \
    -u GIT_INDEX_FILE \
    "$@"
}
