#!/usr/bin/env bash
# Ratchet gate for knip findings (unused files/deps/exports).
#
# The previous "Unused Dependencies" lanes piped knip to `|| true` — findings
# accumulated invisibly and the green check asserted nothing (diligence
# 2026-06-11, quality-gate theater). Raw enforcement would flip the lane red
# on ~119 pre-existing findings, so this uses the repo's established budget
# idiom (cf. budgets/try-optional-baseline.json): the TOTAL finding count may
# only go down. New debt fails the PR; paying debt down lets you lower the
# baseline in budgets/knip-baseline.json.
#
# Usage: scripts/ci/knip-ratchet.sh <package-dir> <baseline-key>
set -euo pipefail

package_dir="$1"
baseline_key="$2"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
baseline_file="$repo_root/budgets/knip-baseline.json"

output="$(cd "$repo_root/$package_dir" && npx knip --reporter compact 2>&1 || true)"
printf '%s\n' "$output"

# knip's compact reporter prints one section header per issue type with the
# count in trailing parens; the sum is the total finding count.
total=0
while IFS= read -r count; do
  total=$((total + count))
done < <(printf '%s\n' "$output" | sed -n 's/.*(\([0-9][0-9]*\))$/\1/p')

baseline="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$baseline_file" "$baseline_key")"

echo ""
echo "knip[$baseline_key]: findings=$total baseline=$baseline"
if [[ "$total" -gt "$baseline" ]]; then
  echo "::error::knip findings for $baseline_key rose from $baseline to $total. Remove the new unused code/deps, or — if a finding is a knip false positive — configure it in the package's knip config rather than raising the baseline."
  exit 1
fi
if [[ "$total" -lt "$baseline" ]]; then
  echo "::notice::knip findings for $baseline_key dropped to $total — lower the baseline in budgets/knip-baseline.json to lock the improvement in."
fi
echo "knip ratchet OK ($baseline_key)"
