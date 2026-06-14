#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
counter_path="${repo_root}/tools/error-debt/count-error-debt.py"

live_report="$(mktemp "${TMPDIR:-/tmp}/try-optional-live.XXXXXX")"
trap 'rm -f "${live_report}"' EXIT

python3 "${counter_path}" --repo-root "${repo_root}" --metric try-optional --format json > "${live_report}"

node - "${live_report}" <<'NODE'
const fs = require("node:fs");

const [livePath] = process.argv.slice(2);
const live = JSON.parse(fs.readFileSync(livePath, "utf8"));
const count = live.tryOptional?.total;

if (!Number.isInteger(count)) {
  console.error(`Invalid live try? count in ${livePath}`);
  process.exit(1);
}

console.log(`try? assert-zero: live=${count} target=0`);
if (count !== 0) {
  console.error("Untagged try? in AgentLens/Services must stay at zero.");
  console.error("Replace the new site with do/catch handling, or add a reviewed try?-ok(<reason>) tag only when optionality is genuinely correct.");
  process.exit(1);
}
NODE
