#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-rule0-test.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

init_case_repo() {
  local repo="$work_root/$1"
  mkdir -p "$repo/scripts/ci"
  cp "$repo_root/scripts/ci/verify-signal-rule0.sh" "$repo/scripts/ci/verify-signal-rule0.sh"
  (
    cd "$repo"
    git init -q
    git config user.email "rule0-test@example.invalid"
    git config user.name "Rule0 Test"
    mkdir -p docs
    printf 'base\n' > docs/base.txt
    git add .
    git commit -q -m "base"
  )
  printf '%s\n' "$repo"
}

run_guard() {
  local repo="$1"
  shift
  (
    cd "$repo"
    env "$@" bash scripts/ci/verify-signal-rule0.sh HEAD~1
  )
}

capture_guard() {
  local repo="$1"
  shift
  local output status
  if output="$(run_guard "$repo" "$@" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  printf '%s\n%s\n' "$status" "$output"
}

assert_status() {
  local expected="$1"
  local actual="$2"
  local output="$3"
  local label="$4"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s expected status %s, got %s\n%s\n' "$label" "$expected" "$actual" "$output" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'FAIL: %s missing %q\n%s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

commit_change() {
  local repo="$1"
  local path="$2"
  local body="$3"
  local message="$4"
  (
    cd "$repo"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$body" > "$path"
    git add "$path"
    git commit -q -m "$message"
  )
}

repo="$(init_case_repo unprotected)"
commit_change "$repo" docs/ordinary.txt "ok" "ordinary docs change"
result="$(capture_guard "$repo")"
status="$(printf '%s\n' "$result" | sed -n '1p')"
output="$(printf '%s\n' "$result" | sed '1d')"
assert_status 0 "$status" "$output" "unprotected change"
assert_contains "$output" "Rule-0 OK" "unprotected change"

repo="$(init_case_repo untrusted-ack)"
commit_change "$repo" third_party/hermes-agent/manifest.json '{"pinnedCommit":"abc"}' $'update vendored manifest\n\nRule0-Ack: hermes-agent reviewed'
result="$(capture_guard "$repo")"
status="$(printf '%s\n' "$result" | sed -n '1p')"
output="$(printf '%s\n' "$result" | sed '1d')"
assert_status 1 "$status" "$output" "untrusted Rule0-Ack"
assert_contains "$output" "Rule0-Ack trailer(s) found but ignored" "untrusted Rule0-Ack"
assert_contains "$output" "RULE-0 VIOLATION: third_party/hermes-agent/manifest.json" "untrusted Rule0-Ack"

repo="$(init_case_repo trusted-ack)"
commit_change "$repo" third_party/hermes-agent/manifest.json '{"pinnedCommit":"abc"}' $'update vendored manifest\n\nRule0-Ack: hermes-agent reviewed'
result="$(capture_guard "$repo" OPENBURNBAR_RULE0_TRUSTED_OWNER_ACK=1)"
status="$(printf '%s\n' "$result" | sed -n '1p')"
output="$(printf '%s\n' "$result" | sed '1d')"
assert_status 0 "$status" "$output" "trusted Rule0-Ack"
assert_contains "$output" "RULE-0 ACK (owner-routed): third_party/hermes-agent/manifest.json" "trusted Rule0-Ack"

repo="$(init_case_repo trusted-scope-limited)"
commit_change "$repo" third_party/other-runtime/manifest.json '{"pinnedCommit":"abc"}' $'update other vendored manifest\n\nRule0-Ack: hermes-agent reviewed'
result="$(capture_guard "$repo" OPENBURNBAR_RULE0_TRUSTED_OWNER_ACK=1)"
status="$(printf '%s\n' "$result" | sed -n '1p')"
output="$(printf '%s\n' "$result" | sed '1d')"
assert_status 1 "$status" "$output" "trusted ack scope remains narrow"
assert_contains "$output" "RULE-0 VIOLATION: third_party/other-runtime/manifest.json" "trusted ack scope remains narrow"

repo="$(init_case_repo trusted-libsignal)"
commit_change "$repo" Vendor/libsignal/LICENSE "AGPL" $'update signal source\n\nRule0-Ack: Vendor/libsignal legal approval'
result="$(capture_guard "$repo" OPENBURNBAR_RULE0_TRUSTED_OWNER_ACK=1)"
status="$(printf '%s\n' "$result" | sed -n '1p')"
output="$(printf '%s\n' "$result" | sed '1d')"
assert_status 0 "$status" "$output" "trusted libsignal ack"
assert_contains "$output" "RULE-0 ACK (owner-routed): Vendor/libsignal/LICENSE" "trusted libsignal ack"

echo "PASS: verify-signal-rule0 self-tests"
