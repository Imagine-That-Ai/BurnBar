#!/usr/bin/env bash
# Hermetic contract tests for the Android diff-coverage gate.

set -euo pipefail

scripts_dir="$(cd "$(dirname "$0")" && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-android-diff-coverage.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

failures=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "ok   - $label"
  else
    echo "FAIL - $label (expected: $expected, actual: $actual)" >&2
    failures=$((failures + 1))
  fi
}

json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
print(eval(sys.argv[2], {"v": value}))
PY
}

new_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email selftest@openburnbar.invalid
  git -C "$repo" config user.name "Android Diff Coverage Self-Test"
  printf 'fixture\n' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
}

add_kotlin() {
  local repo="$1" package_path="$2" class_name="$3" value="$4"
  local dir="$repo/android/app/src/main/java/$package_path"
  mkdir -p "$dir"
  local package_name="${package_path//\//.}"
  printf 'package %s\nfun %sValue(): Int = %s\n' \
    "$package_name" "$class_name" "$value" > "$dir/$class_name.kt"
}

commit_change() {
  git -C "$1" add -A
  git -C "$1" commit -qm change
  git -C "$1" rev-parse HEAD~1
}

write_report() {
  local path="$1" body="$2"
  printf '%s\n' "<?xml version=\"1.0\" encoding=\"UTF-8\"?><report name=\"fixture\">$body</report>" > "$path"
}

run_gate() {
  local repo="$1" base="$2" report="$3" out="$4" err="$5" rc=0
  OPENBURNBAR_COVERAGE_REPO_ROOT="$repo" \
  ANDROID_JACOCO_XML="$report" \
  COVERAGE_THRESHOLD=80 \
    "$scripts_dir/diff-coverage-android.sh" "$base" > "$out" 2> "$err" || rc=$?
  echo "$rc"
}

# Missing JaCoCo is a hard failure for production changes.
repo="$tmp_root/missing-report"
new_repo "$repo"
add_kotlin "$repo" sample/missing Missing 1
base="$(commit_change "$repo")"
rc="$(run_gate "$repo" "$base" "$repo/does-not-exist.xml" "$tmp_root/missing.json" "$tmp_root/missing.err")"
check "missing JaCoCo report fails closed" "1" "$rc"
check "missing report error names JaCoCo" \
  "True" "$(grep -q 'JaCoCo report not found' "$tmp_root/missing.err" && echo True || echo False)"

# Generated UniFFI bindings are verified by binding drift/ABI gates, not app-module JaCoCo.
repo="$tmp_root/generated-uniffi"
new_repo "$repo"
mkdir -p "$repo/android/openburnbar-domain-core/src/main/java/uniffi/generated"
printf 'package uniffi.generated\nfun generatedValue(): Int = 1\n' \
  > "$repo/android/openburnbar-domain-core/src/main/java/uniffi/generated/Bindings.kt"
base="$(commit_change "$repo")"
rc="$(run_gate "$repo" "$base" "$repo/does-not-exist.xml" "$tmp_root/generated.json" "$tmp_root/generated.err")"
check "generated UniFFI Kotlin does not require app JaCoCo" "0" "$rc"
check "generated-only change reports no production Kotlin" \
  "no_production_kotlin" "$(json_get "$tmp_root/generated.json" 'v["diffCoverage"]["method"]')"

# A similarly named directory in any other module is handwritten production code.
repo="$tmp_root/handwritten-uniffi"
new_repo "$repo"
add_kotlin "$repo" uniffi/handwritten Handwritten 1
base="$(commit_change "$repo")"
report="$repo/jacoco.xml"
write_report "$report" '<package name="sample/other"><sourcefile name="Other.kt"><line nr="2" mi="0" ci="1"/></sourcefile></package>'
rc="$(run_gate "$repo" "$base" "$report" "$tmp_root/handwritten.json" "$tmp_root/handwritten.err")"
check "handwritten UniFFI namespace remains coverage-gated" "1" "$rc"
check "handwritten UniFFI namespace requires its own evidence" \
  "no_jacoco_source" "$(json_get "$tmp_root/handwritten.json" 'v["details"][0]["method"]')"

# One executable changed line is gated; there is no minimum-line exemption.
repo="$tmp_root/one-line"
new_repo "$repo"
add_kotlin "$repo" sample/one One 1
base="$(commit_change "$repo")"
report="$repo/jacoco.xml"
write_report "$report" '<package name="sample/one"><sourcefile name="One.kt"><line nr="2" mi="1" ci="0"/></sourcefile></package>'
rc="$(run_gate "$repo" "$base" "$report" "$tmp_root/one-line.json" "$tmp_root/one-line.err")"
check "single uncovered executable line fails" "1" "$rc"
check "single executable line is in the denominator" \
  "1" "$(json_get "$tmp_root/one-line.json" 'v["diffCoverage"]["changedLines"]')"

# Same basenames in different packages must retain independent coverage.
repo="$tmp_root/collision"
new_repo "$repo"
add_kotlin "$repo" sample/alpha Foo 1
add_kotlin "$repo" sample/beta Foo 2
base="$(commit_change "$repo")"
report="$repo/jacoco.xml"
write_report "$report" '<package name="sample/beta"><sourcefile name="Foo.kt"><line nr="2" mi="1" ci="0"/></sourcefile></package><package name="sample/alpha"><sourcefile name="Foo.kt"><line nr="2" mi="0" ci="1"/></sourcefile></package>'
rc="$(run_gate "$repo" "$base" "$report" "$tmp_root/collision.json" "$tmp_root/collision.err")"
check "package-qualified duplicate basenames do not borrow coverage" "1" "$rc"
check "duplicate basenames produce the true 50 percent" \
  "50.0" "$(json_get "$tmp_root/collision.json" 'v["diffCoverage"]["percent"]')"
check "both package-qualified files remain distinct" \
  "['sample/alpha/Foo.kt', 'sample/beta/Foo.kt']" \
  "$(json_get "$tmp_root/collision.json" 'sorted(d["sourceIdentity"] for d in v["details"])')"

# A valid report that does not contain the changed source is still no evidence.
repo="$tmp_root/no-source"
new_repo "$repo"
add_kotlin "$repo" sample/absent Absent 1
base="$(commit_change "$repo")"
report="$repo/jacoco.xml"
write_report "$report" '<package name="sample/other"><sourcefile name="Other.kt"><line nr="2" mi="0" ci="1"/></sourcefile></package>'
rc="$(run_gate "$repo" "$base" "$report" "$tmp_root/no-source.json" "$tmp_root/no-source.err")"
check "zero measured production evidence fails" "1" "$rc"
check "missing source is explicit in the verdict" \
  "no_jacoco_source" "$(json_get "$tmp_root/no-source.json" 'v["details"][0]["method"]')"

# Covered per-line evidence passes.
repo="$tmp_root/pass"
new_repo "$repo"
add_kotlin "$repo" sample/pass Covered 1
base="$(commit_change "$repo")"
report="$repo/jacoco.xml"
write_report "$report" '<package name="sample/pass"><sourcefile name="Covered.kt"><line nr="2" mi="0" ci="1"/></sourcefile></package>'
rc="$(run_gate "$repo" "$base" "$report" "$tmp_root/pass.json" "$tmp_root/pass.err")"
check "covered per-line evidence passes" "0" "$rc"
check "passing verdict is 100 percent" \
  "100.0" "$(json_get "$tmp_root/pass.json" 'v["diffCoverage"]["percent"]')"

if [[ "$failures" -gt 0 ]]; then
  echo "Android diff-coverage self-test: $failures assertion(s) failed" >&2
  exit 1
fi
echo "Android diff-coverage self-test: all assertions passed"
