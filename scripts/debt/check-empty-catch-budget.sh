#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/empty-catch-baseline.json"
counter_path="${repo_root}/tools/error-debt/count-error-debt.py"

if [[ ! -f "${baseline_path}" ]]; then
  echo "Missing empty catch baseline: ${baseline_path}" >&2
  echo "Run scripts/debt/update-empty-catch-baseline.sh to capture the current budget." >&2
  exit 1
fi

live_report="$(mktemp "${TMPDIR:-/tmp}/empty-catch-live.XXXXXX")"
trap 'rm -f "${live_report}"' EXIT

python3 "${counter_path}" --repo-root "${repo_root}" --metric empty-catch --format json > "${live_report}"

node - "${baseline_path}" "${live_report}" <<'NODE'
const fs = require("node:fs");

const [baselinePath, livePath] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
const live = JSON.parse(fs.readFileSync(livePath, "utf8"));
const count = live.emptyCatch?.total;

if (!Number.isInteger(count)) {
  console.error(`Invalid live empty-catch count in ${livePath}`);
  process.exit(1);
}
if (!Number.isInteger(baseline.total)) {
  console.error(`Invalid empty catch baseline total in ${baselinePath}`);
  process.exit(1);
}

console.log(`Empty catch budget: live=${count} baseline=${baseline.total}`);

if (count > baseline.total) {
  console.error(`Empty catch budget exceeded by ${count - baseline.total}.`);
  console.error("Remove the new empty catches before merging.");
  process.exit(1);
}

if (count < baseline.total) {
  console.log(`Empty catch debt improved by ${baseline.total - count}; update the baseline intentionally.`);
}
NODE
