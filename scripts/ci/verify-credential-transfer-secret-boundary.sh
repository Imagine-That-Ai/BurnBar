#!/usr/bin/env bash
# Credential-transfer decryption secrets must never be server-observable.
set -euo pipefail
cd "$(dirname "$0")/../.."

scan_paths=(
  android/app/src/main
  functions/src
  functions/scripts
  firestore.rules
)

failures=0

check_absent() {
  local label="$1"
  local pattern="$2"
  if rg -n --pcre2 "$pattern" "${scan_paths[@]}"; then
    echo "FAIL: ${label}" >&2
    failures=$((failures + 1))
  else
    echo "PASS: ${label}"
  fi
}

check_absent "no Firestore document(code) credential-transfer writes" 'document\s*\(\s*code\s*\)'
check_absent "no credential_transfers/\${code} Admin paths" 'credential_transfers/\$\{code\}'
check_absent "no legacy optional request.data?.code lookup" 'request\.data\?\.\s*code'
check_absent "no legacy Firestore rules code validator" 'validCredentialTransferCode'
check_absent "no transferCode/secretCode fields in production boundary" '\b(transferCode|secretCode)\b\s*[:=]'

rules_block="$(
  awk '
    /match \/credential_transfers\/\{/ { in_block = 1 }
    in_block { print }
    in_block && /--- Public read-only model-landscape metadata ---/ { in_block = 0 }
  ' firestore.rules
)"

if printf "%s\n" "$rules_block" | rg -n --pcre2 'allow\s+create|allow\s+(read,\s*write|read|write):\s*if\s+(?!false\b)'; then
  echo "FAIL: credential_transfers must not allow client create/read/write" >&2
  failures=$((failures + 1))
else
  echo "PASS: credential_transfers has no client create/read/write allowance"
fi

if (( failures > 0 )); then
  echo "FAIL: credential-transfer secret boundary regression detected" >&2
  exit 1
fi

echo "PASS: credential-transfer secret boundary"
