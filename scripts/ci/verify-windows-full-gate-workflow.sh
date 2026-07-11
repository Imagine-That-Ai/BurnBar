#!/usr/bin/env bash
# verify-windows-full-gate-workflow.sh — structural production check for the
# Windows full CI gate workflow (ledger row: ci-windows-full-gate).
#
# Proves the full-suite workflow file is present and defines the dual-arch
# build/test matrix that makes Windows regressions un-mergeable once required.
# Does NOT flip GitHub branch-protection (admin); it proves the gate *exists*
# as product composition in-repo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${ROOT}/.github/workflows/pr-windows-full.yml"

if [[ ! -f "$WF" ]]; then
  echo "windows-full-gate: FAIL missing $WF" >&2
  exit 1
fi

need=(
  "PR Windows Full Suite"
  "windows-latest"
  "windows-11-arm"
  "dotnet test"
  "windows/"
)

for needle in "${need[@]}"; do
  if ! grep -Fq "$needle" "$WF"; then
    echo "windows-full-gate: FAIL workflow missing required content: $needle" >&2
    exit 1
  fi
done

echo "windows-full-gate: PASS"
echo "  workflow: $WF"
echo "  arches: windows-latest + windows-11-arm"
echo "  note: requiring this check on main is an admin branch-protection step;"
echo "        composition of the gate itself is verified in-repo."
exit 0
