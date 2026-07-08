#!/usr/bin/env bash
#
# Self-test for scripts/debt/check-string-any-boundary-budget.sh.
#
# Builds throwaway repo trees, copies the gate in, and asserts its exit codes so
# the shrink-only ratchet is proven to actually catch new untyped `[String: Any]`
# boundary sites — not pass vacuously. Covers:
#   * exact match at baseline passes,
#   * a new site OUTSIDE baseline (in either scope) fails,
#   * two occurrences on one line count as two,
#   * alternate Swift spellings count (`[String:Any]`, `Dictionary<String, Any>`),
#   * commented-out occurrences are not counted,
#   * a decrease below baseline passes and reports the drop,
#   * a missing counted scope fails closed,
#   * a missing baseline fails closed,
#   * --print-live emits a machine-readable snapshot,
#   * the ratchet is WIRED into the debt CI job.
# No network; self-cleaning.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="${here}/check-string-any-boundary-budget.sh"

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

# new_repo → prints the repo path on stdout. Seeds the two scope dirs.
new_repo() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/stringany-test.XXXXXX")"
  tmp_roots+=("${dir}")
  mkdir -p \
    "${dir}/scripts/debt" \
    "${dir}/budgets" \
    "${dir}/AgentLens/Services" \
    "${dir}/OpenBurnBarMobile/Services"
  cp "${gate}" "${dir}/scripts/debt/check-string-any-boundary-budget.sh"
  printf '%s' "${dir}"
}

# write_baseline <repo> <agentLens> <mobile> <total>
write_baseline() {
  printf '{ "agentLensStringAny": %s, "mobileStringAny": %s, "total": %s }\n' \
    "$2" "$3" "$4" >"$1/budgets/string-any-boundary-baseline.json"
}

# assert_exit <want> <repo> <message>
assert_exit() {
  local want="$1" repo="$2" msg="$3" got
  set +e
  ( cd "${repo}" && bash scripts/debt/check-string-any-boundary-budget.sh >/dev/null 2>&1 )
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

# assert_stdout_contains <repo> <needle> <message> [gate-arg]
assert_stdout_contains() {
  local repo="$1" needle="$2" msg="$3" arg="${4:-}" out
  set +e
  out="$( cd "${repo}" && bash scripts/debt/check-string-any-boundary-budget.sh "${arg}" 2>/dev/null )"
  set -e
  if printf '%s' "${out}" | grep -qF "${needle}"; then
    pass=$((pass + 1))
    printf '  ok   (emits) %s\n' "${msg}"
  else
    fail=$((fail + 1))
    printf '  FAIL (missing %q) %s\n' "${needle}" "${msg}"
  fi
}

echo "check-string-any-boundary-budget self-test"

# ── Control: exact match passes ───────────────────────────────────────────────
r="$(new_repo)"
printf 'func f(_ x: [String: Any]) {}\n' >"${r}/AgentLens/Services/Foo.swift"
printf 'func g(_ x: [String: Any]) {}\n' >"${r}/OpenBurnBarMobile/Services/Bar.swift"
write_baseline "${r}" 1 1 2
assert_exit 0 "${r}" "exact-match baseline passes"
assert_stdout_contains "${r}" "String-any boundary budget:" "emits the count line"
assert_stdout_contains "${r}" "Top offending files:" "emits top offending files"

# ── A new AgentLens site OVER baseline fails ──────────────────────────────────
r="$(new_repo)"
printf 'let a: [String: Any] = [:]\n' >"${r}/AgentLens/Services/Foo.swift"
printf 'let b: [String: Any] = [:]\n' >"${r}/AgentLens/Services/Leak.swift"
write_baseline "${r}" 1 0 1
assert_exit 1 "${r}" "a new AgentLens [String: Any] over baseline fails"

# ── A new Mobile site OVER baseline fails ─────────────────────────────────────
r="$(new_repo)"
printf 'let a: [String: Any] = [:]\n' >"${r}/OpenBurnBarMobile/Services/Foo.swift"
printf 'let b: [String: Any] = [:]\n' >"${r}/OpenBurnBarMobile/Services/Leak.swift"
write_baseline "${r}" 0 1 1
assert_exit 1 "${r}" "a new OpenBurnBarMobile [String: Any] over baseline fails"

# ── Two occurrences on one line count as two ──────────────────────────────────
r="$(new_repo)"
printf 'func h(_ x: [String: Any]) -> [String: Any] { x }\n' \
  >"${r}/AgentLens/Services/Foo.swift"
write_baseline "${r}" 1 0 1
assert_exit 1 "${r}" "two occurrences on one line count as two (over baseline)"

# ── Valid Swift spelling variants count ───────────────────────────────────────
r="$(new_repo)"
{
  printf 'let a: [String:Any] = [:]\n'
  printf 'let b: [ String : Any ] = [:]\n'
  printf 'let c: Dictionary<String, Any> = [:]\n'
  printf 'let d: Dictionary < String , Any > = [:]\n'
} >"${r}/AgentLens/Services/Foo.swift"
write_baseline "${r}" 3 0 3
assert_exit 1 "${r}" "alternate Swift spellings count and fail over baseline"

# ── Commented-out occurrences are not counted ─────────────────────────────────
r="$(new_repo)"
printf '// let a: [String: Any] = [:]\n/// see [String: Any]\n * [String: Any]\n' \
  >"${r}/AgentLens/Services/Foo.swift"
printf 'let b: [String: Any] = [:]\n' >"${r}/OpenBurnBarMobile/Services/Bar.swift"
write_baseline "${r}" 0 1 1
assert_exit 0 "${r}" "commented-out occurrences are not counted"

# ── A decrease below baseline passes and reports the drop ─────────────────────
r="$(new_repo)"
printf 'let a: [String: Any] = [:]\n' >"${r}/AgentLens/Services/Foo.swift"
write_baseline "${r}" 5 5 10
assert_exit 0 "${r}" "a decrease below baseline passes (shrink-only)"
assert_stdout_contains "${r}" "dropped" "reports the drop as a notice"

# ── Missing counted scope fails closed ────────────────────────────────────────
r="$(new_repo)"
rm -rf "${r}/OpenBurnBarMobile"
write_baseline "${r}" 0 0 0
assert_exit 1 "${r}" "missing counted scope fails closed"

# ── Missing baseline fails closed ─────────────────────────────────────────────
r="$(new_repo)"
printf 'let a: [String: Any] = [:]\n' >"${r}/AgentLens/Services/Foo.swift"
assert_exit 1 "${r}" "missing baseline fails closed"

# ── --print-live emits a machine-readable snapshot ───────────────────────────
r="$(new_repo)"
printf 'let a: [String: Any] = [:]\n' >"${r}/AgentLens/Services/Foo.swift"
assert_stdout_contains "${r}" '"total": 1' "--print-live emits the live total" "--print-live"

# ── Regression: the ratchet is WIRED into the debt CI job ─────────────────────
# A shrink-only ratchet that no workflow runs cannot fail a pipeline, so a new
# [String: Any] boundary site could still land green. Assert the structural-debt
# job actually invokes this script.
workflow="${here}/../../.github/workflows/code-quality.yml"
if [[ -f "${workflow}" ]] && grep -q "check-string-any-boundary-budget.sh" "${workflow}"; then
  pass=$((pass + 1))
  printf '  ok   (ci-wired) .github/workflows/code-quality.yml invokes the ratchet\n'
else
  fail=$((fail + 1))
  printf '  FAIL string-any ratchet is not wired into .github/workflows/code-quality.yml\n'
fi

echo
printf 'passed=%s failed=%s\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
echo "check-string-any-boundary-budget self-test: all green"
