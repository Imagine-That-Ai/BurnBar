#!/usr/bin/env bash
# Regenerate the Swift file-size baseline. Run this after decomposing a giant
# file so the budget ratchets DOWN. The target line count is preserved; pass
# --target N to retighten the threshold itself.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/swift-file-size-baseline.json"
counter_path="${repo_root}/tools/error-debt/count-swift-file-size.py"

target=2000
if [[ "${1:-}" == "--target" ]]; then
  target="${2:?--target needs a value}"
elif [[ -f "${baseline_path}" ]]; then
  target="$(node -e "console.log(JSON.parse(require('node:fs').readFileSync(process.argv[1],'utf8')).target)" "${baseline_path}")"
fi

python3 "${counter_path}" --repo-root "${repo_root}" --target "${target}" --format json > "${baseline_path}"
total="$(node -e "console.log(JSON.parse(require('node:fs').readFileSync(process.argv[1],'utf8')).total)" "${baseline_path}")"
echo "Updated ${baseline_path} (target=${target}, files over target=${total})"
