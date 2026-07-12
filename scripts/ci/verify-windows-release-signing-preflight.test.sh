#!/usr/bin/env bash
# Regression fixtures for scripts/ci/verify-windows-release-signing-preflight.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$ROOT/scripts/ci/verify-windows-release-signing-preflight.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

base_env=(
  WINDOWS_CODESIGN_ENDPOINT=https://eus.codesigning.azure.net/
  WINDOWS_CODESIGN_ACCOUNT_NAME=openburnbarwin202607
  WINDOWS_CODESIGN_CERT_PROFILE_NAME=openburnbarwin202607-public
  WINDOWS_CODESIGN_AZURE_TENANT_ID=tenant-id
  WINDOWS_CODESIGN_AZURE_CLIENT_ID=client-id
  WINDOWS_CODESIGN_AZURE_CLIENT_SECRET=client-secret
  WINDOWS_UPDATE_SIGNING_KEY=private-seed-base64
  WINDOWS_UPDATE_PUBLIC_KEY=public-key-base64
  GITHUB_REF_TYPE=branch
  GITHUB_REF_NAME=main
)

run_case() {
  local want="$1"
  local name="$2"
  shift 2
  local log="$TMP_ROOT/${name//[^A-Za-z0-9_.-]/_}.log"
  local output="$TMP_ROOT/${name//[^A-Za-z0-9_.-]/_}.out"
  set +e
  env -i PATH="$PATH" GITHUB_OUTPUT="$output" "$@" >"$log" 2>&1
  local got=$?
  set -e
  if [[ "$got" != "$want" ]]; then
    echo "FAIL fixture $name: got exit $got, want $want" >&2
    cat "$log" >&2
    [[ -f "$output" ]] && cat "$output" >&2
    exit 1
  fi
  echo "PASS fixture: $name"
}

assert_log_contains() {
  local name="$1"
  local needle="$2"
  local log="$TMP_ROOT/${name//[^A-Za-z0-9_.-]/_}.log"
  if ! grep -Fq "$needle" "$log"; then
    echo "FAIL fixture $name: expected log to contain: $needle" >&2
    cat "$log" >&2
    exit 1
  fi
}

assert_output_contains() {
  local name="$1"
  local needle="$2"
  local output="$TMP_ROOT/${name//[^A-Za-z0-9_.-]/_}.out"
  if ! grep -Fq "$needle" "$output"; then
    echo "FAIL fixture $name: expected GITHUB_OUTPUT to contain: $needle" >&2
    cat "$output" >&2
    exit 1
  fi
}

run_case 0 complete env "${base_env[@]}" "$VERIFY"
assert_output_contains complete "codesign=true"
assert_output_contains complete "updatekey=true"

run_case 1 certificate-profile-missing env \
  WINDOWS_CODESIGN_ENDPOINT=https://eus.codesigning.azure.net/ \
  WINDOWS_CODESIGN_ACCOUNT_NAME=openburnbarwin202607 \
  WINDOWS_CODESIGN_AZURE_TENANT_ID=tenant-id \
  WINDOWS_CODESIGN_AZURE_CLIENT_ID=client-id \
  WINDOWS_CODESIGN_AZURE_CLIENT_SECRET=client-secret \
  WINDOWS_UPDATE_SIGNING_KEY=private-seed-base64 \
  GITHUB_REF_TYPE=branch \
  GITHUB_REF_NAME=main \
  "$VERIFY"
assert_log_contains certificate-profile-missing "certificate profile is not configured"
assert_log_contains certificate-profile-missing "WINDOWS_CODESIGN_CERT_PROFILE_NAME"

run_case 1 update-key-missing env \
  WINDOWS_CODESIGN_ENDPOINT=https://eus.codesigning.azure.net/ \
  WINDOWS_CODESIGN_ACCOUNT_NAME=openburnbarwin202607 \
  WINDOWS_CODESIGN_CERT_PROFILE_NAME=openburnbarwin202607-public \
  WINDOWS_CODESIGN_AZURE_TENANT_ID=tenant-id \
  WINDOWS_CODESIGN_AZURE_CLIENT_ID=client-id \
  WINDOWS_CODESIGN_AZURE_CLIENT_SECRET=client-secret \
  WINDOWS_UPDATE_PUBLIC_KEY=public-key-base64 \
  GITHUB_REF_TYPE=branch \
  GITHUB_REF_NAME=main \
  "$VERIFY"
assert_log_contains update-key-missing "WINDOWS_UPDATE_SIGNING_KEY is missing"

run_case 1 update-public-key-missing env \
  WINDOWS_CODESIGN_ENDPOINT=https://eus.codesigning.azure.net/ \
  WINDOWS_CODESIGN_ACCOUNT_NAME=openburnbarwin202607 \
  WINDOWS_CODESIGN_CERT_PROFILE_NAME=openburnbarwin202607-public \
  WINDOWS_CODESIGN_AZURE_TENANT_ID=tenant-id \
  WINDOWS_CODESIGN_AZURE_CLIENT_ID=client-id \
  WINDOWS_CODESIGN_AZURE_CLIENT_SECRET=client-secret \
  WINDOWS_UPDATE_SIGNING_KEY=private-seed-base64 \
  GITHUB_REF_TYPE=branch \
  GITHUB_REF_NAME=main \
  "$VERIFY"
assert_log_contains update-public-key-missing "WINDOWS_UPDATE_PUBLIC_KEY is missing"

run_case 1 no-signing-config env \
  WINDOWS_UPDATE_SIGNING_KEY=private-seed-base64 \
  WINDOWS_UPDATE_PUBLIC_KEY=public-key-base64 \
  GITHUB_REF_TYPE=branch \
  GITHUB_REF_NAME=main \
  "$VERIFY"
assert_log_contains no-signing-config "Windows Authenticode signing is not configured"

run_case 0 unsigned-manual-dry-run env \
  WINDOWS_RELEASE_ALLOW_UNSIGNED=1 \
  GITHUB_REF_TYPE=branch \
  GITHUB_REF_NAME=manual-dry-run \
  "$VERIFY"
assert_output_contains unsigned-manual-dry-run "codesign=false"
assert_output_contains unsigned-manual-dry-run "updatekey=false"
assert_log_contains unsigned-manual-dry-run "Unsigned Windows release dry-run requested"

run_case 1 unsigned-release-tag-rejected env \
  WINDOWS_RELEASE_ALLOW_UNSIGNED=1 \
  GITHUB_REF_TYPE=tag \
  GITHUB_REF_NAME=windows-v1.2.3 \
  "$VERIFY"
assert_log_contains unsigned-release-tag-rejected "Unsigned dry-run is not allowed for windows-v* tag releases"

run_case 1 partial-config env \
  WINDOWS_CODESIGN_ENDPOINT=https://eus.codesigning.azure.net/ \
  WINDOWS_CODESIGN_ACCOUNT_NAME=openburnbarwin202607 \
  WINDOWS_CODESIGN_CERT_PROFILE_NAME=openburnbarwin202607-public \
  WINDOWS_CODESIGN_AZURE_TENANT_ID=tenant-id \
  WINDOWS_UPDATE_SIGNING_KEY=private-seed-base64 \
  WINDOWS_UPDATE_PUBLIC_KEY=public-key-base64 \
  GITHUB_REF_TYPE=branch \
  GITHUB_REF_NAME=main \
  "$VERIFY"
assert_log_contains partial-config "Windows Authenticode signing configuration is partial"
assert_log_contains partial-config "WINDOWS_CODESIGN_AZURE_CLIENT_ID"

echo "PASS: Windows release signing preflight fixtures"
