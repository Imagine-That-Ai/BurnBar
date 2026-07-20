#!/usr/bin/env bash
# Execute one `gh api` request with bounded retries and atomic stdout.
# Protected release workflows use this wrapper so transient GitHub 5xx/network
# failures cannot invalidate an otherwise immutable candidate.

set -euo pipefail

attempts="${OPENBURNBAR_GH_API_ATTEMPTS:-5}"
base_sleep_seconds="${OPENBURNBAR_GH_API_BASE_SLEEP_SECONDS:-2}"

if ! [[ "$attempts" =~ ^[1-9][0-9]*$ ]]; then
  echo "OPENBURNBAR_GH_API_ATTEMPTS must be a positive integer." >&2
  exit 2
fi
if ! [[ "$base_sleep_seconds" =~ ^[0-9]+$ ]]; then
  echo "OPENBURNBAR_GH_API_BASE_SLEEP_SECONDS must be a non-negative integer." >&2
  exit 2
fi
if (($# == 0)); then
  echo "usage: gh-api-with-retry.sh <gh api arguments...>" >&2
  exit 2
fi

stdout_file="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/openburnbar-gh-api-stdout.XXXXXX")"
stderr_file="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/openburnbar-gh-api-stderr.XXXXXX")"
trap 'rm -f "$stdout_file" "$stderr_file"' EXIT

for ((attempt = 1; attempt <= attempts; attempt += 1)); do
  : >"$stdout_file"
  : >"$stderr_file"

  if gh api "$@" >"$stdout_file" 2>"$stderr_file"; then
    cat "$stdout_file"
    exit 0
  else
    exit_code=$?
  fi

  cat "$stderr_file" >&2
  if ((attempt == attempts)); then
    echo "gh api failed after ${attempts} attempts." >&2
    exit "$exit_code"
  fi

  sleep_seconds=$((base_sleep_seconds * attempt))
  echo "gh api attempt ${attempt}/${attempts} failed; retrying in ${sleep_seconds}s." >&2
  sleep "$sleep_seconds"
done
