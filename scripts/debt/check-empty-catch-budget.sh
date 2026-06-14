#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
counter_path="${repo_root}/tools/error-debt/count-error-debt.py"

live_report="$(mktemp "${TMPDIR:-/tmp}/empty-catch-live.XXXXXX")"
trap 'rm -f "${live_report}"' EXIT

python3 "${counter_path}" --repo-root "${repo_root}" --metric empty-catch --format json > "${live_report}"

node - "${live_report}" <<'NODE'
const fs = require("node:fs");

const [livePath] = process.argv.slice(2);
const live = JSON.parse(fs.readFileSync(livePath, "utf8"));
const count = live.emptyCatch?.total;

if (!Number.isInteger(count)) {
  console.error(`Invalid live empty-catch count in ${livePath}`);
  process.exit(1);
}

console.log(`Empty catch budget: live=${count} target=0`);

if (count > 0) {
  console.error(`Empty catch debt is forbidden; remove ${count} empty catch block${count === 1 ? "" : "s"}.`);
  process.exit(1);
}
NODE
