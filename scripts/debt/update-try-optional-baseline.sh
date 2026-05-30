#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/try-optional-baseline.json"
counter_path="${repo_root}/tools/error-debt/count-error-debt.py"

live="$(python3 "${counter_path}" --repo-root "${repo_root}" --metric try-optional --format json)"
total="$(node -e "const j=JSON.parse(process.argv[1]); console.log(j.tryOptional.total)" "${live}")"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "${baseline_path}" <<EOF
{
  "total": ${total},
  "scope": "AgentLens/Services",
  "generatedAt": "${generated_at}",
  "note": "try? occurrences in AgentLens/Services. CI fails on increase."
}
EOF

echo "Updated ${baseline_path} (total=${total})"
