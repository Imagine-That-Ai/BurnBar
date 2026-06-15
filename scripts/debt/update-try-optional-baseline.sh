#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/try-optional-baseline.json"
counter_path="${repo_root}/tools/error-debt/count-error-debt.py"

live="$(python3 "${counter_path}" --repo-root "${repo_root}" --metric try-optional --format json)"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Write the full baseline (total + per-root breakdown) straight from the counter
# so the recorded scope can never drift from what the counter actually measures.
node -e '
const live = JSON.parse(process.argv[1]);
const generatedAt = process.argv[2];
const to = live.tryOptional;
const out = {
  total: to.total,
  scope: "AgentLens + OpenBurnBarCore/Sources + OpenBurnBarMobile + OpenBurnBarDaemon/Sources (production Swift, tests excluded)",
  byRoot: to.byRoot,
  generatedAt,
  note: "try? occurrences across all production Swift roots. CI fails on any increase to total; ratchet down only.",
};
require("node:fs").writeFileSync(process.argv[3], JSON.stringify(out, null, 2) + "\n");
' "${live}" "${generated_at}" "${baseline_path}"

echo "Updated ${baseline_path} (total=$(node -e "console.log(JSON.parse(process.argv[1]).tryOptional.total)" "${live}"))"
