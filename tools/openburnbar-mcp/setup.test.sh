#!/usr/bin/env bash
#
# Self-test for tools/openburnbar-mcp/setup.sh.
#
# Defends the domain-core native-build cargo gate contract:
#   - cargo absent + OPENBURNBAR_MCP_ALLOW_LEXICAL_ONLY=true  -> setup completes
#     (lexical-only), skipping both the domain-core and static-parser native
#     builds and reaching the final "OK: use ... server.py" guidance line.
#   - cargo absent + default (flag unset)                      -> fail-closed,
#     exit 1 with the domain-core cargo-required ERROR on stderr.
#   - cargo absent + OPENBURNBAR_MCP_ALLOW_LEXICAL_ONLY=false  -> fail-closed,
#     proving the gate is an exact-match `= "true"` parse, not a truthy check.
#
# Runs setup.sh under an isolated PATH with cargo genuinely absent and a
# stubbed python3 that satisfies venv/pip invocations without creating real
# virtualenvs, installing dependencies, or touching the real user HOME.
# Matches the repo's existing *.test.sh self-test convention
# (see scripts/ci/app-check-smoke.test.sh): mktemp fixture, env -i PATH,
# assert_exit helper, pass/fail counters, exit 1 on any failure.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

source_script="tools/openburnbar-mcp/setup.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mcp-setup-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

pass=0
fail=0

# new_fixture: build an isolated tool layout that mirrors the real repo enough
# for setup.sh's `cd "$(dirname "$0")"` + `REPO_ROOT="$(cd ../.. && pwd)"` to
# resolve. Only the lexical-only path is exercised here, which never invokes
# build-domain-core-python.sh, cargo, or the static-parser binary, so those
# repo trees are intentionally absent from the fixture.
new_fixture() {
  local dir
  dir="$(mktemp -d "${tmp_root}/fixture.XXXXXX")"
  mkdir -p "${dir}/tools/openburnbar-mcp/hermes-skill" "${dir}/bin" "${dir}/home"
  cp "${source_script}" "${dir}/tools/openburnbar-mcp/setup.sh"
  chmod +x "${dir}/tools/openburnbar-mcp/setup.sh"
  # A minimal requirements.txt so the pip-install stub has a real argument.
  printf 'mcp==1.27.0\n' >"${dir}/tools/openburnbar-mcp/requirements.txt"
  # Hermes skill source file so the (skipped-under-empty-~/.hermes) link step
  # has a real target if it were ever reached; under this fixture ~/.hermes is
  # absent so only the NOTE branch runs.
  printf '# burnbar-operator skill\n' >"${dir}/tools/openburnbar-mcp/hermes-skill/SKILL.md"

  # python3 stub: handles `-m venv .venv` by laying down a .venv/bin/python that
  # itself accepts `-m pip install ...` as a no-op. No real venv, no installs.
  cat >"${dir}/bin/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -m)
    shift
    case "${1:-}" in
      venv)
        # create a fake venv rooted at the next argv arg
        venv_root="${2:-.venv}"
        mkdir -p "${venv_root}/bin"
        # The venv python re-dispatches pip invocations to a no-op exit 0.
        cat >"${venv_root}/bin/python" <<'PY'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -m)
    shift
    case "${1:-}" in
      pip) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  -c) exit 0 ;;
  "") exit 0 ;;
  *) exit 0 ;;
esac
PY
        chmod +x "${venv_root}/bin/python"
        exit 0
        ;;
      pip)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  -c) exit 0 ;;
  "") exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "${dir}/bin/python3"

  printf '%s' "${dir}"
}

# run_setup: invoke setup.sh under a fully isolated, cargo-less environment.
# env -i wipes PATH/HOME and every inherited var so cargo is genuinely absent
# (host cargo lives outside /usr/bin:/bin) and the real ~/.hermes is untouched.
run_setup() {
  local fixture="$1"; shift
  env -i \
    PATH="${fixture}/bin:/usr/bin:/bin" \
    HOME="${fixture}/home" \
    "$@" bash "${fixture}/tools/openburnbar-mcp/setup.sh"
}

assert_exit() {
  local want="$1" label="$2"
  shift 2
  local output="${tmp_root}/${label}.out"
  local got
  set +e
  "$@" >"${output}" 2>&1
  got=$?
  set -e
  if [[ "${got}" == "${want}" ]]; then
    pass=$((pass + 1))
    printf '  ok   (exit %s) %s\n' "${got}" "${label}"
  else
    fail=$((fail + 1))
    printf '  FAIL (exit %s, want %s) %s\n' "${got}" "${want}" "${label}" >&2
    cat "${output}" >&2
  fi
}

assert_grep() {
  local pattern="$1" label="$2" output_file="$3"
  if grep -q -- "${pattern}" "${output_file}"; then
    pass=$((pass + 1))
    printf '  ok   (match %s) %s\n' "${pattern}" "${label}"
  else
    fail=$((fail + 1))
    printf '  FAIL (no match %s) %s\n' "${pattern}" "${label}" >&2
    cat "${output_file}" >&2
  fi
}

assert_no_match() {
  local pattern="$1" label="$2" output_file="$3"
  if grep -q -- "${pattern}" "${output_file}"; then
    fail=$((fail + 1))
    printf '  FAIL (unexpected match %s) %s\n' "${pattern}" "${label}" >&2
    cat "${output_file}" >&2
  else
    pass=$((pass + 1))
    printf '  ok   (absent %s) %s\n' "${pattern}" "${label}"
  fi
}

echo "openburnbar-mcp setup lexical-only cargo-gate self-test"

# --- lexical-only: cargo absent + flag=true completes (the fix's core path) ---
fixture="$(new_fixture)"
out="${tmp_root}/lexical-only-completes.out"
set +e
run_setup "${fixture}" OPENBURNBAR_MCP_ALLOW_LEXICAL_ONLY=true >"${out}" 2>&1
got=$?
set -e
if [[ "${got}" -ne 0 ]]; then
  fail=$((fail + 1))
  printf '  FAIL (exit %s, want 0) lexical-only-completes\n' "${got}" >&2
  cat "${out}" >&2
else
  pass=$((pass + 1))
  printf '  ok   (exit 0) lexical-only-completes\n'
fi
# Both native builds were skipped, each emitting its WARN line.
assert_grep 'skipping Rust/cargo domain-core Python native build' lexical-domain-core-warn "${out}"
assert_grep 'continuing with lexical-only Project Code Memory setup' lexical-parser-warn "${out}"
# Setup reached the final MCP-config guidance line — proves it ran to completion.
assert_grep 'OK: use' lexical-reached-completion "${out}"
# Native build script was never invoked under lexical-only.
assert_no_match 'build-domain-core-python.sh' lexical-no-native-build "${out}"
# No cargo was ever required on the lexical-only path.
assert_no_match 'cargo is required' lexical-no-cargo-required "${out}"

# --- native-required: cargo absent + flag unset fails (negative invariant) ---
fixture="$(new_fixture)"
out="${tmp_root}/native-required-unset-fails.out"
assert_exit 1 native-required-unset-fails \
  run_setup "${fixture}"
assert_grep 'cargo is required to build the local MCP shared domain core' native-unset-error "${out}"

# --- native-required: cargo absent + flag=false fails (exact-match parse) ---
# A truthy/non-strict gate would wrongly treat "false" as enabled and succeed;
# the exact `= "true"` comparison must reject every other value.
fixture="$(new_fixture)"
out="${tmp_root}/native-required-false-fails.out"
assert_exit 1 native-required-false-fails \
  run_setup "${fixture}" OPENBURNBAR_MCP_ALLOW_LEXICAL_ONLY=false
assert_grep 'cargo is required to build the local MCP shared domain core' native-false-error "${out}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAIL: ${fail} openburnbar-mcp setup self-test(s) failed" >&2
  exit 1
fi

echo "PASS: ${pass} openburnbar-mcp setup lexical-only cargo-gate positive controls"