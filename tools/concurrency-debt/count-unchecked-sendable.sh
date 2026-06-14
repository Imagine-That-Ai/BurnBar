#!/usr/bin/env bash
# Count @unchecked Sendable annotations in OpenBurnBar production Swift code.
#
# This is the concurrency-debt counterpart to tools/error-debt/count-error-debt.py
# and tools/type-debt/audit-unsafe-casts.mjs. It greps production Swift sources
# across the four shipping roots and emits a JSON report consumed by
# scripts/debt/check-unchecked-sendable-budget.sh (CI fails on increase).
#
# Usage:
#   tools/concurrency-debt/count-unchecked-sendable.sh [--repo-root <path>] [--format json|text]
#
# Notes:
#   * Test, mock, fixture, preview, and build-product paths are excluded so the
#     budget governs only shipped concurrency escape hatches.
#   * For OpenBurnBarCore / OpenBurnBarDaemon only the Sources/ trees are scanned,
#     which keeps generated SwiftPM .build/checkouts artifacts out of the count.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
format="json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      repo_root="$(cd "$2" && pwd)"
      shift 2
      ;;
    --format)
      format="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Paths excluded from the budget: test/mock/fixture/preview sources and any
# build-product trees that may exist under a scanned root.
exclude_re='(^|/)(Tests?|Mocks?|Fixtures?|Preview Content|\.build|\.build-codex|\.swiftpm|DerivedData|\.derived-data|checkouts|build)/'

count_root() {
  local root="$1"
  local abs="${repo_root}/${root}"
  [[ -d "${abs}" ]] || { echo 0; return 0; }
  grep -rlE "@unchecked[[:space:]]+Sendable" "${abs}" --include="*.swift" 2>/dev/null \
    | sed "s#^${repo_root}/##" \
    | { grep -vE "${exclude_re}" || true; } \
    | while IFS= read -r rel; do
        [[ -n "${rel}" ]] || continue
        # Count real conformance annotations only. Lines that merely *mention*
        # `@unchecked Sendable` inside a comment (e.g. `// AUDIT(@unchecked
        # Sendable): …` justifications, which the budget actively encourages) are
        # documentation, not debt, so excluding comment lines keeps the count
        # equal to the number of live escape hatches.
        awk '/@unchecked[[:space:]]+Sendable/ && $0 !~ /^[[:space:]]*(\/\/|\/\*|\*)/ { count++ } END { print count + 0 }' "${repo_root}/${rel}"
      done \
    | awk '{ sum += $1 } END { print sum + 0 }'
}

agent_lens="$(count_root "AgentLens")"
core="$(count_root "OpenBurnBarCore/Sources")"
daemon="$(count_root "OpenBurnBarDaemon/Sources")"
mobile="$(count_root "OpenBurnBarMobile")"
total=$(( agent_lens + core + daemon + mobile ))

if [[ "${format}" == "text" ]]; then
  echo "unchecked_sendable total=${total} agent_lens=${agent_lens} core=${core} daemon=${daemon} mobile=${mobile}"
else
  cat <<EOF
{
  "total": ${total},
  "agentLens": ${agent_lens},
  "core": ${core},
  "daemon": ${daemon},
  "mobile": ${mobile}
}
EOF
fi
