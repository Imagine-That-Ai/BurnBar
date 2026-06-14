#!/usr/bin/env bash
#
# F-MD08-014 — fail closed when security-claims.md references source files that
# do not exist at HEAD. Prevents audit/docs drift from certifying absent controls.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

CLAIMS_FILE="security/threat-model/security-claims.md"
if [[ ! -f "$CLAIMS_FILE" ]]; then
  echo "✗ check-security-claims: missing $CLAIMS_FILE"
  exit 1
fi

missing=()
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  if [[ ! -e "$path" ]]; then
    missing+=("$path")
  fi
done < <(python3 scripts/ci/_extract_security_claim_paths.py)

if ((${#missing[@]} > 0)); then
  echo "✗ check-security-claims: security-claims.md references missing files:"
  for path in "${missing[@]}"; do
    echo "  - $path"
  done
  exit 1
fi

echo "✓ check-security-claims: referenced implementation paths exist at HEAD."