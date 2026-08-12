#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
readonly SOURCE_ROOT
readonly CANDIDATE_SHA="1111111111111111111111111111111111111111"
readonly WRONG_SHA="2222222222222222222222222222222222222222"
readonly TAP_SHA="3333333333333333333333333333333333333333"
readonly BASE_SHA="4444444444444444444444444444444444444444"
readonly VERSION="1.2.3"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-homebrew-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local path="$1"
  local expected="$2"
  grep -Fq "$expected" "$path" || fail "$path does not contain: $expected"
}

assert_not_contains() {
  local path="$1"
  local unexpected="$2"
  ! grep -Fq "$unexpected" "$path" || fail "$path unexpectedly contains: $unexpected"
}

new_fixture() {
  local name="$1"
  local fixture="$test_root/$name"

  mkdir -p "$fixture/scripts/lib" "$fixture/homebrew" "$fixture/mock-bin" "$fixture/tap" "$fixture/tmp"
  cp "$SOURCE_ROOT/scripts/update-homebrew.sh" "$fixture/scripts/"
  cp "$SOURCE_ROOT/scripts/lib/exclusive_json.py" "$fixture/scripts/lib/"
  cp "$SOURCE_ROOT/homebrew/burnbar.rb" "$fixture/homebrew/"

  cat >"$fixture/mock-bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"$TEST_COMMAND_LOG"
if [[ "$1 $2" == "release view" ]]; then
  printf '%s\tfalse\n' "${TEST_RELEASE_TAG:-v$TEST_VERSION}"
elif [[ "$1" == "api" && "$2" == *"/git/ref/tags/"* ]]; then
  printf 'commit %s\n' "${TEST_TAG_SHA:-$TEST_CANDIDATE_SHA}"
elif [[ "$1 $2" == "release download" ]]; then
  output_dir=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--dir" ]]; then
      output_dir="$2"
      break
    fi
    shift
  done
  mkdir -p "$output_dir"
  printf 'exact public DMG fixture\n' >"$output_dir/OpenBurnBar-$TEST_VERSION-macOS.dmg"
elif [[ "$1" == "api" && "$2" == *"/commits/"* ]]; then
  printf '%s\n' "$TEST_TAP_SHA"
else
  printf 'unexpected gh invocation: %s\n' "$*" >&2
  exit 97
fi
EOF

  cat >"$fixture/mock-bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$TEST_COMMAND_LOG"
args=" $* "
if [[ "$args" == *" rev-parse --show-toplevel "* ]]; then
  printf '%s\n' "$TEST_REPO_ROOT"
elif [[ "$args" == *" remote get-url origin "* ]]; then
  printf '%s\n' "${TEST_TAP_REMOTE:-https://github.com/Imagine-That-Ai/homebrew-tap.git}"
elif [[ "$args" == *" symbolic-ref --short HEAD "* ]]; then
  printf 'main\n'
elif [[ "$args" == *" status --porcelain "* ]]; then
  :
elif [[ "$args" == *" fetch --quiet origin main "* ]]; then
  :
elif [[ "$args" == *" rev-parse refs/remotes/origin/main "* ]]; then
  printf '%s\n' "$TEST_BASE_SHA"
elif [[ "$args" == *" diff --cached --quiet "* ]]; then
  exit 1
elif [[ "$args" == *" diff --cached --name-only "* ]]; then
  printf 'Casks/openburnbar.rb\n'
elif [[ "$args" == *" commit -m "* ]]; then
  : >"$TEST_GIT_COMMITTED"
elif [[ "$args" == *" rev-parse HEAD "* ]]; then
  if [[ "${1:-}" == "-C" && "${2:-}" == */tap ]]; then
    if [[ -f "$TEST_GIT_COMMITTED" ]]; then
      printf '%s\n' "$TEST_TAP_SHA"
    else
      printf '%s\n' "$TEST_BASE_SHA"
    fi
  else
    printf '%s\n' "$TEST_CANDIDATE_SHA"
  fi
elif [[ "$args" == *" ls-remote --exit-code origin refs/heads/main "* ]]; then
  printf '%s\trefs/heads/main\n' "$TEST_TAP_SHA"
fi
EOF

  cat >"$fixture/mock-bin/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'brew %s\n' "$*" >>"$TEST_COMMAND_LOG"
EOF

  cat >"$fixture/mock-bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${TEST_DIGEST_MODE:-real}" == "zero" ]]; then
  printf '%064d  %s\n' 0 "$1"
elif [[ "${TEST_DIGEST_MODE:-real}" == "malformed" ]]; then
  printf 'not-a-digest  %s\n' "$1"
else
  shasum -a 256 "$1"
fi
EOF

  chmod +x "$fixture/mock-bin/gh" "$fixture/mock-bin/git" "$fixture/mock-bin/brew" "$fixture/mock-bin/sha256sum"
  printf '%s\n' "$fixture"
}

run_tool() {
  local fixture="$1"
  shift

  PATH="$fixture/mock-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  TMPDIR="$fixture/tmp" \
  TEST_COMMAND_LOG="$fixture/commands.log" \
  TEST_REPO_ROOT="$fixture" \
  TEST_TAP_DIR="$fixture/tap" \
  TEST_GIT_COMMITTED="$fixture/git-committed" \
  TEST_CANDIDATE_SHA="$CANDIDATE_SHA" \
  TEST_TAP_SHA="$TAP_SHA" \
  TEST_BASE_SHA="$BASE_SHA" \
  TEST_VERSION="$VERSION" \
  "$fixture/scripts/update-homebrew.sh" "$@"
}

assert_contains "$SOURCE_ROOT/homebrew/burnbar.rb" "Imagine-That-Ai/BurnBar"
assert_contains "$SOURCE_ROOT/homebrew/burnbar.rb" "PENDING_RELEASE_SHA256"
assert_not_contains "$SOURCE_ROOT/homebrew/burnbar.rb" "Ajnunezg/BurnBar"
assert_not_contains "$SOURCE_ROOT/homebrew/burnbar.rb" \
  "0000000000000000000000000000000000000000000000000000000000000000"

fixture="$(new_fixture update-success)"
run_tool "$fixture" update --version "$VERSION" --candidate-sha "$CANDIDATE_SHA"
expected_dmg="$fixture/expected.dmg"
printf 'exact public DMG fixture\n' >"$expected_dmg"
expected_sha="$(shasum -a 256 "$expected_dmg" | awk '{print $1}')"
assert_contains "$fixture/homebrew/burnbar.rb" "version \"$VERSION\""
assert_contains "$fixture/homebrew/burnbar.rb" "sha256 \"$expected_sha\""
assert_contains "$fixture/homebrew/burnbar.rb" "# Source commit: $CANDIDATE_SHA"
assert_contains "$fixture/homebrew/burnbar.rb" "# Release tag: v$VERSION"
assert_not_contains "$fixture/commands.log" "git push"
assert_not_contains "$fixture/commands.log" "brew "

fixture="$(new_fixture candidate-mismatch)"
before="$(shasum -a 256 "$fixture/homebrew/burnbar.rb" | awk '{print $1}')"
if TEST_TAG_SHA="$WRONG_SHA" run_tool "$fixture" update --version "$VERSION" --candidate-sha "$CANDIDATE_SHA"; then
  fail "candidate mismatch unexpectedly succeeded"
fi
after="$(shasum -a 256 "$fixture/homebrew/burnbar.rb" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail "candidate mismatch modified the cask"

fixture="$(new_fixture release-mismatch)"
before="$(shasum -a 256 "$fixture/homebrew/burnbar.rb" | awk '{print $1}')"
if TEST_RELEASE_TAG="v9.9.9" run_tool "$fixture" update --version "$VERSION" --candidate-sha "$CANDIDATE_SHA"; then
  fail "release mismatch unexpectedly succeeded"
fi
after="$(shasum -a 256 "$fixture/homebrew/burnbar.rb" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail "release mismatch modified the cask"

for digest_mode in zero malformed; do
  fixture="$(new_fixture "digest-$digest_mode")"
  before="$(shasum -a 256 "$fixture/homebrew/burnbar.rb" | awk '{print $1}')"
  if TEST_DIGEST_MODE="$digest_mode" run_tool "$fixture" update --version "$VERSION" --candidate-sha "$CANDIDATE_SHA"; then
    fail "$digest_mode digest unexpectedly succeeded"
  fi
  after="$(shasum -a 256 "$fixture/homebrew/burnbar.rb" | awk '{print $1}')"
  [[ "$before" == "$after" ]] || fail "$digest_mode digest modified the cask"
done

fixture="$(new_fixture publish-success)"
run_tool "$fixture" update --version "$VERSION" --candidate-sha "$CANDIDATE_SHA"
: >"$fixture/commands.log"
receipt="$fixture/evidence/homebrew-publication.json"
mkdir -m 700 "$fixture/evidence"
run_tool "$fixture" publish \
  --version "$VERSION" \
  --candidate-sha "$CANDIDATE_SHA" \
  --tap-dir "$fixture/tap" \
  --receipt "$receipt"
assert_contains "$fixture/commands.log" "brew style --cask"
assert_contains "$fixture/commands.log" "brew audit --cask --strict"
assert_contains "$fixture/commands.log" " push origin HEAD:refs/heads/main"
assert_contains "$receipt" "\"sourceCommit\": \"$CANDIDATE_SHA\""
assert_contains "$receipt" "\"tapCommit\": \"$TAP_SHA\""
assert_contains "$receipt" "\"releaseAssetSha256\": \"$expected_sha\""
assert_contains "$fixture/tap/Casks/openburnbar.rb" "sha256 \"$expected_sha\""
receipt_mode="$(stat -f '%Lp' "$receipt" 2>/dev/null || stat -c '%a' "$receipt")"
[[ "$receipt_mode" == "600" ]] || fail "publication receipt mode is $receipt_mode, expected 600"

fixture="$(new_fixture wrong-tap)"
run_tool "$fixture" update --version "$VERSION" --candidate-sha "$CANDIDATE_SHA"
: >"$fixture/commands.log"
mkdir -m 700 "$fixture/evidence"
if TEST_TAP_REMOTE="https://github.com/example/homebrew-tap.git" run_tool "$fixture" publish \
  --version "$VERSION" \
  --candidate-sha "$CANDIDATE_SHA" \
  --tap-dir "$fixture/tap" \
  --receipt "$fixture/evidence/receipt.json"; then
  fail "wrong tap origin unexpectedly succeeded"
fi
assert_not_contains "$fixture/commands.log" "git -C $fixture/tap push"

for receipt_case in existing symlink unsafe-parent; do
  fixture="$(new_fixture "receipt-$receipt_case")"
  run_tool "$fixture" update --version "$VERSION" --candidate-sha "$CANDIDATE_SHA"
  : >"$fixture/commands.log"
  mkdir -m 700 "$fixture/evidence"
  receipt="$fixture/evidence/receipt.json"
  case "$receipt_case" in
    existing)
      printf 'preserve me\n' >"$receipt"
      ;;
    symlink)
      printf 'preserve target\n' >"$fixture/receipt-target"
      ln -s "$fixture/receipt-target" "$receipt"
      ;;
    unsafe-parent)
      chmod 777 "$fixture/evidence"
      ;;
  esac

  if run_tool "$fixture" publish \
    --version "$VERSION" \
    --candidate-sha "$CANDIDATE_SHA" \
    --tap-dir "$fixture/tap" \
    --receipt "$receipt"; then
    fail "$receipt_case receipt unexpectedly succeeded"
  fi
  assert_not_contains "$fixture/commands.log" " push origin "
  if [[ "$receipt_case" == "existing" ]]; then
    assert_contains "$receipt" "preserve me"
  elif [[ "$receipt_case" == "symlink" ]]; then
    assert_contains "$fixture/receipt-target" "preserve target"
  fi
done

printf 'PASS: update-homebrew candidate binding, checksum rejection, and publication isolation\n'
