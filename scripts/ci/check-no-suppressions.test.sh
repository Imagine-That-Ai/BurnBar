#!/usr/bin/env bash
#
# Self-test for scripts/ci/check-no-suppressions.sh.
#
# Builds throwaway git repos and asserts the gate's exit codes for justified vs.
# unjustified suppressions — positive controls that prove the meta-gate actually
# catches bypass attempts (not just passes vacuously). Every case here maps to a
# real bypass/fail-open the gate must keep closed. No network; self-cleaning.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="${here}/check-no-suppressions.sh"

pass=0
fail=0
tmp_roots=()
cleanup() {
  local d
  for d in "${tmp_roots[@]:-}"; do
    [[ -n "${d}" ]] && rm -rf "${d}"
  done
  return 0
}
trap cleanup EXIT

# new_repo <allowlist-entry>...  → prints the repo path on stdout.
new_repo() {
  local dir entry
  dir="$(mktemp -d "${TMPDIR:-/tmp}/cns-test.XXXXXX")"
  tmp_roots+=("${dir}")
  mkdir -p "${dir}/scripts/ci" "${dir}/docs"
  cp "${gate}" "${dir}/scripts/ci/check-no-suppressions.sh"
  {
    echo "# rationale"
    echo "<!-- BEGIN:suppression-allowlist -->"
    echo '```text'
    for entry in "$@"; do echo "${entry}"; done
    echo '```'
    echo "<!-- END:suppression-allowlist -->"
  } >"${dir}/docs/LINT_RATIONALE.md"
  ( cd "${dir}" \
      && git init -q \
      && git config user.email t@t.t \
      && git config user.name t \
      && git add -A \
      && git commit -qm init )
  printf '%s' "${dir}"
}

# assert_exit <want> <repo> <message>
assert_exit() {
  local want="$1" repo="$2" msg="$3" got
  ( cd "${repo}" && git add -A >/dev/null 2>&1 || true )
  set +e
  ( cd "${repo}" && bash scripts/ci/check-no-suppressions.sh >/dev/null 2>&1 )
  got=$?
  set -e
  if [[ "${got}" == "${want}" ]]; then
    pass=$((pass + 1))
    printf '  ok   (exit %s) %s\n' "${got}" "${msg}"
  else
    fail=$((fail + 1))
    printf '  FAIL (exit %s, want %s) %s\n' "${got}" "${want}" "${msg}"
  fi
}

echo "check-no-suppressions self-test"

# ── Baseline behaviour ───────────────────────────────────────────────────────
r="$(new_repo)"
assert_exit 0 "${r}" "clean repo passes"

r="$(new_repo)"
printf '// @ts-ignore\nconst x = 1;\n' >"${r}/a.ts"
assert_exit 1 "${r}" "unjustified @ts-ignore fails"
printf '// @ts-ignore reason: upstream types are wrong here\nconst x = 1;\n' >"${r}/a.ts"
assert_exit 0 "${r}" "@ts-ignore with inline reason passes"

# Triple-slash directive (TS still honours it) must NOT bypass the gate.
r="$(new_repo)"
printf '/// @ts-nocheck\nconst x = 1;\n' >"${r}/a.ts"
assert_exit 1 "${r}" "triple-slash /// @ts-nocheck is caught"

# ── Rust #[allow] + reason on the line above (rustfmt spot) ───────────────────
r="$(new_repo)"
printf '#[allow(dead_code)]\nfn f() {}\n' >"${r}/a.rs"
assert_exit 1 "${r}" "unjustified #[allow] fails"
printf '// reason: kept for FFI symmetry across targets\n#[allow(dead_code)]\nfn f() {}\n' >"${r}/a.rs"
assert_exit 0 "${r}" "#[allow] with reason comment above passes"

# ── Python noqa: coded ok, bare rejected ─────────────────────────────────────
r="$(new_repo)"
printf 'import os  # noqa\n' >"${r}/a.py"
assert_exit 1 "${r}" "bare # noqa fails"
printf 'import os  # noqa: F401\n' >"${r}/a.py"
assert_exit 0 "${r}" "coded # noqa: F401 passes"

# ── Anti-gaming: reason must be real text, in a comment, not in directive args ─
r="$(new_repo)"
printf '@Suppress("UNCHECKED_CAST reason: bogus inside args")\nfun g() {}\n' >"${r}/a.kt"
assert_exit 1 "${r}" "reason inside directive args does not count"
r="$(new_repo)"
printf '@Suppress("X") // reason: y\nfun g() {}\n' >"${r}/a.kt"
assert_exit 1 "${r}" "too-short reason is rejected"
r="$(new_repo)"
printf '@Suppress("X") // reason: load-bearing grouping, see ADR\nfun g() {}\n' >"${r}/a.kt"
assert_exit 0 "${r}" "real reason in comment passes"

# ── Anti-decoy: a `reason:` inside a string literal does NOT justify ─────────
r="$(new_repo)"
printf 'log("/* reason: decoy long enough text */"); // eslint-disable-next-line no-console\n' >"${r}/a.ts"
assert_exit 1 "${r}" "string-literal decoy does not justify (eslint)"
r="$(new_repo)"
printf 's = "# reason: decoy long enough text"  ; import x  # noqa\n' >"${r}/a.py"
assert_exit 1 "${r}" "string-literal decoy does not justify (python noqa)"
r="$(new_repo)"
printf 'def z = "// reason: decoy long enough"; baseline = file("b.xml")\n' >"${r}/build.gradle"
assert_exit 1 "${r}" "string-literal decoy does not justify (config baseline)"

# ── Anti-leak: an adjacent suppression line is not a reason for the next ──────
r="$(new_repo)"
printf '@Suppress("A") // reason: justified and long enough\n@Suppress("B")\nfun g() {}\n' >"${r}/a.kt"
assert_exit 1 "${r}" "adjacent suppression does not borrow the previous reason"

# ── detekt inline waiver ─────────────────────────────────────────────────────
r="$(new_repo)"
printf '// detekt:disable:MagicNumber\nval n = 42\n' >"${r}/a.kt"
assert_exit 1 "${r}" "// detekt: comment without reason fails"
printf '// detekt:disable:MagicNumber reason: wire-format constant\nval n = 42\n' >"${r}/a.kt"
assert_exit 0 "${r}" "// detekt: with reason passes"

# ── Budgets: exact-path only, nested caught ──────────────────────────────────
r="$(new_repo)"
mkdir -p "${r}/budgets/sub"
printf '{}\n' >"${r}/budgets/sub/evil.json"
assert_exit 1 "${r}" "nested un-allowlisted budgets/*.json fails"
r="$(new_repo "budgets/x.json")"
mkdir -p "${r}/budgets"
printf '{}\n' >"${r}/budgets/x.json"
assert_exit 0 "${r}" "exact-allowlisted budget passes"

# ── Baseline files: xml AND yml ──────────────────────────────────────────────
r="$(new_repo)"
printf '<x/>\n' >"${r}/foo.baseline.xml"
assert_exit 1 "${r}" "*baseline*.xml fails"
r="$(new_repo)"
printf 'x: 1\n' >"${r}/lint.baseline.yml"
assert_exit 1 "${r}" "*baseline*.yml fails"

# ── Config-level baseline re-introduction ────────────────────────────────────
r="$(new_repo)"
printf 'detekt {\n  baseline = file("detekt-baseline.xml")\n}\n' >"${r}/build.gradle.kts"
assert_exit 1 "${r}" "baseline = file() in build.gradle.kts fails"
printf 'detekt {\n  baseline = file("b.xml") // reason: legacy module, scheduled for removal\n}\n' >"${r}/build.gradle.kts"
assert_exit 0 "${r}" "config baseline with reason passes"

# ── Token-scoped allowlist: only the named kind is amnestied ──────────────────
r="$(new_repo "legacy.ts | eslint-disable")"
printf '/* eslint-disable */\n// @ts-ignore\nconst x = 1;\n' >"${r}/legacy.ts"
assert_exit 1 "${r}" "scoped allowlist still gates a different token in the file"
r="$(new_repo "legacy.ts | eslint-disable")"
printf '/* eslint-disable */\nconst x = 1;\n' >"${r}/legacy.ts"
assert_exit 0 "${r}" "scoped allowlist permits the named token"

# ── ESLint native -- description counts as justification ─────────────────────
r="$(new_repo)"
printf '// eslint-disable-next-line no-console -- prints the CLI banner\nconsole.log(1);\n' >"${r}/a.ts"
assert_exit 0 "${r}" "eslint -- description passes"

# ── .astro is scanned (was a live blind spot) ────────────────────────────────
r="$(new_repo)"
printf -- '---\n// eslint-disable-next-line\nconst x = 1;\n---\n' >"${r}/a.astro"
assert_exit 1 "${r}" ".astro file is scanned"

# ── Glob in allowlist fails CLOSED (would mask suppressions) ─────────────────
r="$(new_repo "*")"
printf 'import os  # noqa\n' >"${r}/a.py"
assert_exit 2 "${r}" "over-broad glob '*' in allowlist fails closed"

# ── Stale allowlist path: warns but does not fail, and grants no amnesty ──────
# (Another PR deleting an allowlisted artifact must not break this gate.)
r="$(new_repo "does/not/exist.json")"
assert_exit 0 "${r}" "stale allowlist path warns, does not fail"
r="$(new_repo "does/not/exist.ts | eslint-disable")"
printf '// eslint-disable-next-line\nconst x = 1;\n' >"${r}/a.ts"
assert_exit 1 "${r}" "stale allowlist entry grants no amnesty"

# ── Marker robustness ────────────────────────────────────────────────────────
r="$(new_repo)"
printf 'x' >>"${r}/docs/LINT_RATIONALE.md"  # touch; then inject a 2nd BEGIN
printf '\n<!-- BEGIN:suppression-allowlist -->\n*.py\n<!-- END:suppression-allowlist -->\n' \
  >>"${r}/docs/LINT_RATIONALE.md"
assert_exit 2 "${r}" "second BEGIN marker fails closed"
r="$(new_repo)"
printf 'Prose mentioning BEGIN:suppression-allowlist inline is harmless.\n' \
  >>"${r}/docs/LINT_RATIONALE.md"
assert_exit 0 "${r}" "prose mention of the marker does not reopen the block"
r="$(new_repo)"
printf '# no markers at all\n' >"${r}/docs/LINT_RATIONALE.md"
assert_exit 2 "${r}" "missing markers fail closed"

echo
printf 'passed=%s failed=%s\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
echo "check-no-suppressions self-test: all green"
