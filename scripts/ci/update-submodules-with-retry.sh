#!/usr/bin/env bash
#
# Initialize Git submodules with bounded retries.
#
# GitHub-hosted macOS runners occasionally fail during submodule clone before
# any repository tests execute. Keeping this logic in-repo lets workflows avoid
# a single fragile actions/checkout submodule step while still failing closed if
# the dependency cannot be fetched after repeated attempts.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

attempts="${OPENBURNBAR_SUBMODULE_UPDATE_ATTEMPTS:-5}"
base_sleep_seconds="${OPENBURNBAR_SUBMODULE_UPDATE_BASE_SLEEP_SECONDS:-5}"
dry_run=0
saved_local_extraheaders=()
saved_global_extraheaders=()

if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
  shift
fi

submodule_paths=("$@")
if ((${#submodule_paths[@]} == 0)); then
  submodule_paths=(Vendor/libsignal)
fi

if ! [[ "$attempts" =~ ^[1-9][0-9]*$ ]]; then
  echo "OPENBURNBAR_SUBMODULE_UPDATE_ATTEMPTS must be a positive integer." >&2
  exit 2
fi
if ! [[ "$base_sleep_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "OPENBURNBAR_SUBMODULE_UPDATE_BASE_SLEEP_SECONDS must be a positive integer." >&2
  exit 2
fi

run_submodule_update() {
  local status=0

  clear_github_extraheaders
  trap restore_github_extraheaders RETURN
  git submodule sync --recursive -- "${submodule_paths[@]}" || status=$?
  if ((status == 0)); then
    git submodule update --init --recursive --depth=1 --jobs=4 -- "${submodule_paths[@]}" || status=$?
  fi
  trap - RETURN
  restore_github_extraheaders
  return "$status"
}

clear_github_extraheaders() {
  mapfile -t saved_local_extraheaders < <(git config --local --get-all http.https://github.com/.extraheader 2>/dev/null || true)
  mapfile -t saved_global_extraheaders < <(git config --global --get-all http.https://github.com/.extraheader 2>/dev/null || true)

  git config --local --unset-all http.https://github.com/.extraheader >/dev/null 2>&1 || true
  git config --global --unset-all http.https://github.com/.extraheader >/dev/null 2>&1 || true
}

restore_github_extraheaders() {
  local value

  git config --local --unset-all http.https://github.com/.extraheader >/dev/null 2>&1 || true
  git config --global --unset-all http.https://github.com/.extraheader >/dev/null 2>&1 || true

  for value in "${saved_local_extraheaders[@]}"; do
    git config --local --add http.https://github.com/.extraheader "$value"
  done
  for value in "${saved_global_extraheaders[@]}"; do
    git config --global --add http.https://github.com/.extraheader "$value"
  done
}

reset_partial_submodule_checkout() {
  local path

  for path in "${submodule_paths[@]}"; do
    git submodule deinit -f -- "$path" >/dev/null 2>&1 || true
    rm -rf "$path" ".git/modules/$path"
  done
}

if ((dry_run)); then
  printf 'DRY RUN: would initialize submodules with %s attempts: %s\n' "$attempts" "${submodule_paths[*]}"
  exit 0
fi

for ((attempt = 1; attempt <= attempts; attempt += 1)); do
  echo ">>> Submodule update attempt ${attempt}/${attempts}: ${submodule_paths[*]}"

  if run_submodule_update; then
    echo ">>> Submodule update succeeded."
    exit 0
  else
    exit_code=$?
    if ((attempt == attempts)); then
      echo "Submodule update failed after ${attempts} attempts." >&2
      exit "$exit_code"
    fi

    reset_partial_submodule_checkout
    sleep_seconds=$((base_sleep_seconds * attempt))
    echo "Submodule update failed; retrying in ${sleep_seconds}s." >&2
    sleep "$sleep_seconds"
  fi
done
