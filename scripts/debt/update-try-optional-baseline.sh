#!/usr/bin/env bash
set -euo pipefail

# remediation(try-optional-budget-direction-guard): This script used to blindly
# `cat >`-write the live try? count into the baseline in EITHER direction, which
# ratcheted the CEILING upward (797->800->808) every time someone re-ran it after
# adding new try? sites. The baseline.total is a ceiling that must only DECREASE.
# We now refuse to raise it unless an explicit, reviewed --allow-increase override
# is passed, and we update only `total`/`generatedAt` via jq so the `direction`/
# `ratchetPolicy`/`note`/`scope` fields stay intact.

allow_increase=false
for arg in "$@"; do
  case "${arg}" in
    --allow-increase)
      allow_increase=true
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: update-try-optional-baseline.sh [--allow-increase]

Re-captures the live try? count into budgets/try-optional-baseline.json.

The baseline total is a CEILING that must only DECREASE. By default this script
REFUSES to write a higher number (that would loosen the budget). Pass
--allow-increase ONLY for a deliberate, reviewed baseline raise; it prints a loud
warning and proceeds.
USAGE
      exit 0
      ;;
    *)
      echo "update-try-optional-baseline: unknown argument: ${arg}" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/try-optional-baseline.json"
counter_path="${repo_root}/tools/error-debt/count-error-debt.py"

# remediation(try-optional-budget-direction-guard): jq is required to update only
# the `total`/`generatedAt` fields without clobbering the ceiling-policy metadata.
if ! command -v jq >/dev/null 2>&1; then
  echo "update-try-optional-baseline: jq is required to update the baseline in place" >&2
  exit 1
fi

if [[ ! -f "${baseline_path}" ]]; then
  echo "update-try-optional-baseline: missing baseline ${baseline_path}" >&2
  exit 1
fi

live="$(python3 "${counter_path}" --repo-root "${repo_root}" --metric try-optional --format json)"
total="$(node -e "const j=JSON.parse(process.argv[1]); console.log(j.tryOptional.total)" "${live}")"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# remediation(try-optional-budget-direction-guard): read the existing ceiling and
# refuse to ratchet it upward. Equal or lower writes through (the legitimate
# pay-down case); only a higher live count is gated behind --allow-increase.
existing_total="$(jq -r '.total' "${baseline_path}")"
if [[ -z "${existing_total}" || "${existing_total}" == "null" ]]; then
  echo "update-try-optional-baseline: could not read existing .total from ${baseline_path}" >&2
  exit 1
fi

if [[ "${total}" -gt "${existing_total}" ]]; then
  if [[ "${allow_increase}" != true ]]; then
    echo "update-try-optional-baseline: REFUSING to raise the try? ceiling from ${existing_total} to ${total}." >&2
    echo "The baseline total is a CEILING that must only DECREASE. Remove the new try? sites instead of absorbing them." >&2
    echo "If this is a deliberate, reviewed baseline raise, re-run with --allow-increase." >&2
    exit 1
  fi
  echo "WARNING: --allow-increase set; raising the try? ceiling from ${existing_total} to ${total}." >&2
  echo "WARNING: this LOOSENS the budget and must be a deliberate, reviewed decision." >&2
fi

# remediation(try-optional-budget-direction-guard): update only total/generatedAt
# via jq (writing through a temp file) so direction/ratchetPolicy/note/scope and
# any other fields are preserved.
tmp_path="$(mktemp "${TMPDIR:-/tmp}/try-optional-baseline.XXXXXX")"
trap 'rm -f "${tmp_path}"' EXIT
jq --argjson total "${total}" --arg generatedAt "${generated_at}" '
  .total = $total
  | .generatedAt = $generatedAt
' "${baseline_path}" > "${tmp_path}"
mv "${tmp_path}" "${baseline_path}"
trap - EXIT

echo "Updated ${baseline_path} (total=${total})"
