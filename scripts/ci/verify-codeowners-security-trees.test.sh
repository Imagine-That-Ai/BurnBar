#!/usr/bin/env bash
# Regression test for scripts/ci/verify-codeowners-security-trees.sh.
#
# Verifies that:
#   1. The existing verifier PASSES against the current CODEOWNERS file.
#   2. The verifier catches a missing .gitleaks.toml entry (fail-closed).
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$SOURCE_ROOT/scripts/ci/verify-codeowners-security-trees.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

passed=0
failed=0

expect_pass() {
  local name="$1"
  shift
  local log="$TMP_ROOT/${name//[^A-Za-z0-9_.-]/_}.log"
  if "$@" >"$log" 2>&1; then
    echo "  ok   $name"
    passed=$((passed + 1))
  else
    echo "  FAIL $name (expected pass)" >&2
    cat "$log" >&2
    failed=$((failed + 1))
  fi
}

expect_fail() {
  local name="$1"
  shift
  local log="$TMP_ROOT/${name//[^A-Za-z0-9_.-]/_}.log"
  if "$@" >"$log" 2>&1; then
    echo "  FAIL $name (expected failure)" >&2
    cat "$log" >&2
    failed=$((failed + 1))
  else
    echo "  ok   $name"
    passed=$((passed + 1))
  fi
}

echo "Self-test: verify-codeowners-security-trees.sh"
echo

# ---------------------------------------------------------------------------
# Test 1: verifier passes on the current (correct) CODEOWNERS file.
# ---------------------------------------------------------------------------
# The verifier script hard-codes its own path references and cd's to repo root.
# We run it directly from the real repo.
expect_pass "current CODEOWNERS passes verifier" bash "$VERIFY"

# ---------------------------------------------------------------------------
# Test 2: verifier catches a missing .gitleaks.toml entry.
#
# We create a temporary CODEOWNERS with the .gitleaks.toml line removed, then
# run the verifier with a modified CODEOWNERS path via a wrapper script.
# The verifier script reads ".github/CODEOWNERS" from the repo root, so we
# need a temp repo root with the mutated CODEOWNERS. We copy just the
# CODEOWNERS file and point the verifier at it by creating a temp repo tree.
# ---------------------------------------------------------------------------
MUTATED_REPO="$TMP_ROOT/mutated-repo"
mkdir -p "$MUTATED_REPO/.github"
mkdir -p "$MUTATED_REPO/scripts/ci"

# Copy the real CODEOWNERS and remove the .gitleaks.toml line.
sed '/^\.gitleaks\.toml /d' "$SOURCE_ROOT/.github/CODEOWNERS" \
  > "$MUTATED_REPO/.github/CODEOWNERS"

# Copy the verifier script itself (it is self-contained Python embedded in
# bash, reading from the current working directory).
cp "$VERIFY" "$MUTATED_REPO/scripts/ci/verify-codeowners-security-trees.sh"

# Run the verifier from the mutated repo root so it reads the mutated
# CODEOWNERS. We expect it to FAIL because .gitleaks.toml is missing.
expect_fail "missing .gitleaks.toml entry caught by verifier" \
  bash -c "cd '$MUTATED_REPO' && bash scripts/ci/verify-codeowners-security-trees.sh"

# ---------------------------------------------------------------------------
# Test 3: verifier catches a missing .gitleaksignore entry.
# ---------------------------------------------------------------------------
MUTATED_REPO2="$TMP_ROOT/mutated-repo2"
mkdir -p "$MUTATED_REPO2/.github"
mkdir -p "$MUTATED_REPO2/scripts/ci"

sed '/^\.gitleaksignore /d' "$SOURCE_ROOT/.github/CODEOWNERS" \
  > "$MUTATED_REPO2/.github/CODEOWNERS"
cp "$VERIFY" "$MUTATED_REPO2/scripts/ci/verify-codeowners-security-trees.sh"

expect_fail "missing .gitleaksignore entry caught by verifier" \
  bash -c "cd '$MUTATED_REPO2' && bash scripts/ci/verify-codeowners-security-trees.sh"

echo
if [ "$failed" -eq 0 ]; then
  echo "PASS: ${passed} passed, ${failed} failed"
  exit 0
else
  echo "FAIL: ${passed} passed, ${failed} failed"
  exit 1
fi