#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/unchecked-sendable-baseline.json"
counter_path="${repo_root}/tools/concurrency-debt/count-unchecked-sendable.sh"

live="$(bash "${counter_path}" --repo-root "${repo_root}" --format json)"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

read -r total agent_lens core daemon mobile <<EOF
$(node -e "const j=JSON.parse(process.argv[1]); console.log(j.total, j.agentLens, j.core, j.daemon, j.mobile)" "${live}")
EOF

mkdir -p "$(dirname "${baseline_path}")"
cat > "${baseline_path}" <<EOF
{
  "total": ${total},
  "agentLens": ${agent_lens},
  "core": ${core},
  "daemon": ${daemon},
  "mobile": ${mobile},
  "scope": "AgentLens + OpenBurnBarCore/Sources + OpenBurnBarDaemon/Sources + OpenBurnBarMobile production Swift (tests/mocks/fixtures/build products excluded)",
  "generatedAt": "${generated_at}",
  "note": "@unchecked Sendable annotations in OpenBurnBar production code. CI fails on increase; ratchet down and regenerate when removed."
}
EOF

echo "Updated ${baseline_path} (total=${total})"
