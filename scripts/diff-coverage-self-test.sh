#!/usr/bin/env bash
# Self-test for the diff-coverage gate (scripts/diff-coverage.sh +
# scripts/extract-package-coverage-lines.sh).
#
# Builds a hermetic fixture: a throwaway git repo with a package-partition
# Swift file (OpenBurnBarCore/Sources/…) and an app-partition Swift file
# (AgentLens/…), plus an LCOV trace standing in for `llvm-cov export
# -format=lcov` output. Then asserts the gate's actual contract:
#
#   1. Measured percent: changed-line ∩ per-line evidence yields the exact
#      expected percentage, and the threshold pass/fail flips accordingly.
#   2. Scope partition: app-partition files are out of scope for the
#      packages lane (reported, never silently dropped).
#   3. No evidence ⇒ fail for executable changed lines. Plain Swift
#      declaration-only changes are excluded because they do not emit LLVM line
#      counters.
#   4. cov:ignore without a justification fails the gate outright;
#      `cov:ignore -- <reason>` excludes exactly the annotated lines.
#   5. A lane whose evidence is missing entirely fails closed.
#
# Run directly or via the CI coverage steps (it guards the gate before the
# gate judges the PR). Exits non-zero on the first failed assertion.

set -euo pipefail

scripts_dir="$(cd "$(dirname "$0")" && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-diff-coverage-selftest.XXXXXX")"
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
  # json_get <file> <python-expression over parsed `v`>
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    v = json.load(handle)
print(eval(sys.argv[2], {"v": v}))
PY
}

# --- fixture builders --------------------------------------------------------

write_widget() {
  # $1 = repo dir, $2 = suffix for line 11, $3 = suffix for line 12
  cat > "$1/OpenBurnBarCore/Sources/DemoKit/Widget.swift" <<EOF
public enum Widget {
    public static func base() -> Int {
        return 1
    }
}

public enum WidgetMath {
    public static func add(_ a: Int, _ b: Int) -> Int {
        let sum = a + b
        let doubled = sum * 2
        let halved = doubled / 2$2
        return halved$3
    }
}
EOF
}

make_repo() {
  # $1 = repo dir, $2 = suffix for line 11, $3 = suffix for line 12
  local repo="$1"
  mkdir -p "$repo/OpenBurnBarCore/Sources/DemoKit" "$repo/AgentLens/Services/Demo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email selftest@openburnbar.invalid
  git -C "$repo" config user.name "Diff Coverage Self-Test"

  cat > "$repo/OpenBurnBarCore/Sources/DemoKit/Widget.swift" <<'EOF'
public enum Widget {
    public static func base() -> Int {
        return 1
    }
}
EOF
  cat > "$repo/AgentLens/Services/Demo/Orphan.swift" <<'EOF'
final class Orphan {
}
EOF
  git -C "$repo" add -A
  git -C "$repo" commit -qm base

  write_widget "$repo" "$2" "$3"
  cat > "$repo/AgentLens/Services/Demo/Orphan.swift" <<'EOF'
final class Orphan {
    func grow() -> Int {
        return 2
    }
}
EOF
  git -C "$repo" add -A
  git -C "$repo" commit -qm change
  git -C "$repo" rev-parse HEAD~1
}

write_lcov() {
  # $1 = lcov path, $2 = repo dir. Lines 8-10,13 hit; 11-12 executable, unhit.
  cat > "$1" <<EOF
SF:$2/OpenBurnBarCore/Sources/DemoKit/Widget.swift
DA:2,9
DA:3,9
DA:8,3
DA:9,3
DA:10,3
DA:11,0
DA:12,0
DA:13,3
end_of_record
EOF
}

make_declaration_repo() {
  local repo="$1"
  mkdir -p "$repo/OpenBurnBarCore/Sources/DemoKit"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email selftest@openburnbar.invalid
  git -C "$repo" config user.name "Diff Coverage Self-Test"

  cat > "$repo/OpenBurnBarCore/Sources/DemoKit/Widget.swift" <<'EOF'
public enum Widget {
    public static func base() -> Int {
        return 1
    }
}
EOF
  cat > "$repo/OpenBurnBarCore/Sources/DemoKit/Model.swift" <<'EOF'
public struct Model {
    public var id: String
}
EOF
  git -C "$repo" add -A
  git -C "$repo" commit -qm base

  cat > "$repo/OpenBurnBarCore/Sources/DemoKit/Model.swift" <<'EOF'
public struct Model {
    public var id: String
    public var relayKeyVersion: Int?
    public var supportsSignalEnvelope: Bool?
}
EOF
  git -C "$repo" add -A
  git -C "$repo" commit -qm declaration-change
  git -C "$repo" rev-parse HEAD~1
}

run_gate() {
  # $1 = repo, $2 = base sha, $3 = scope, $4 = threshold, $5 = pkg lines json,
  # $6 = verdict path, $7 = stderr path. Echoes the gate's exit code.
  local rc=0
  OPENBURNBAR_COVERAGE_REPO_ROOT="$1" \
  DIFF_COVERAGE_SCOPE="$3" \
  COVERAGE_THRESHOLD="$4" \
  DIFF_COVERAGE_OUTPUT="$6" \
    "$scripts_dir/diff-coverage.sh" "$2" '' '' "$5" > /dev/null 2> "$7" || rc=$?
  echo "$rc"
}

# --- fixture 1: plain change, lines 11-12 uncovered --------------------------

repo="$tmp_root/repo"
base_sha="$(make_repo "$repo" '' '')"
lcov="$tmp_root/fixture.lcov"
write_lcov "$lcov" "$repo"

pkg_lines="$tmp_root/pkg-lines.json"
OPENBURNBAR_COVERAGE_REPO_ROOT="$repo" \
  "$scripts_dir/extract-package-coverage-lines.sh" "$lcov" > "$pkg_lines"

check "extractor maps a hit line" \
  "True" "$(json_get "$pkg_lines" 'v["files"]["OpenBurnBarCore/Sources/DemoKit/Widget.swift"]["lines"]["8"]')"
check "extractor maps an executable-but-unhit line" \
  "False" "$(json_get "$pkg_lines" 'v["files"]["OpenBurnBarCore/Sources/DemoKit/Widget.swift"]["lines"]["11"]')"
check "extractor omits non-executable lines" \
  "False" "$(json_get "$pkg_lines" '"6" in v["files"]["OpenBurnBarCore/Sources/DemoKit/Widget.swift"]["lines"]')"

# Changed Widget lines 6-14 ∩ evidence = {8,9,10,11,12,13}; 4 of 6 hit.
verdict="$tmp_root/verdict-measured.json"
rc="$(run_gate "$repo" "$base_sha" packages 80 "$pkg_lines" "$verdict" "$tmp_root/err-measured.log")"
check "measured 66.67% fails the 80% threshold" "1" "$rc"
check "measured percent is the exact intersection" \
  "66.67" "$(json_get "$verdict" 'v["diffCoverage"]["percent"]')"
check "per-file method is package line evidence" \
  "line_level(package)" "$(json_get "$verdict" 'v["details"][0]["method"]')"
check "app-partition file is out of scope for the packages lane" \
  "AgentLens/Services/Demo/Orphan.swift" \
  "$(json_get "$verdict" 'v["outOfScope"][0]["file"]')"

verdict="$tmp_root/verdict-pass.json"
rc="$(run_gate "$repo" "$base_sha" packages 60 "$pkg_lines" "$verdict" "$tmp_root/err-pass.log")"
check "same evidence passes a 60% threshold" "0" "$rc"
check "passing verdict is marked passed" \
  "True" "$(json_get "$verdict" 'v["diffCoverage"]["passed"]')"

# scope=all: the app-partition file has no evidence anywhere -> every changed
# line is uncovered, and the verdict says so explicitly.
verdict="$tmp_root/verdict-noevidence.json"
rc="$(run_gate "$repo" "$base_sha" all 80 "$pkg_lines" "$verdict" "$tmp_root/err-noevidence.log")"
check "no-evidence file fails the gate" "1" "$rc"
check "no-evidence file is reported as no_evidence" \
  "no_evidence" \
  "$(json_get "$verdict" '[d for d in v["details"] if d["file"].startswith("AgentLens/")][0]["method"]')"
check "no-evidence file has zero covered lines" \
  "0" "$(json_get "$verdict" '[d for d in v["details"] if d["file"].startswith("AgentLens/")][0]["coveredLines"]')"

# Declaration-only package changes do not emit LLVM line counters. They should
# not become fake uncovered executable lines when the package lane has other
# valid evidence and the changed declaration file has no LCOV source record.
repo_decl="$tmp_root/repo-declaration"
base_decl="$(make_declaration_repo "$repo_decl")"
lcov_decl="$tmp_root/fixture-declaration.lcov"
write_lcov "$lcov_decl" "$repo_decl"
pkg_decl="$tmp_root/pkg-lines-declaration.json"
OPENBURNBAR_COVERAGE_REPO_ROOT="$repo_decl" \
  "$scripts_dir/extract-package-coverage-lines.sh" "$lcov_decl" > "$pkg_decl"

verdict="$tmp_root/verdict-declaration.json"
rc="$(run_gate "$repo_decl" "$base_decl" packages 80 "$pkg_decl" "$verdict" "$tmp_root/err-declaration.log")"
check "declaration-only no-evidence file passes with zero executable changed lines" "0" "$rc"
check "declaration-only verdict has zero changed executable lines" \
  "0" "$(json_get "$verdict" 'v["diffCoverage"]["changedLines"]')"

# Missing lane evidence fails closed (no package lines json, no .build).
rc=0
OPENBURNBAR_COVERAGE_REPO_ROOT="$repo" DIFF_COVERAGE_SCOPE=packages \
  "$scripts_dir/diff-coverage.sh" "$base_sha" > /dev/null 2> "$tmp_root/err-closed.log" || rc=$?
check "packages lane with no evidence fails closed" "1" "$rc"
grep -q "No package coverage data found" "$tmp_root/err-closed.log" \
  && echo "ok   - fail-closed error names the missing evidence" \
  || { echo "FAIL - fail-closed error names the missing evidence" >&2; failures=$((failures + 1)); }

# --- fixture 2: bare cov:ignore (no reason) is a gate failure ----------------

repo_bare="$tmp_root/repo-bare"
base_bare="$(make_repo "$repo_bare" ' // cov:ignore' '')"
lcov_bare="$tmp_root/fixture-bare.lcov"
write_lcov "$lcov_bare" "$repo_bare"
pkg_bare="$tmp_root/pkg-lines-bare.json"
OPENBURNBAR_COVERAGE_REPO_ROOT="$repo_bare" \
  "$scripts_dir/extract-package-coverage-lines.sh" "$lcov_bare" > "$pkg_bare"

rc="$(run_gate "$repo_bare" "$base_bare" packages 60 "$pkg_bare" "$tmp_root/verdict-bare.json" "$tmp_root/err-bare.log")"
check "bare cov:ignore (no reason) fails the gate even above threshold" "1" "$rc"
grep -q "cov:ignore without a justification" "$tmp_root/err-bare.log" \
  && echo "ok   - bare cov:ignore failure names the violation" \
  || { echo "FAIL - bare cov:ignore failure names the violation" >&2; failures=$((failures + 1)); }

# --- fixture 3: cov:ignore -- <reason> excludes exactly those lines ----------

repo_reason="$tmp_root/repo-reason"
base_reason="$(make_repo "$repo_reason" ' // cov:ignore -- fixture: unreachable without hardware' ' // cov:ignore -- fixture: unreachable without hardware')"
lcov_reason="$tmp_root/fixture-reason.lcov"
write_lcov "$lcov_reason" "$repo_reason"
pkg_reason="$tmp_root/pkg-lines-reason.json"
OPENBURNBAR_COVERAGE_REPO_ROOT="$repo_reason" \
  "$scripts_dir/extract-package-coverage-lines.sh" "$lcov_reason" > "$pkg_reason"

verdict="$tmp_root/verdict-reason.json"
rc="$(run_gate "$repo_reason" "$base_reason" packages 80 "$pkg_reason" "$verdict" "$tmp_root/err-reason.log")"
check "justified cov:ignore lines are excluded (remaining lines 100%)" "0" "$rc"
check "justified waiver leaves only measured lines in the percent" \
  "100.0" "$(json_get "$verdict" 'v["diffCoverage"]["percent"]')"

# -----------------------------------------------------------------------------

if [[ "$failures" -gt 0 ]]; then
  echo "diff-coverage self-test: $failures assertion(s) failed" >&2
  exit 1
fi
echo "diff-coverage self-test: all assertions passed"
