#!/usr/bin/env bash
# Self-test for scripts/ci/select-pr-app-tests.sh (wave 3.8).
#
# Builds a fixture git repo with a mini AgentLens tree, then asserts the
# selector maps changed files to OpenBurnBarTests filters: smoke always,
# impacted classes appended, fail-closed on unresolvable diffs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SELECTOR="$ROOT/scripts/ci/select-pr-app-tests.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/repo"
mkdir -p "$FIX/scripts/lib" "$FIX/AgentLensTests/Active" "$FIX/AgentLensTests/Quarantine" "$FIX/AgentLens/Features" "$FIX/OpenBurnBarMobile" "$FIX/OpenBurnBarCore/Sources"
cp "$ROOT/scripts/lib/openburnbar-release-app-test-filters.sh" "$FIX/scripts/lib/"

# shellcheck source=scripts/lib/openburnbar-release-app-test-filters.sh
source "$ROOT/scripts/lib/openburnbar-release-app-test-filters.sh"
SMOKE_JOINED="$(openburnbar_release_app_test_filters_env)"
SMOKE_COUNT="${#OPENBURNBAR_RELEASE_APP_TEST_FILTERS[@]}"

git -C "$FIX" init -q -b main .
git -C "$FIX" config user.email test@example.test
git -C "$FIX" config user.name "selector-test"
# The filters lib is infrastructure, not a test input: commit it at BASE so
# every case branch (including smoke-only, cut from BASE) can source it —
# mirroring the real repo, where the lib exists at all refs.
git -C "$FIX" add -A
git -C "$FIX" commit -q -m fixture-base
BASE="$(git -C "$FIX" rev-parse HEAD)"

write() {
    mkdir -p "$FIX/$(dirname "$1")"
    cat > "$FIX/$1"
}

commit_changes() {
    git -C "$FIX" add -A
    git -C "$FIX" commit -q -m "case $1"
    git -C "$FIX" rev-parse HEAD
}

run_selector() {
    SELECT_PR_APP_TESTS_REPO_ROOT="$FIX" bash "$SELECTOR" "$BASE" "$1" 2>"$TMP/stderr.txt"
}

assert_contains() {
    if ! grep -Fq "$2" <<<"$1"; then
        echo "FAIL: $3 — missing [$2] in [$1]" >&2
        exit 1
    fi
}

assert_not_contains() {
    if grep -Fq "$2" <<<"$1"; then
        echo "FAIL: $3 — unexpected [$2] in [$1]" >&2
        exit 1
    fi
}

assert_smoke_prefix() {
    local prefix="${1:0:${#SMOKE_JOINED}}"
    if [[ "$prefix" != "$SMOKE_JOINED" ]]; then
        echo "FAIL: $2 — output does not start with the smoke catalog" >&2
        exit 1
    fi
}

# Case 1: changed app test file maps to its declared class.
write AgentLensTests/Active/WidgetTests.swift <<'EOF'
import XCTest
final class WidgetTests: XCTestCase {
    func testWidget() {}
}
EOF
HEAD1="$(commit_changes 1)"
OUT1="$(run_selector "$HEAD1")"
assert_smoke_prefix "$OUT1" "case 1"
assert_contains "$OUT1" "OpenBurnBarTests/WidgetTests" "case 1"

# Case 2: changed source maps to stem Tests + MattersTests when present.
write AgentLens/Features/Gadget.swift <<'EOF'
public struct Gadget {}
EOF
write AgentLensTests/Active/GadgetTests.swift <<'EOF'
import XCTest
final class GadgetTests: XCTestCase {}
EOF
write AgentLensTests/Active/GadgetMattersTests.swift <<'EOF'
import XCTest
final class GadgetMattersTests: XCTestCase {}
EOF
HEAD2="$(commit_changes 2)"
OUT2="$(run_selector "$HEAD2")"
assert_smoke_prefix "$OUT2" "case 2"
assert_contains "$OUT2" "OpenBurnBarTests/GadgetTests" "case 2"
assert_contains "$OUT2" "OpenBurnBarTests/GadgetMattersTests" "case 2"
# Case 1's WidgetTests.swift is also in this cumulative diff: still mapped.
assert_contains "$OUT2" "OpenBurnBarTests/WidgetTests" "case 2 cumulative"

# Case 3: extension source Foo+Bar.swift maps via the Foo base.
write AgentLens/Features/Widget+Preview.swift <<'EOF'
public struct WidgetPreview {}
EOF
HEAD3="$(commit_changes 3)"
OUT3="$(run_selector "$HEAD3")"
assert_contains "$OUT3" "OpenBurnBarTests/WidgetTests" "case 3"

# Case 4: Core source maps the same way.
write OpenBurnBarCore/Sources/Gadget.swift <<'EOF'
public struct CoreGadget {}
EOF
HEAD4="$(commit_changes 4)"
OUT4="$(run_selector "$HEAD4")"
assert_contains "$OUT4" "OpenBurnBarTests/GadgetTests" "case 4"

# Case 5: multi-class test file maps every class.
write AgentLensTests/Active/MultiTests.swift <<'EOF'
import XCTest
final class MultiTests: XCTestCase {}
final class MultiHelperTests: XCTestCase {}
EOF
HEAD5="$(commit_changes 5)"
OUT5="$(run_selector "$HEAD5")"
assert_contains "$OUT5" "OpenBurnBarTests/MultiTests" "case 5"
assert_contains "$OUT5" "OpenBurnBarTests/MultiHelperTests" "case 5"

# Case 6: smoke-only paths (mobile, quarantine, lonely source, docs).
git -C "$FIX" checkout -q -b smoke-only "$BASE"
write OpenBurnBarMobile/Foo.swift <<'EOF'
public struct Foo {}
EOF
write AgentLensTests/Quarantine/QTests.swift <<'EOF'
import XCTest
final class QTests: XCTestCase {}
EOF
write AgentLens/Features/Lonely.swift <<'EOF'
public struct Lonely {}
EOF
write docs/notes.md <<'EOF'
hello
EOF
HEAD6="$(commit_changes 6)"
OUT6="$(run_selector "$HEAD6")"
assert_smoke_prefix "$OUT6" "case 6"
if [[ "$OUT6" != "$SMOKE_JOINED" ]]; then
    echo "FAIL: case 6 — expected exactly the smoke catalog, got [$OUT6]" >&2
    exit 1
fi
git -C "$FIX" checkout -q main

# Case 7: GITHUB_OUTPUT carries the filters line.
GITHUB_OUTPUT="$TMP/ghout.txt" SELECT_PR_APP_TESTS_REPO_ROOT="$FIX" \
    bash "$SELECTOR" "$BASE" "$HEAD1" >/dev/null 2>&1
assert_contains "$(cat "$TMP/ghout.txt")" "filters=" "case 7"
assert_contains "$(cat "$TMP/ghout.txt")" "OpenBurnBarTests/WidgetTests" "case 7"

# Case 8: fail closed — empty diff and bad SHAs exit nonzero.
if SELECT_PR_APP_TESTS_REPO_ROOT="$FIX" bash "$SELECTOR" "$BASE" "$BASE" >/dev/null 2>&1; then
    echo "FAIL: case 8 — empty diff must exit nonzero" >&2
    exit 1
fi
if SELECT_PR_APP_TESTS_REPO_ROOT="$FIX" bash "$SELECTOR" deadbee deadbeef >/dev/null 2>&1; then
    echo "FAIL: case 8 — bad SHAs must exit nonzero" >&2
    exit 1
fi

echo "select-pr-app-tests self-tests passed ($SMOKE_COUNT smoke filters)."
