#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/try-optional-baseline.json"
counter_path="${repo_root}/tools/error-debt/count-error-debt.py"

if [[ ! -f "${baseline_path}" ]]; then
  echo "Missing try? baseline: ${baseline_path}" >&2
  echo "Run scripts/debt/update-try-optional-baseline.sh to capture the current budget." >&2
  exit 1
fi

live_report="$(mktemp "${TMPDIR:-/tmp}/try-optional-live.XXXXXX")"
trap 'rm -f "${live_report}"' EXIT

python3 "${counter_path}" --repo-root "${repo_root}" --metric try-optional --format json > "${live_report}"

node - "${baseline_path}" "${live_report}" <<'NODE'
const fs = require("node:fs");

const [baselinePath, livePath] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
const live = JSON.parse(fs.readFileSync(livePath, "utf8"));
const count = live.tryOptional?.total;

if (!Number.isInteger(count)) {
  console.error(`Invalid live try? count in ${livePath}`);
  process.exit(1);
}
if (!Number.isInteger(baseline.total)) {
  console.error(`Invalid try? baseline total in ${baselinePath}`);
  process.exit(1);
}

console.log(`try? budget: live=${count} baseline=${baseline.total}`);

if (count > baseline.total) {
  console.error(`try? budget exceeded by ${count - baseline.total}.`);
  console.error("Remove the new try? usages before merging.");
  process.exit(1);
}

if (count < baseline.total) {
  console.log(`try? debt improved by ${baseline.total - count}; update the baseline intentionally.`);
}
NODE
