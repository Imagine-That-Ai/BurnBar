#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

source_script="scripts/ci/app-check-smoke.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/app-check-smoke-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

pass=0
fail=0

new_fixture() {
  local dir
  dir="$(mktemp -d "${tmp_root}/fixture.XXXXXX")"
  mkdir -p "${dir}/scripts/ci" "${dir}/scripts/ops" "${dir}/bin"
  cp "${source_script}" "${dir}/scripts/ci/app-check-smoke.sh"
  ln -s "$(command -v dirname)" "${dir}/bin/dirname"
  chmod +x "${dir}/scripts/ci/app-check-smoke.sh"
  printf '%s' "${dir}"
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

echo "app-check-smoke self-test"

fixture="$(new_fixture)"
assert_exit 0 external-run-skips \
  env -i PATH="/usr/bin:/bin" INTERNAL_RUN=false bash "${fixture}/scripts/ci/app-check-smoke.sh"

fixture="$(new_fixture)"
assert_exit 1 internal-run-without-project-fails \
  env -i PATH="/usr/bin:/bin" INTERNAL_RUN=true bash "${fixture}/scripts/ci/app-check-smoke.sh"

fixture="$(new_fixture)"
assert_exit 1 internal-run-without-gcloud-fails \
  env -i PATH="${fixture}/bin" INTERNAL_RUN=true OPENBURNBAR_FIREBASE_PROJECT=burnbar-ci /bin/bash "${fixture}/scripts/ci/app-check-smoke.sh"

fixture="$(new_fixture)"
cat >"${fixture}/bin/gcloud" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${fixture}/bin/gcloud"
cat >"${fixture}/scripts/ops/verify-firestore-app-check-enforcement.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${OPENBURNBAR_FIREBASE_PROJECT:-}" != "burnbar-ci" ]]; then
  echo "expected OPENBURNBAR_FIREBASE_PROJECT=burnbar-ci" >&2
  exit 1
fi
echo "verified ${OPENBURNBAR_FIREBASE_PROJECT}" > app-check-verify-ran.txt
SH
chmod +x "${fixture}/scripts/ops/verify-firestore-app-check-enforcement.sh"
assert_exit 0 internal-run-with-gcloud-runs-verifier \
  env -i PATH="${fixture}/bin:/usr/bin:/bin" INTERNAL_RUN=true OPENBURNBAR_FIREBASE_PROJECT=burnbar-ci bash "${fixture}/scripts/ci/app-check-smoke.sh"
if [[ ! -f "${fixture}/app-check-verify-ran.txt" ]]; then
  echo "FAIL: verifier was not invoked" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
  echo "  ok   verifier was invoked"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAIL: ${fail} app-check-smoke self-test(s) failed" >&2
  exit 1
fi

echo "PASS: ${pass} app-check-smoke positive controls"
