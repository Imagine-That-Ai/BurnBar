#!/usr/bin/env bash
# Divergence guard: the accepted RustSec advisory set must live in exactly ONE
# place — crates/openburnbar-iroh/deny.toml. This fails CI if anyone reintroduces
# a hand-maintained --ignore list in the workflow (the drift that this single
# source was created to eliminate), or if the derived set is empty.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SAST_WORKFLOW="${ROOT_DIR}/.github/workflows/rust-sast.yml"
DERIVE="${ROOT_DIR}/scripts/ci/rust-advisory-ignores.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. No hardcoded RustSec ignore literals in the SAST workflow — those must be
#    derived from deny.toml via scripts/ci/rust-advisory-ignores.sh instead.
if grep -nE -- '--ignore[[:space:]]+RUSTSEC' "$SAST_WORKFLOW" >/dev/null 2>&1; then
  echo "Hardcoded advisory ignores found in $(basename "$SAST_WORKFLOW"):" >&2
  grep -nE -- '--ignore[[:space:]]+RUSTSEC' "$SAST_WORKFLOW" >&2
  fail "Move these into crates/openburnbar-iroh/deny.toml and derive them via scripts/ci/rust-advisory-ignores.sh."
fi

# 2. The single source must yield a non-empty, well-formed advisory set.
#    (Portable read loop — avoids `mapfile`, which is absent on bash 3.2.)
IDS=()
while IFS= read -r id; do
  [[ -n "$id" ]] && IDS+=("$id")
done < <(bash "$DERIVE")
[[ "${#IDS[@]}" -gt 0 ]] || fail "deny.toml produced an empty advisory ignore set."
for id in "${IDS[@]}"; do
  [[ "$id" =~ ^RUSTSEC-[0-9]{4}-[0-9]{4}$ ]] || fail "malformed advisory id from deny.toml: '${id}'"
done

echo "PASS: advisory ignore set is single-sourced from deny.toml (${#IDS[@]} ids: ${IDS[*]})."
