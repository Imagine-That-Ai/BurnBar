#!/usr/bin/env bash
# Self-test for scripts/lib/swift-toolchain.sh.
#
# Every case runs the helper in a scrubbed `env -i` subprocess with fake
# toolchains on disk, so the assertions never depend on what Xcode, swiftly, or
# Command Line Tools happen to be installed on the host.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="${repo_root}/scripts/lib/swift-toolchain.sh"

if [[ ! -f "${helper}" ]]; then
  echo "FAIL: ${helper} does not exist" >&2
  exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/obb-swift-toolchain-test.XXXXXX")"
cleanup() { rm -rf "${tmp}"; }
trap cleanup EXIT

failures=0
note_fail() {
  failures=$((failures + 1))
  echo "FAIL: $*" >&2
}

make_fake_swift() {
  # make_fake_swift <path> <label>
  local path="$1"
  local label="$2"
  mkdir -p "$(dirname "${path}")"
  cat > "${path}" <<FAKE
#!/bin/sh
if [ "\$1" = "--version" ]; then
  echo "Apple Swift version 0.0.0 (${label})"
  echo "Target: fake"
  exit 0
fi
echo "fake swift (${label}) invoked with: \$*"
FAKE
  chmod +x "${path}"
}

# Deliberate space in the directory name: the repo checkout on the maintainer's
# machine lives under a path with a space, and so does the Xcode app bundle.
xcode_dir="${tmp}/Fake Xcode.app/Contents/Developer"
make_fake_swift "${xcode_dir}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" "developer-dir"

xcrun_target="${tmp}/xcrun toolchain/usr/bin/swift"
make_fake_swift "${xcrun_target}" "xcrun"

path_bin="${tmp}/path bin"
make_fake_swift "${path_bin}/swift" "path"

override_swift="${tmp}/override bin/swift"
make_fake_swift "${override_swift}" "override"

# Fake xcrun answers `--find swift` from the environment so each case can point
# it wherever it likes (and so a case can make xcrun fail).
mkdir -p "${path_bin}"
cat > "${path_bin}/xcrun" <<'FAKE'
#!/bin/sh
if [ "$1" = "--find" ] && [ "$2" = "swift" ]; then
  if [ -n "${FAKE_XCRUN_SWIFT:-}" ]; then
    printf '%s\n' "${FAKE_XCRUN_SWIFT}"
    exit 0
  fi
  exit 1
fi
exit 1
FAKE
chmod +x "${path_bin}/xcrun"

empty_bin="${tmp}/empty bin"
mkdir -p "${empty_bin}"

stdout_file="${tmp}/stdout"
stderr_file="${tmp}/stderr"

# run_case NAME [VAR=VALUE ...]
# Sources the helper in a hermetic subprocess and prints "<swift>|<source>" on
# stdout. Records the exit status in run_status.
run_status=0
run_case() {
  local name="$1"
  shift
  set +e
  env -i "$@" /bin/bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$0"
    obb_swift_init
    printf "%s|%s\n" "${OBB_SWIFT}" "${OBB_SWIFT_SOURCE}"
  ' "${helper}" >"${stdout_file}" 2>"${stderr_file}"
  run_status=$?
  set -e
  if [[ -n "${OBB_TEST_TRACE:-}" ]]; then
    echo "--- ${name} (exit ${run_status})"
    sed 's/^/    stderr: /' "${stderr_file}"
  fi
}

# ── 1. OPENBURNBAR_SWIFT wins over everything else ──────────────────────────
run_case "override" \
  "PATH=${path_bin}:/usr/bin:/bin" \
  "DEVELOPER_DIR=${xcode_dir}" \
  "FAKE_XCRUN_SWIFT=${xcrun_target}" \
  "OPENBURNBAR_SWIFT=${override_swift}"
if [[ "${run_status}" -ne 0 ]]; then
  note_fail "OPENBURNBAR_SWIFT override should succeed (exit ${run_status})"
elif [[ "$(cat "${stdout_file}")" != "${override_swift}|OPENBURNBAR_SWIFT" ]]; then
  note_fail "OPENBURNBAR_SWIFT override resolved to '$(cat "${stdout_file}")'"
fi

# ── 2. A bogus OPENBURNBAR_SWIFT fails loudly instead of falling back ───────
run_case "override-broken" \
  "PATH=${path_bin}:/usr/bin:/bin" \
  "OPENBURNBAR_SWIFT=${tmp}/definitely-not-a-swift"
if [[ "${run_status}" -eq 0 ]]; then
  note_fail "A non-executable OPENBURNBAR_SWIFT must not resolve"
elif ! grep -q "OPENBURNBAR_SWIFT" "${stderr_file}"; then
  note_fail "Broken OPENBURNBAR_SWIFT error must name the variable: $(cat "${stderr_file}")"
elif ! grep -q "definitely-not-a-swift" "${stderr_file}"; then
  note_fail "Broken OPENBURNBAR_SWIFT error must show the offending path"
fi

# ── 3. DEVELOPER_DIR toolchain beats bare PATH swift ────────────────────────
run_case "developer-dir" \
  "PATH=${path_bin}:/usr/bin:/bin" \
  "DEVELOPER_DIR=${xcode_dir}" \
  "FAKE_XCRUN_SWIFT=${xcrun_target}"
if [[ "${run_status}" -ne 0 ]]; then
  note_fail "DEVELOPER_DIR resolution should succeed (exit ${run_status})"
elif [[ "$(cat "${stdout_file}")" != "${xcode_dir}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift|DEVELOPER_DIR" ]]; then
  note_fail "DEVELOPER_DIR resolved to '$(cat "${stdout_file}")'"
fi

# ── 4. A DEVELOPER_DIR without a toolchain falls through to xcrun ───────────
run_case "developer-dir-empty" \
  "PATH=${path_bin}:/usr/bin:/bin" \
  "DEVELOPER_DIR=${tmp}/no-such-developer-dir" \
  "FAKE_XCRUN_SWIFT=${xcrun_target}"
if [[ "${run_status}" -ne 0 ]]; then
  note_fail "xcrun fallback should succeed (exit ${run_status})"
elif [[ "$(cat "${stdout_file}")" != "${xcrun_target}|xcrun --find swift" ]]; then
  note_fail "xcrun fallback resolved to '$(cat "${stdout_file}")'"
fi

# ── 5. No xcrun at all (Linux) falls back to swift on PATH ──────────────────
run_case "path-fallback" \
  "PATH=${path_bin}:/usr/bin:/bin"
if [[ "${run_status}" -ne 0 ]]; then
  note_fail "PATH fallback should succeed (exit ${run_status})"
elif [[ "$(cat "${stdout_file}")" != "${path_bin}/swift|PATH" ]]; then
  note_fail "PATH fallback resolved to '$(cat "${stdout_file}")'"
fi

# ── 6. Nothing anywhere: fail with an actionable message, never silently ────
run_case "nothing" "PATH=${empty_bin}"
if [[ "${run_status}" -eq 0 ]]; then
  note_fail "Resolution must fail when no swift exists anywhere"
else
  for needle in "no swift toolchain" "OPENBURNBAR_SWIFT" "xcrun"; do
    if ! grep -qi "${needle}" "${stderr_file}"; then
      note_fail "Missing-toolchain error must mention '${needle}': $(cat "${stderr_file}")"
    fi
  done
fi

# ── 7. The banner is stderr-only, so `$(...)` capture stays clean ───────────
run_case "banner-stream" "PATH=${path_bin}:/usr/bin:/bin"
if [[ "$(cat "${stdout_file}")" != "${path_bin}/swift|PATH" ]]; then
  note_fail "Banner leaked into stdout: $(cat "${stdout_file}")"
fi
if ! grep -q "swift toolchain" "${stderr_file}"; then
  note_fail "Banner must name the toolchain on stderr: $(cat "${stderr_file}")"
fi
if ! grep -q "${path_bin}/swift" "${stderr_file}"; then
  note_fail "Banner must print the resolved swift path"
fi
if ! grep -qi "resolved via" "${stderr_file}"; then
  note_fail "Banner must say which rule matched"
fi
if ! grep -q "Apple Swift version 0.0.0 (path)" "${stderr_file}"; then
  note_fail "Banner must print the toolchain version line"
fi

# ── 8. A resolved-but-broken toolchain still reports, it does not hang ──────
broken_swift="${tmp}/broken bin/swift"
mkdir -p "$(dirname "${broken_swift}")"
cat > "${broken_swift}" <<'FAKE'
#!/bin/sh
echo "boom: toolchain is broken" >&2
exit 3
FAKE
chmod +x "${broken_swift}"
run_case "broken-toolchain" \
  "PATH=/usr/bin:/bin" \
  "OPENBURNBAR_SWIFT=${broken_swift}"
if [[ "${run_status}" -ne 0 ]]; then
  note_fail "Resolution succeeds even when --version fails (exit ${run_status})"
elif ! grep -q "boom: toolchain is broken" "${stderr_file}"; then
  note_fail "Banner must surface a failing --version instead of hiding it"
fi

if [[ "${failures}" -ne 0 ]]; then
  echo "FAIL: ${failures} swift-toolchain resolution assertion(s) failed." >&2
  exit 1
fi

echo "PASS: swift toolchain resolution is deterministic, ordered, and loud on failure."
