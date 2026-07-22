#!/usr/bin/env bash

resolve_repo_path() {
  if [[ $# -ne 2 ]]; then
    echo "usage: resolve_repo_path REPO_ROOT PATH" >&2
    return 2
  fi

  local repo_root="$1"
  local path="$2"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "${repo_root%/}" "$path"
  fi
}
