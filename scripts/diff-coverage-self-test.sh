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
#   2. Scope partition: app and Linux-only package files are out of scope for
#      the macOS packages lane (reported, never silently dropped); the Linux
#      lane owns exactly its reviewed path-prefix policy, including near-miss
#      portable names remaining macOS-owned.
#   3. No evidence ⇒ fail for executable changed lines. Plain Swift
#      declaration-only changes and conditional-compilation directives are
#      excluded because they do not emit LLVM line counters.
#   4. cov:ignore without a justification fails the gate outright;
#      `cov:ignore -- <reason>` and justified ignore blocks exclude exactly
#      the annotated lines.
#   5. A lane whose evidence is missing entirely fails closed.
#   6. Pure-move safe-harbor (R-GH0): a byte-identical / reindented relocation is
#      credited refactor:pure-move and excluded from the denominator, so a
#      god-file split passes with zero new tests; a move+edit gates only the
#      genuinely edited line; and a forged "move" that flips a literal is NOT
#      exempted and still fails. Block matching (not global line text) makes an
#      in-place edit whose new text coincidentally equals one line of an
#      unrelated deleted block stay GATED; strip-only normalization keeps an
#      internal-whitespace literal edit gated; and pureMove.gatedLines always
#      equals diffCoverage.changedLines (never inflated by structural lines).
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

run_app_gate() {
  # $1 = repo, $2 = base sha, $3 = threshold, $4 = summary json,
  # $5 = app lines json, $6 = verdict path, $7 = stderr path.
  local rc=0
  OPENBURNBAR_COVERAGE_REPO_ROOT="$1" \
  DIFF_COVERAGE_SCOPE=app \
  COVERAGE_THRESHOLD="$3" \
  DIFF_COVERAGE_OUTPUT="$6" \
    "$scripts_dir/diff-coverage.sh" "$2" "$4" "$5" > /dev/null 2> "$7" || rc=$?
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

# --- fixture 4: cov:ignore-start -- <reason> excludes a block ---------------

repo_block="$tmp_root/repo-block"
base_block="$(make_repo "$repo_block" ' // cov:ignore-start -- fixture: live integration block' ' // cov:ignore-end')"
lcov_block="$tmp_root/fixture-block.lcov"
write_lcov "$lcov_block" "$repo_block"
pkg_block="$tmp_root/pkg-lines-block.json"
OPENBURNBAR_COVERAGE_REPO_ROOT="$repo_block" \
  "$scripts_dir/extract-package-coverage-lines.sh" "$lcov_block" > "$pkg_block"

verdict="$tmp_root/verdict-block.json"
rc="$(run_gate "$repo_block" "$base_block" packages 80 "$pkg_block" "$verdict" "$tmp_root/err-block.log")"
check "justified cov:ignore block excludes the enclosed changed lines" "0" "$rc"
check "justified block waiver leaves only measured lines in the percent" \
  "100.0" "$(json_get "$verdict" 'v["diffCoverage"]["percent"]')"

# --- fixtures 5-7: pure-move safe-harbor (R-GH0) -----------------------------
#
# Splitting a god-file or relocating a block is not new behavior, so a
# byte-identical (or whitespace-normalized) relocation must not be charged as
# brand-new uncovered lines — the pressure that makes refactors game the gate.
# Each fixture moves a WidgetMath block OUT of Big.swift and INTO the
# pre-existing Helpers.swift. git renders a block move into an existing file as
# delete+add (never a whole-file rename), so the content classifier in
# diff-coverage.sh — not git's own rename detection — is what grants the
# exemption. The exemption is earned by the detector, never by an annotation.

make_move_repo() {
  # $1 = repo dir, $2 = Helpers.swift destination (the relocated block, which
  # may carry an edit/forgery). Echoes the base sha.
  local repo="$1" dest="$2"
  mkdir -p "$repo/OpenBurnBarCore/Sources/DemoKit"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email selftest@openburnbar.invalid
  git -C "$repo" config user.name "Diff Coverage Self-Test"

  cat > "$repo/OpenBurnBarCore/Sources/DemoKit/Big.swift" <<'EOF'
public enum Widget {
    public static func base() -> Int {
        return 1
    }
}

public enum WidgetMath {
    public static func add(_ a: Int, _ b: Int) -> Int {
        let sum = a + b
        return sum
    }
}
EOF
  cat > "$repo/OpenBurnBarCore/Sources/DemoKit/Helpers.swift" <<'EOF'
public enum Helpers {
    public static func noop() -> Int {
        return 0
    }
}
EOF
  git -C "$repo" add -A
  git -C "$repo" commit -qm base

  # Big.swift keeps only Widget; the WidgetMath block relocates into Helpers.
  cat > "$repo/OpenBurnBarCore/Sources/DemoKit/Big.swift" <<'EOF'
public enum Widget {
    public static func base() -> Int {
        return 1
    }
}
EOF
  printf '%s\n' "$dest" > "$repo/OpenBurnBarCore/Sources/DemoKit/Helpers.swift"
  git -C "$repo" add -A
  git -C "$repo" commit -qm move
  git -C "$repo" rev-parse HEAD~1
}

write_swift_lcov() {
  # $1 = lcov path, $2 = repo, $3 = repo-relative Swift file, $4... = DA records
  local path="$1" repo="$2" rel="$3"; shift 3
  {
    echo "SF:$repo/$rel"
    printf '%s\n' "$@"
    echo "end_of_record"
  } > "$path"
}

extract_pkg() {
  # $1 = lcov path, $2 = repo, $3 = out json path
  OPENBURNBAR_COVERAGE_REPO_ROOT="$2" \
    "$scripts_dir/extract-package-coverage-lines.sh" "$1" > "$3"
}

move_pure="$(cat <<'EOF'
public enum Helpers {
    public static func noop() -> Int {
        return 0
    }
}

public enum WidgetMath {
    public static func add(_ a: Int, _ b: Int) -> Int {
        let sum = a + b
        return sum
    }
}
EOF
)"
move_edit="$(cat <<'EOF'
public enum Helpers {
    public static func noop() -> Int {
        return 0
    }
}

public enum WidgetMath {
    public static func add(_ a: Int, _ b: Int) -> Int {
        let sum = a + b
        return sum + 1
    }
}
EOF
)"
move_forge="$(cat <<'EOF'
public enum Helpers {
    public static func noop() -> Int {
        return 0
    }
}

public enum WidgetMath {
    public static func add(_ a: Int, _ b: Int) -> Int {
        let sum = a * b
        return sum
    }
}
EOF
)"

# (a) Pure split: every relocated line is byte-identical to a removed line, so
# the whole block is credited refactor:pure-move. Evidence covers ONLY the
# retained Widget — the relocated block ships with zero new tests, and the gate
# still passes because a move is not new code.
repo_pure="$tmp_root/repo-move-pure"
base_pure="$(make_move_repo "$repo_pure" "$move_pure")"
lcov_pure="$tmp_root/fixture-move-pure.lcov"
write_swift_lcov "$lcov_pure" "$repo_pure" "OpenBurnBarCore/Sources/DemoKit/Big.swift" "DA:2,3" "DA:3,3"
pkg_pure="$tmp_root/pkg-move-pure.json"
extract_pkg "$lcov_pure" "$repo_pure" "$pkg_pure"
verdict="$tmp_root/verdict-move-pure.json"
rc="$(run_gate "$repo_pure" "$base_pure" packages 80 "$pkg_pure" "$verdict" "$tmp_root/err-move-pure.log")"
check "pure move passes the 80% gate with zero new tests" "0" "$rc"
check "pure move leaves nothing in the coverage denominator" \
  "0" "$(json_get "$verdict" 'v["diffCoverage"]["changedLines"]')"
check "pure move credits every relocated line as refactor:pure-move" \
  "6" "$(json_get "$verdict" 'v["pureMove"]["movedLines"]')"
check "pure move gates zero files" \
  "0" "$(json_get "$verdict" 'v["diffCoverage"]["changedFiles"]')"

# (b) Move + edit: the relocated lines are credited, but the one genuinely
# edited line (`return sum + 1`) matches no removed line and stays gated. With
# that single line covered, the gate passes on the strength of the edit alone.
repo_edit="$tmp_root/repo-move-edit"
base_edit="$(make_move_repo "$repo_edit" "$move_edit")"
lcov_edit="$tmp_root/fixture-move-edit.lcov"
write_swift_lcov "$lcov_edit" "$repo_edit" "OpenBurnBarCore/Sources/DemoKit/Helpers.swift" "DA:10,1"
pkg_edit="$tmp_root/pkg-move-edit.json"
extract_pkg "$lcov_edit" "$repo_edit" "$pkg_edit"
verdict="$tmp_root/verdict-move-edit.json"
rc="$(run_gate "$repo_edit" "$base_edit" packages 80 "$pkg_edit" "$verdict" "$tmp_root/err-move-edit.log")"
check "move+edit passes when only the edited line is covered" "0" "$rc"
check "move+edit gates exactly the one edited line" \
  "1" "$(json_get "$verdict" 'v["diffCoverage"]["changedLines"]')"
check "move+edit still credits the relocated lines" \
  "5" "$(json_get "$verdict" 'v["pureMove"]["movedLines"]')"
check "move+edit measures 100% on the single gated line" \
  "100.0" "$(json_get "$verdict" 'v["diffCoverage"]["percent"]')"

# (c) Forged move: the block is relocated but a literal is flipped
# (`a + b` -> `a * b`). The forged line matches no removed line, so it is NOT
# exempted; left uncovered it drags the gate below threshold and fails. This is
# the safe-harbor's teeth: a relocation cannot smuggle a logic change past the
# gate.
repo_forge="$tmp_root/repo-move-forge"
base_forge="$(make_move_repo "$repo_forge" "$move_forge")"
lcov_forge="$tmp_root/fixture-move-forge.lcov"
write_swift_lcov "$lcov_forge" "$repo_forge" "OpenBurnBarCore/Sources/DemoKit/Helpers.swift" "DA:9,0"
pkg_forge="$tmp_root/pkg-move-forge.json"
extract_pkg "$lcov_forge" "$repo_forge" "$pkg_forge"
verdict="$tmp_root/verdict-move-forge.json"
rc="$(run_gate "$repo_forge" "$base_forge" packages 80 "$pkg_forge" "$verdict" "$tmp_root/err-move-forge.log")"
check "forged move (changed literal) is NOT exempted and fails the gate" "1" "$rc"
check "forged move still gates exactly the tampered line" \
  "1" "$(json_get "$verdict" 'v["diffCoverage"]["changedLines"]')"
check "forged move credits only the genuinely relocated lines" \
  "5" "$(json_get "$verdict" 'v["pureMove"]["movedLines"]')"
check "forged move leaves the tampered line uncovered" \
  "0" "$(json_get "$verdict" '[d for d in v["details"] if d["file"].endswith("Helpers.swift")][0]["coveredLines"]')"

# --- fixture 8: coincidence attack — an in-place edit whose new text equals one
# line of an UNRELATED deleted block must NOT be exempted as a move (R-GH0, P1).
# Calc.swift changes `return 1` -> `return 0` (a real edit) while an unrelated
# Helper.swift that also contains `return 0` is deleted. Global line-text
# matching credited the edited `return 0` as a "move" because that text appeared
# somewhere in the removed set; block matching gates it because a length-1 added
# run matches no contiguous removed run of >= 2 lines. (Separate files so git
# cannot align the edit against the deleted line as unchanged context.)
repo_coin="$tmp_root/repo-coincidence"
mkdir -p "$repo_coin/OpenBurnBarCore/Sources/DemoKit"
git -C "$repo_coin" init -q -b main
git -C "$repo_coin" config user.email selftest@openburnbar.invalid
git -C "$repo_coin" config user.name "Diff Coverage Self-Test"
cat > "$repo_coin/OpenBurnBarCore/Sources/DemoKit/Calc.swift" <<'EOF'
public enum Calc {
    public static func value() -> Int {
        return 1
    }
}
EOF
cat > "$repo_coin/OpenBurnBarCore/Sources/DemoKit/Helper.swift" <<'EOF'
public enum Helper {
    public static func fallback() -> Int {
        return 0
    }
}
EOF
git -C "$repo_coin" add -A
git -C "$repo_coin" commit -qm base
base_coin="$(git -C "$repo_coin" rev-parse HEAD)"
cat > "$repo_coin/OpenBurnBarCore/Sources/DemoKit/Calc.swift" <<'EOF'
public enum Calc {
    public static func value() -> Int {
        return 0
    }
}
EOF
git -C "$repo_coin" rm -q OpenBurnBarCore/Sources/DemoKit/Helper.swift
git -C "$repo_coin" add -A
git -C "$repo_coin" commit -qm coincidence-attack
lcov_coin="$tmp_root/fixture-coincidence.lcov"
write_swift_lcov "$lcov_coin" "$repo_coin" "OpenBurnBarCore/Sources/DemoKit/Calc.swift" "DA:2,3" "DA:3,0"
pkg_coin="$tmp_root/pkg-coincidence.json"
extract_pkg "$lcov_coin" "$repo_coin" "$pkg_coin"
verdict="$tmp_root/verdict-coincidence.json"
rc="$(run_gate "$repo_coin" "$base_coin" packages 80 "$pkg_coin" "$verdict" "$tmp_root/err-coincidence.log")"
check "coincidence edit (return 1 -> return 0) is NOT exempted and fails the gate" "1" "$rc"
check "coincidence edit is gated, never credited as a pure move" \
  "0" "$(json_get "$verdict" 'v["pureMove"]["movedLines"]')"
check "coincidence edit stays in the coverage denominator" \
  "1" "$(json_get "$verdict" 'v["diffCoverage"]["changedLines"]')"

# --- fixture 9: an internal-whitespace edit inside a moved block stays gated
# (R-GH0, P1/P3). The Labeler block relocates Big.swift -> Helpers.swift, but the
# string literal's INTERNAL spacing changes (`"a b"` -> `"a  b"`). Normalizing
# only leading/trailing indentation (text.strip) preserves that internal byte, so
# the edited line matches no removed line and is gated, while the 4 untouched
# block lines are still credited as the move.
repo_ws="$tmp_root/repo-whitespace"
mkdir -p "$repo_ws/OpenBurnBarCore/Sources/DemoKit"
git -C "$repo_ws" init -q -b main
git -C "$repo_ws" config user.email selftest@openburnbar.invalid
git -C "$repo_ws" config user.name "Diff Coverage Self-Test"
cat > "$repo_ws/OpenBurnBarCore/Sources/DemoKit/Big.swift" <<'EOF'
public enum Widget {
    public static func base() -> Int {
        return 1
    }
}

public enum Labeler {
    public static func text() -> String {
        return "a b"
    }
}
EOF
cat > "$repo_ws/OpenBurnBarCore/Sources/DemoKit/Helpers.swift" <<'EOF'
public enum Helpers {
    public static func noop() -> Int {
        return 0
    }
}
EOF
git -C "$repo_ws" add -A
git -C "$repo_ws" commit -qm base
base_ws="$(git -C "$repo_ws" rev-parse HEAD)"
cat > "$repo_ws/OpenBurnBarCore/Sources/DemoKit/Big.swift" <<'EOF'
public enum Widget {
    public static func base() -> Int {
        return 1
    }
}
EOF
cat > "$repo_ws/OpenBurnBarCore/Sources/DemoKit/Helpers.swift" <<'EOF'
public enum Helpers {
    public static func noop() -> Int {
        return 0
    }
}

public enum Labeler {
    public static func text() -> String {
        return "a  b"
    }
}
EOF
git -C "$repo_ws" add -A
git -C "$repo_ws" commit -qm move-with-internal-whitespace-edit
lcov_ws="$tmp_root/fixture-whitespace.lcov"
write_swift_lcov "$lcov_ws" "$repo_ws" "OpenBurnBarCore/Sources/DemoKit/Helpers.swift" "DA:9,0"
pkg_ws="$tmp_root/pkg-whitespace.json"
extract_pkg "$lcov_ws" "$repo_ws" "$pkg_ws"
verdict="$tmp_root/verdict-whitespace.json"
rc="$(run_gate "$repo_ws" "$base_ws" packages 80 "$pkg_ws" "$verdict" "$tmp_root/err-whitespace.log")"
check "internal-whitespace literal edit inside a move is NOT exempted and fails" "1" "$rc"
check "internal-whitespace edit stays gated (only the 4 untouched lines move)" \
  "4" "$(json_get "$verdict" 'v["pureMove"]["movedLines"]')"
check "internal-whitespace edit stays in the coverage denominator" \
  "1" "$(json_get "$verdict" 'v["diffCoverage"]["changedLines"]')"

# --- fixture 10: pureMove.gatedLines matches the coverage denominator (R-GH0,
# P3). A no-evidence file adds two STRUCTURAL lines (a stored property and a
# closing brace) plus two executable lines. total_exc drops the structural
# lines, so the reported gated count must equal diffCoverage.changedLines and
# never inflate by counting structural lines the percentage already excludes.
repo_gm="$tmp_root/repo-gated-match"
mkdir -p "$repo_gm/OpenBurnBarCore/Sources/DemoKit"
git -C "$repo_gm" init -q -b main
git -C "$repo_gm" config user.email selftest@openburnbar.invalid
git -C "$repo_gm" config user.name "Diff Coverage Self-Test"
cat > "$repo_gm/OpenBurnBarCore/Sources/DemoKit/Model.swift" <<'EOF'
public struct Model {
    public var id: Int
}
EOF
cat > "$repo_gm/OpenBurnBarCore/Sources/DemoKit/Keep.swift" <<'EOF'
public enum Keep {
    public static func run() -> Int {
        return 7
    }
}
EOF
git -C "$repo_gm" add -A
git -C "$repo_gm" commit -qm base
base_gm="$(git -C "$repo_gm" rev-parse HEAD)"
cat > "$repo_gm/OpenBurnBarCore/Sources/DemoKit/Model.swift" <<'EOF'
public struct Model {
    public var id: Int
    public var name: String
    public func compute() -> Int {
        return id + 2
    }
}
EOF
git -C "$repo_gm" add -A
git -C "$repo_gm" commit -qm add-structural-and-executable
# Evidence names only the untouched Keep.swift, so Model.swift is no_evidence
# (the packages lane still has evidence and does not fail closed).
lcov_gm="$tmp_root/fixture-gated-match.lcov"
write_swift_lcov "$lcov_gm" "$repo_gm" "OpenBurnBarCore/Sources/DemoKit/Keep.swift" "DA:2,1" "DA:3,1"
pkg_gm="$tmp_root/pkg-gated-match.json"
extract_pkg "$lcov_gm" "$repo_gm" "$pkg_gm"
verdict="$tmp_root/verdict-gated-match.json"
rc="$(run_gate "$repo_gm" "$base_gm" packages 80 "$pkg_gm" "$verdict" "$tmp_root/err-gated-match.log")"
check "gated tally equals the coverage denominator (no structural overcount)" \
  "True" "$(json_get "$verdict" 'v["pureMove"]["gatedLines"] == v["diffCoverage"]["changedLines"]')"
check "no-evidence callable signature and return line both stay gated" \
  "2" "$(json_get "$verdict" 'v["pureMove"]["gatedLines"]')"

# --- fixture 11: re-indentation invariant — strip-only normalization must keep
# a REINDENTED relocation matching (R-GH0, P1 non-regression). A helper body
# relocates Big.swift -> Helpers.swift and its lines shift from 4-space to
# 8-space leading indent. The stripped body still matches the removed lines, so
# the reindented block is credited; only the genuinely-new function signature is
# gated (and it is covered), so the gate passes.
repo_reindent="$tmp_root/repo-reindent"
mkdir -p "$repo_reindent/OpenBurnBarCore/Sources/DemoKit"
git -C "$repo_reindent" init -q -b main
git -C "$repo_reindent" config user.email selftest@openburnbar.invalid
git -C "$repo_reindent" config user.name "Diff Coverage Self-Test"
cat > "$repo_reindent/OpenBurnBarCore/Sources/DemoKit/Big.swift" <<'EOF'
public enum Widget {
    public static func base() -> Int {
        return 1
    }
}

public func freeHelper() -> Int {
    let seed = 5
    return seed
}
EOF
cat > "$repo_reindent/OpenBurnBarCore/Sources/DemoKit/Helpers.swift" <<'EOF'
public enum Helpers {
    public static func noop() -> Int {
        return 0
    }
}
EOF
git -C "$repo_reindent" add -A
git -C "$repo_reindent" commit -qm base
base_reindent="$(git -C "$repo_reindent" rev-parse HEAD)"
cat > "$repo_reindent/OpenBurnBarCore/Sources/DemoKit/Big.swift" <<'EOF'
public enum Widget {
    public static func base() -> Int {
        return 1
    }
}
EOF
cat > "$repo_reindent/OpenBurnBarCore/Sources/DemoKit/Helpers.swift" <<'EOF'
public enum Helpers {
    public static func noop() -> Int {
        return 0
    }

    public static func relocated() -> Int {
        let seed = 5
        return seed
    }
}
EOF
git -C "$repo_reindent" add -A
git -C "$repo_reindent" commit -qm reindented-move
lcov_reindent="$tmp_root/fixture-reindent.lcov"
write_swift_lcov "$lcov_reindent" "$repo_reindent" "OpenBurnBarCore/Sources/DemoKit/Helpers.swift" "DA:6,1"
pkg_reindent="$tmp_root/pkg-reindent.json"
extract_pkg "$lcov_reindent" "$repo_reindent" "$pkg_reindent"
verdict="$tmp_root/verdict-reindent.json"
rc="$(run_gate "$repo_reindent" "$base_reindent" packages 80 "$pkg_reindent" "$verdict" "$tmp_root/err-reindent.log")"
check "re-indented block move still credits the 4-space->8-space body lines" \
  "3" "$(json_get "$verdict" 'v["pureMove"]["movedLines"]')"
check "re-indented move passes (only the genuinely-new signature is gated)" "0" "$rc"

# --- fixture 12: app scope requires line truth ------------------------------
# A 100% file-wide summary is deliberately provided to prove it cannot rescue
# missing or uncovered per-line evidence.
repo_app="$tmp_root/repo-app"
mkdir -p "$repo_app/AgentLens/Services/Demo"
git -C "$repo_app" init -q -b main
git -C "$repo_app" config user.email selftest@openburnbar.invalid
git -C "$repo_app" config user.name "Diff Coverage Self-Test"
cat > "$repo_app/AgentLens/Services/Demo/AppLogic.swift" <<'EOF'
enum AppLogic {
}
EOF
git -C "$repo_app" add -A
git -C "$repo_app" commit -qm base
base_app="$(git -C "$repo_app" rev-parse HEAD)"
cat > "$repo_app/AgentLens/Services/Demo/AppLogic.swift" <<'EOF'
enum AppLogic {
    static func value() -> Int {
        #if os(macOS)
        return 42
        #endif
    }
}
EOF
git -C "$repo_app" add -A
git -C "$repo_app" commit -qm app-change

app_summary="$tmp_root/app-summary.json"
cat > "$app_summary" <<EOF
{"targets":[{"name":"$repo_app/AgentLens/Services/Demo/AppLogic.swift","executable":100,"hit":100}]}
EOF

verdict="$tmp_root/verdict-app-missing-lines.json"
rc="$(run_app_gate "$repo_app" "$base_app" 80 "$app_summary" '' "$verdict" "$tmp_root/err-app-missing-lines.log")"
check "app scope fails when per-line evidence file is absent" "1" "$rc"
check "missing app line evidence reports the required artifact" \
  "True" "$(grep -q 'No per-line app coverage data found' "$tmp_root/err-app-missing-lines.log" && echo True || echo False)"

app_empty_lines="$tmp_root/app-empty-lines.json"
printf '{"files":{}}\n' > "$app_empty_lines"
verdict="$tmp_root/verdict-app-noevidence.json"
rc="$(run_app_gate "$repo_app" "$base_app" 80 "$app_summary" "$app_empty_lines" "$verdict" "$tmp_root/err-app-noevidence.log")"
check "app aggregate summary cannot replace missing line evidence" "1" "$rc"
check "app file without a line map is reported as no_evidence" \
  "no_evidence" "$(json_get "$verdict" 'v["details"][0]["method"]')"

app_lines="$tmp_root/app-lines.json"
cat > "$app_lines" <<'EOF'
{"files":{"AgentLens/Services/Demo/AppLogic.swift":{"lines":{"2":true,"4":true}}}}
EOF
verdict="$tmp_root/verdict-app-lines.json"
rc="$(run_app_gate "$repo_app" "$base_app" 80 "$app_summary" "$app_lines" "$verdict" "$tmp_root/err-app-lines.log")"
check "app scope passes with covered per-line evidence" "0" "$rc"
check "app verdict uses line-level evidence" \
  "line_level(app)" "$(json_get "$verdict" 'v["details"][0]["method"]')"
check "app scope excludes conditional-compilation directives from denominator" \
  "2" "$(json_get "$verdict" 'v["diffCoverage"]["changedLines"]')"

# --- fixture 13: exact macOS/Linux package ownership -------------------------
repo_linux="$tmp_root/repo-linux-partition"
linux_dir="$repo_linux/OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse"
mkdir -p "$linux_dir"
git -C "$repo_linux" init -q -b main
git -C "$repo_linux" config user.email selftest@openburnbar.invalid
git -C "$repo_linux" config user.name "Diff Coverage Self-Test"
cat > "$linux_dir/LinuxCloudAuthHTTPClient.swift" <<'EOF'
public enum LinuxOnlyClient {
}
EOF
cat > "$linux_dir/LinuxNamedPortableCredentials.swift" <<'EOF'
public enum PortableLinuxNamedCredentials {
}
EOF
cat > "$linux_dir/LinuxCloudAuthHTTPClient.swiftExtra.swift" <<'EOF'
public enum ExactFileNearMiss {
}
EOF
git -C "$repo_linux" add -A
git -C "$repo_linux" commit -qm base
base_linux="$(git -C "$repo_linux" rev-parse HEAD)"
cat > "$linux_dir/LinuxCloudAuthHTTPClient.swift" <<'EOF'
public enum LinuxOnlyClient {
    public static func value(
        seed: Int = 41
    ) -> Int {
        let result = seed
        return result + 1
    }
}
EOF
cat > "$linux_dir/LinuxNamedPortableCredentials.swift" <<'EOF'
public enum PortableLinuxNamedCredentials {
    public static func value() -> Int {
        return 42
    }
}
EOF
cat > "$linux_dir/LinuxCloudAuthHTTPClient.swiftExtra.swift" <<'EOF'
public enum ExactFileNearMiss {
    public static func value() -> Int {
        return 42
    }
}
EOF
git -C "$repo_linux" add -A
git -C "$repo_linux" commit -qm partition-change

lcov_linux="$tmp_root/fixture-linux-partition.lcov"
cat > "$lcov_linux" <<EOF
SF:$linux_dir/LinuxCloudAuthHTTPClient.swift
DA:5,1
DA:6,0
end_of_record
SF:$linux_dir/LinuxNamedPortableCredentials.swift
DA:2,1
DA:3,1
end_of_record
SF:$linux_dir/LinuxCloudAuthHTTPClient.swiftExtra.swift
DA:2,1
DA:3,1
end_of_record
EOF
pkg_linux="$tmp_root/pkg-linux-partition.json"
extract_pkg "$lcov_linux" "$repo_linux" "$pkg_linux"

verdict="$tmp_root/verdict-macos-package-partition.json"
rc="$(run_gate "$repo_linux" "$base_linux" packages 80 "$pkg_linux" "$verdict" "$tmp_root/err-macos-package-partition.log")"
check "macOS package lane passes its covered portable Linux-named file" "0" "$rc"
check "macOS package lane defers the exact Linux-only file" \
  "linux-packages" \
  "$(json_get "$verdict" '[d for d in v["outOfScope"] if d["file"].endswith("LinuxCloudAuthHTTPClient.swift")][0]["gatedBy"]')"
check "portable Linux-named near miss remains macOS package-owned" \
  "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/LinuxNamedPortableCredentials.swift" \
  "$(json_get "$verdict" '[d for d in v["details"] if d["file"].endswith("LinuxNamedPortableCredentials.swift")][0]["file"]')"
check "exact Linux-only file policy does not match a longer filename" \
  "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/LinuxCloudAuthHTTPClient.swiftExtra.swift" \
  "$(json_get "$verdict" '[d for d in v["details"] if d["file"].endswith("LinuxCloudAuthHTTPClient.swiftExtra.swift")][0]["file"]')"

verdict="$tmp_root/verdict-linux-package-partition.json"
rc="$(run_gate "$repo_linux" "$base_linux" linux-packages 80 "$pkg_linux" "$verdict" "$tmp_root/err-linux-package-partition.log")"
check "Linux-only package lane enforces the 80% threshold" "1" "$rc"
check "Linux-only package lane measures exact LCOV intersection" \
  "50.0" "$(json_get "$verdict" 'v["diffCoverage"]["percent"]')"
check "multiline callable signature lines without LLVM counters are non-executable" \
  "2" "$(json_get "$verdict" 'v["diffCoverage"]["changedLines"]')"
check "Linux-only package lane defers portable package files to macOS" \
  "packages" \
  "$(json_get "$verdict" '[d for d in v["outOfScope"] if d["file"].endswith("LinuxNamedPortableCredentials.swift")][0]["gatedBy"]')"
check "Linux-only package lane defers longer exact-file near miss to macOS" \
  "packages" \
  "$(json_get "$verdict" '[d for d in v["outOfScope"] if d["file"].endswith("LinuxCloudAuthHTTPClient.swiftExtra.swift")][0]["gatedBy"]')"

rc=0
OPENBURNBAR_COVERAGE_REPO_ROOT="$repo_linux" DIFF_COVERAGE_SCOPE=linux-packages \
  "$scripts_dir/diff-coverage.sh" "$base_linux" > /dev/null 2> "$tmp_root/err-linux-closed.log" || rc=$?
check "Linux-only package lane with no LCOV evidence fails closed" "1" "$rc"
check "Linux fail-closed error names the missing package evidence" \
  "True" "$(grep -q 'No package coverage data found' "$tmp_root/err-linux-closed.log" && echo True || echo False)"

rc=0
OPENBURNBAR_COVERAGE_REPO_ROOT="$repo_linux" DIFF_COVERAGE_SCOPE=linux-packages \
  "$scripts_dir/diff-coverage.sh" refs/heads/base-that-does-not-exist '' '' "$pkg_linux" \
  > /dev/null 2> "$tmp_root/err-invalid-base.log" || rc=$?
check "invalid diff base fails closed instead of reporting an empty passing diff" "1" "$rc"
check "invalid diff base error names enumeration failure" \
  "True" "$(grep -q 'Unable to enumerate changed Swift files' "$tmp_root/err-invalid-base.log" && echo True || echo False)"

# Signature syntax is excluded only when a file has real line evidence, and
# even then ambiguous delimiters or executable bodies must stay in the
# denominator. These fixtures reproduce prior zero-denominator fail-opens.
edge_base="$(git -C "$repo_linux" rev-parse HEAD)"
cat > "$linux_dir/LinuxOAuthLoopbackListener.swift" <<'EOF'
public enum LiteralDelimiterEdge {
    public static func value(
        marker: String = "("
    ) -> Int {
        let result = marker.count
        return result
    }
}
EOF
cat > "$linux_dir/LinuxIrohControllerRuntime.swift" <<'EOF'
public enum OneLineBodyEdge {
    public static func value() -> Int { return 42 }
}
EOF
cat > "$linux_dir/LinuxIrohHostIdentityStore.swift" <<'EOF'
public enum DefaultClosureEdge {
    public static func value(
        compute: () -> Int = { 42 }
    ) -> Int {
        return compute()
    }
}
EOF
git -C "$repo_linux" add -A
git -C "$repo_linux" commit -qm signature-edge-change

lcov_signature_edges="$tmp_root/fixture-linux-signature-edges.lcov"
cat > "$lcov_signature_edges" <<EOF
SF:$linux_dir/LinuxOAuthLoopbackListener.swift
DA:1,1
end_of_record
SF:$linux_dir/LinuxIrohControllerRuntime.swift
DA:1,1
end_of_record
SF:$linux_dir/LinuxIrohHostIdentityStore.swift
DA:1,1
end_of_record
EOF
pkg_signature_edges="$tmp_root/pkg-linux-signature-edges.json"
extract_pkg "$lcov_signature_edges" "$repo_linux" "$pkg_signature_edges"

verdict="$tmp_root/verdict-linux-signature-edges.json"
rc="$(run_gate "$repo_linux" "$edge_base" linux-packages 80 "$pkg_signature_edges" "$verdict" "$tmp_root/err-linux-signature-edges.log")"
check "ambiguous callable signatures and inline bodies fail closed" "1" "$rc"
check "all signature-edge files remain in the coverage verdict" \
  "3" "$(json_get "$verdict" 'len(v["details"])')"
check "string delimiter cannot hide an uninstrumented function body" \
  "True" "$(json_get "$verdict" '(lambda d: d["executableLines"] > d["coveredLines"])([d for d in v["details"] if d["file"].endswith("LinuxOAuthLoopbackListener.swift")][0])')"
check "one-line callable body cannot be classified as declaration syntax" \
  "True" "$(json_get "$verdict" '(lambda d: d["executableLines"] > d["coveredLines"])([d for d in v["details"] if d["file"].endswith("LinuxIrohControllerRuntime.swift")][0])')"
check "default closure body cannot be classified as declaration syntax" \
  "True" "$(json_get "$verdict" '(lambda d: d["executableLines"] > d["coveredLines"])([d for d in v["details"] if d["file"].endswith("LinuxIrohHostIdentityStore.swift")][0])')"

# --- fixture 14: line-level ownership inside a mixed-platform Swift file -----
repo_mixed="$tmp_root/repo-mixed-platform"
mixed_dir="$repo_mixed/OpenBurnBarDaemon/Sources/OpenBurnBarDaemon"
mkdir -p "$mixed_dir"
git -C "$repo_mixed" init -q -b main
git -C "$repo_mixed" config user.email selftest@openburnbar.invalid
git -C "$repo_mixed" config user.name "Diff Coverage Self-Test"
cat > "$mixed_dir/MixedPlatform.swift" <<'EOF'
public enum MixedPlatform {
}
EOF
git -C "$repo_mixed" add -A
git -C "$repo_mixed" commit -qm base
base_mixed="$(git -C "$repo_mixed" rev-parse HEAD)"
cat > "$mixed_dir/MixedPlatform.swift" <<'EOF'
public enum MixedPlatform {
#if os(macOS)
    public static func value() -> Int {
        let result = 40
        return result + 2
    }
#elseif os(Linux) && DEBUG
    public static func value() -> Int {
        let result = 41
        return result + 1
    }
#else
    public static func fallback() -> Int {
        return 0
    }
#endif
#if DEBUG
    public static func diagnostic() -> Int {
        let marker = 1
        return marker
    }
#endif
}
EOF
git -C "$repo_mixed" add -A
git -C "$repo_mixed" commit -qm mixed-platform-change

lcov_mixed="$tmp_root/fixture-mixed-platform.lcov"
cat > "$lcov_mixed" <<EOF
SF:$mixed_dir/MixedPlatform.swift
DA:4,1
DA:5,1
DA:9,1
DA:10,0
DA:14,1
DA:19,1
DA:20,1
end_of_record
EOF
pkg_mixed="$tmp_root/pkg-mixed-platform.json"
extract_pkg "$lcov_mixed" "$repo_mixed" "$pkg_mixed"

verdict="$tmp_root/verdict-mixed-macos.json"
rc="$(run_gate "$repo_mixed" "$base_mixed" packages 80 "$pkg_mixed" "$verdict" "$tmp_root/err-mixed-macos.log")"
check "macOS package lane passes covered macOS and unknown-flag branches" "0" "$rc"
check "macOS package lane owns four executable lines in mixed file" \
  "4" "$(json_get "$verdict" 'v["diffCoverage"]["changedLines"]')"
check "macOS package lane defers only Linux-exclusive mixed-file lines" \
  "9" "$(json_get "$verdict" '[d for d in v["deferredLines"] if d["file"].endswith("MixedPlatform.swift")][0]["changedLines"]')"

verdict="$tmp_root/verdict-mixed-linux.json"
rc="$(run_gate "$repo_mixed" "$base_mixed" linux-packages 80 "$pkg_mixed" "$verdict" "$tmp_root/err-mixed-linux.log")"
check "Linux package lane independently fails its uncovered mixed-file branch" "1" "$rc"
check "Linux mixed-file coverage uses only three executable Linux lines" \
  "3" "$(json_get "$verdict" 'v["diffCoverage"]["changedLines"]')"
check "Linux mixed-file coverage remains exact" \
  "66.67" "$(json_get "$verdict" 'v["diffCoverage"]["percent"]')"
check "unknown build-flag branch remains portable instead of moving to Linux" \
  "12" "$(json_get "$verdict" '[d for d in v["deferredLines"] if d["file"].endswith("MixedPlatform.swift")][0]["changedLines"]')"

# -----------------------------------------------------------------------------

if [[ "$failures" -gt 0 ]]; then
  echo "diff-coverage self-test: $failures assertion(s) failed" >&2
  exit 1
fi
echo "diff-coverage self-test: all assertions passed"
