#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

violations="$(
  git grep -nE '(curl|wget)[^|;&]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh)|[[:space:]](bash|sh)[[:space:]]+<\(' \
    -- .github scripts \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    || true
)"

if [[ -n "$violations" ]]; then
  echo "Remote shell installer pattern detected. Download installers to a file, pin version+checksum, and execute only after verification." >&2
  echo "$violations" >&2
  exit 1
fi

echo "OK: no curl/wget pipe-to-shell installers in workflows or scripts."
