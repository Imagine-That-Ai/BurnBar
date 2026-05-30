#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/empty-catch-baseline.json"
counter_path="${repo_root}/tools/error-debt/count-error-debt.py"

live="$(python3 "${counter_path}" --repo-root "${repo_root}" --metric empty-catch --format json)"
total="$(node -e "const j=JSON.parse(process.argv[1]); console.log(j.emptyCatch.total)" "${live}")"
agent_lens="$(node -e "const j=JSON.parse(process.argv[1]); console.log(j.emptyCatch.agent_lens)" "${live}")"
daemon="$(node -e "const j=JSON.parse(process.argv[1]); console.log(j.emptyCatch.daemon)" "${live}")"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "${baseline_path}" <<EOF
{
  "total": ${total},
  "agent_lens": ${agent_lens},
  "daemon": ${daemon},
  "generatedAt": "${generated_at}",
  "note": "Empty catch {} blocks in AgentLens + OpenBurnBarDaemon. CI fails on increase."
}
EOF

echo "Updated ${baseline_path} (total=${total})"
