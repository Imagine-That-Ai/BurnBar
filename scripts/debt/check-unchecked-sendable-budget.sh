#!/usr/bin/env bash
# Fail-closed @unchecked Sendable gate.
#
# The ratchet bucket (fixable escape hatches) is at ZERO and must stay there: any
# new `@unchecked Sendable` conformance fails CI unless it is a genuinely-
# irreducible exception carrying a `sendable-allowlist: <reason-id>` token (inline on
# the line, or in the contiguous comment block directly above it) from the canonical
# registry below (documented in docs/security/UNCHECKED_SENDABLE_REMEDIATION.md).
#
# There is intentionally no baseline file: the budget is asserted to be 0, not
# ratcheted against a stored number.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
counter_path="${repo_root}/tools/concurrency-debt/count-unchecked-sendable.sh"

# Canonical allowlist reason-ids. Adding a new one requires a documented rationale
# in docs/security/UNCHECKED_SENDABLE_REMEDIATION.md and a reviewer sign-off.
allowed_reason_ids=(
  "iroh-ffi-handle"
  "single-threaded-vector-builder"
  "sqlite-raw-pointer"
  "corehid-backend"
  "process-handle"
  "firebase-sdk-handle"
  "firestore-any-payload"
  "firestore-any-test-fake"
  "foundation-sdk-shim"
  "apple-media-buffer"
  "swift-crypto-key-material"
  "database-handle-wrapper"
  "internal-lock-snapshot-store"
  "locked-formatter-cache"
  "nslock-blocking-outcome"
  "nslock-protected-storage"
  "serial-queue-confined-watcher"
)

live_report="$(mktemp "${TMPDIR:-/tmp}/unchecked-sendable-live.XXXXXX")"
trap 'rm -f "${live_report}"' EXIT
bash "${counter_path}" --repo-root "${repo_root}" --format json > "${live_report}"

ratchet="$(node -e "console.log(JSON.parse(require('node:fs').readFileSync(process.argv[1],'utf8')).total)" "${live_report}")"
allowlist="$(node -e "console.log(JSON.parse(require('node:fs').readFileSync(process.argv[1],'utf8')).allowlist)" "${live_report}")"

echo "@unchecked Sendable gate: ratchet=${ratchet} (must be 0) allowlist=${allowlist}"

exclude_re='(^|/)(Tests?|Mocks?|Fixtures?|Preview Content|\.build|\.build-codex|\.swiftpm|DerivedData|\.derived-data|checkouts|build)/'
status=0

# 1) Ratchet must be zero. List any un-allowlisted live conformances.
if [[ "${ratchet}" -ne 0 ]]; then
  echo "ERROR: ${ratchet} fixable @unchecked Sendable conformance(s) reintroduced." >&2
  echo "Make the type genuinely Sendable (actor isolation, @MainActor, a Locked/OSAllocatedUnfairLock box, or a typed Sendable payload)." >&2
  echo "If it is genuinely irreducible (FFI/raw pointer/SDK gap), tag it with an AUDIT comment carrying a 'sendable-allowlist: <reason-id>' token and document it." >&2
  echo "Offending sites:" >&2
  for root in AgentLens OpenBurnBarMobile OpenBurnBarCore/Sources OpenBurnBarDaemon/Sources; do
    [[ -d "${repo_root}/${root}" ]] || continue
    while IFS= read -r rel; do
      [[ -n "${rel}" ]] || continue
      awk '
        { line[NR] = $0 }
        /@unchecked[[:space:]]+Sendable/ && $0 !~ /^[[:space:]]*(\/\/|\/\*|\*)/ {
          allow = ($0 ~ /sendable-allowlist:/) ? 1 : 0
          for (i = NR - 1; i >= 1; i--) {
            if (line[i] ~ /^[[:space:]]*(\/\/|\/\*|\*)/) {
              if (line[i] ~ /sendable-allowlist:/) { allow = 1; break }
            } else break
          }
          if (!allow) printf "  %s:%d: %s\n", FILENAME, NR, $0
        }
      ' "${repo_root}/${rel}" >&2
    done < <(grep -rlE "@unchecked[[:space:]]+Sendable" "${repo_root}/${root}" --include="*.swift" 2>/dev/null \
              | sed "s#^${repo_root}/##" | { grep -vE "${exclude_re}" || true; })
  done
  status=1
fi

# 2) Every allowlist token must use a registered reason-id (bash 3.2-portable).
known_ids=" ${allowed_reason_ids[*]} "
while IFS= read -r used; do
  [[ -n "${used}" ]] || continue
  if [[ "${known_ids}" != *" ${used} "* ]]; then
    echo "ERROR: unknown sendable-allowlist reason-id '${used}'. Add it to scripts/debt/check-unchecked-sendable-budget.sh + docs/security/UNCHECKED_SENDABLE_REMEDIATION.md with a rationale." >&2
    status=1
  fi
done < <(for root in AgentLens OpenBurnBarMobile OpenBurnBarCore/Sources OpenBurnBarDaemon/Sources; do
            [[ -d "${repo_root}/${root}" ]] || continue
            grep -rhoE "sendable-allowlist: [a-z0-9-]+" "${repo_root}/${root}" --include="*.swift" 2>/dev/null
          done | sed 's/^sendable-allowlist: //' | sort -u)

if [[ "${status}" -eq 0 ]]; then
  echo "@unchecked Sendable ratchet is zero; ${allowlist} documented allowlist exception(s)."
fi
exit "${status}"
