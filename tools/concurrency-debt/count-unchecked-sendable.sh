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

# Dual-bucket accounting. Each real `@unchecked Sendable` conformance is either:
#   * RATCHET   — a fixable escape hatch (mutable state, isolation gap). Enforced
#                 toward zero; CI fails on any increase. This is the budget "total".
#   * ALLOWLIST — a genuinely-irreducible exception (FFI handle, raw pointer,
#                 Firebase/Foundation SDK type not yet Sendable-annotated), marked
#                 with a `sendable-allowlist: <reason-id>` token in its AUDIT comment
#                 (within 8 lines) or inline. Documented in docs/security/
#                 UNCHECKED_SENDABLE_REMEDIATION.md, NOT counted against the budget.
# Comment-only lines (e.g. `// AUDIT(@unchecked Sendable): …`) are never counted.
count_root() {
  local root="$1"
  local abs="${repo_root}/${root}"
  [[ -d "${abs}" ]] || { echo "0 0"; return 0; }
  grep -rlE "@unchecked[[:space:]]+Sendable" "${abs}" --include="*.swift" 2>/dev/null \
    | sed "s#^${repo_root}/##" \
    | { grep -vE "${exclude_re}" || true; } \
    | while IFS= read -r rel; do
        [[ -n "${rel}" ]] || continue
        awk '
          { line[NR] = $0 }
          /@unchecked[[:space:]]+Sendable/ && $0 !~ /^[[:space:]]*(\/\/|\/\*|\*)/ {
            allow = ($0 ~ /sendable-allowlist:/) ? 1 : 0
            for (i = NR - 1; i >= NR - 8 && i >= 1; i--) if (line[i] ~ /sendable-allowlist:/) allow = 1
            if (allow) a++; else r++
          }
          END { print (r + 0), (a + 0) }
        ' "${repo_root}/${rel}"
      done \
    | awk '{ r += $1; a += $2 } END { print (r + 0), (a + 0) }'
}

read -r agent_lens agent_lens_allow <<EOF
$(count_root "AgentLens")
EOF
read -r core core_allow <<EOF
$(count_root "OpenBurnBarCore/Sources")
EOF
read -r daemon daemon_allow <<EOF
$(count_root "OpenBurnBarDaemon/Sources")
EOF
read -r mobile mobile_allow <<EOF
$(count_root "OpenBurnBarMobile")
EOF
total=$(( agent_lens + core + daemon + mobile ))
allowlist=$(( agent_lens_allow + core_allow + daemon_allow + mobile_allow ))

if [[ "${format}" == "text" ]]; then
  echo "unchecked_sendable ratchet=${total} allowlist=${allowlist} agent_lens=${agent_lens} core=${core} daemon=${daemon} mobile=${mobile}"
else
  cat <<EOF
{
  "total": ${total},
  "allowlist": ${allowlist},
  "agentLens": ${agent_lens},
  "core": ${core},
  "daemon": ${daemon},
  "mobile": ${mobile}
}
EOF
fi
