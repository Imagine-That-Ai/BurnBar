#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-rollback-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

make_commit() {
  local repo="$1"
  local stamp="$2"
  local body="$3"
  printf '%s\n' "${body}" >"${repo}/functions/index.js"
  git -C "${repo}" add .
  GIT_AUTHOR_DATE="${stamp}" GIT_COMMITTER_DATE="${stamp}" \
    git -C "${repo}" commit --quiet -m "test ${body}"
}

make_tag() {
  local repo="$1"
  local tag="$2"
  local stamp="$3"
  GIT_COMMITTER_DATE="${stamp}" git -C "${repo}" tag -a "${tag}" -m "${tag}"
}

build_fixture_repo() {
  local name="$1"
  local repo="${TMP_DIR}/${name}"
  local origin="${TMP_DIR}/${name}.git"
  mkdir -p "${repo}/scripts/ci" "${repo}/functions"
  cp scripts/rollback.sh "${repo}/scripts/rollback.sh"
  cp scripts/ci/sentry_dsn.py "${repo}/scripts/ci/sentry_dsn.py"
  chmod +x "${repo}/scripts/rollback.sh"
  printf '%s\n' 'FIREBASE_PROJECT=burnbar-test' >"${repo}/functions/.env.burnbar.production"

  git -C "${repo}" init --quiet
  git -C "${repo}" config user.email "rollback-test@example.invalid"
  git -C "${repo}" config user.name "Rollback Test"
  git -C "${repo}" config commit.gpgSign false
  git -C "${repo}" config tag.gpgSign false

  make_commit "${repo}" "2026-06-01T00:00:00Z" "one"
  make_tag "${repo}" "v1.0.0" "2026-06-01T00:00:00Z"

  make_commit "${repo}" "2026-06-21T00:00:00Z" "two"
  make_tag "${repo}" "v1.0.1" "2026-06-21T00:00:00Z"

  make_commit "${repo}" "2026-06-21T12:00:00Z" "calver"
  make_tag "${repo}" "v2026.6.5" "2026-06-21T12:00:00Z"

  make_commit "${repo}" "2026-06-22T00:00:00Z" "three"
  make_tag "${repo}" "v1.0.2" "2026-06-22T00:00:00Z"

  git init --quiet --bare "${origin}"
  git -C "${repo}" remote add origin "${origin}"
  git -C "${repo}" push --quiet --tags origin HEAD
  printf '%s\n' "${repo}"
}

build_stale_fixture_repo() {
  local name="$1"
  local repo="${TMP_DIR}/${name}"
  local origin="${TMP_DIR}/${name}.git"
  mkdir -p "${repo}/scripts/ci" "${repo}/functions"
  cp scripts/rollback.sh "${repo}/scripts/rollback.sh"
  cp scripts/ci/sentry_dsn.py "${repo}/scripts/ci/sentry_dsn.py"
  chmod +x "${repo}/scripts/rollback.sh"
  printf '%s\n' 'FIREBASE_PROJECT=burnbar-test' >"${repo}/functions/.env.burnbar.production"

  git -C "${repo}" init --quiet
  git -C "${repo}" config user.email "rollback-test@example.invalid"
  git -C "${repo}" config user.name "Rollback Test"
  git -C "${repo}" config commit.gpgSign false
  git -C "${repo}" config tag.gpgSign false

  make_commit "${repo}" "2026-01-01T00:00:00Z" "old"
  make_tag "${repo}" "v1.0.0" "2026-01-01T00:00:00Z"

  make_commit "${repo}" "2026-06-22T00:00:00Z" "current"
  make_tag "${repo}" "v1.0.1" "2026-06-22T00:00:00Z"

  git init --quiet --bare "${origin}"
  git -C "${repo}" remote add origin "${origin}"
  git -C "${repo}" push --quiet --tags origin HEAD
  printf '%s\n' "${repo}"
}

run_rollback() {
  local repo="$1"
  shift
  (cd "${repo}" && bash scripts/rollback.sh "$@")
}

canonical_repo="$(build_fixture_repo canonical)"
canonical_out="${TMP_DIR}/canonical.out"
STALE_TAG_MAX_AGE_DAYS=999 run_rollback "${canonical_repo}" --dry-run >"${canonical_out}"
if ! grep -Fq "Target: v1.0.1" "${canonical_out}"; then
  echo "FAIL: auto rollback did not select the previous canonical SemVer tag" >&2
  cat "${canonical_out}" >&2
  exit 1
fi
if grep -Fq "Target: v2026.6.5" "${canonical_out}"; then
  echo "FAIL: auto rollback selected a year-shaped calver tag" >&2
  cat "${canonical_out}" >&2
  exit 1
fi

stale_repo="$(build_stale_fixture_repo stale)"
stale_err="${TMP_DIR}/stale.err"
if STALE_TAG_MAX_AGE_DAYS=1 run_rollback "${stale_repo}" --dry-run >"${TMP_DIR}/stale.out" 2>"${stale_err}"; then
  echo "FAIL: stale auto-selected rollback target was accepted" >&2
  exit 1
fi
if ! grep -Fq "Auto-selected target 'v1.0.0'" "${stale_err}"; then
  echo "FAIL: stale-target refusal did not name the auto-selected tag" >&2
  cat "${stale_err}" >&2
  exit 1
fi

STALE_TAG_MAX_AGE_DAYS=1 run_rollback "${stale_repo}" --allow-stale --dry-run >"${TMP_DIR}/allow-stale.out"
if ! grep -Fq "Target: v1.0.0" "${TMP_DIR}/allow-stale.out"; then
  echo "FAIL: --allow-stale did not preserve the auto-selected stale target" >&2
  cat "${TMP_DIR}/allow-stale.out" >&2
  exit 1
fi

STALE_TAG_MAX_AGE_DAYS=1 run_rollback "${stale_repo}" v1.0.0 --dry-run >"${TMP_DIR}/explicit.out"
if ! grep -Fq "Target: v1.0.0" "${TMP_DIR}/explicit.out"; then
  echo "FAIL: explicit rollback target was not honored" >&2
  cat "${TMP_DIR}/explicit.out" >&2
  exit 1
fi

live_commit="$(git -C "${canonical_repo}" rev-parse 'refs/tags/v1.0.2^{commit}')"
OPENBURNBAR_SOURCE_COMMIT="${live_commit}" run_rollback "${canonical_repo}" v1.0.1 --dry-run >"${TMP_DIR}/live-routine.out"
if ! grep -Fq "Target: v1.0.1" "${TMP_DIR}/live-routine.out"; then
  echo "FAIL: routine rollback to an ancestor of the published live source commit was refused" >&2
  cat "${TMP_DIR}/live-routine.out" >&2
  exit 1
fi

older_live="$(git -C "${canonical_repo}" rev-parse 'refs/tags/v1.0.1^{commit}')"
if OPENBURNBAR_SOURCE_COMMIT="${older_live}" run_rollback "${canonical_repo}" v1.0.2 --dry-run >"${TMP_DIR}/live-forward.out" 2>"${TMP_DIR}/live-forward.err"; then
  echo "FAIL: rollback accepted a target that is not an ancestor of the live source commit" >&2
  exit 1
fi
if ! grep -Fq "is not an ancestor of live source commit" "${TMP_DIR}/live-forward.err"; then
  echo "FAIL: forward-move refusal did not name the hazard" >&2
  cat "${TMP_DIR}/live-forward.err" >&2
  exit 1
fi

make_commit "${canonical_repo}" "2026-06-23T00:00:00Z" "unpublished"
unpublished_live="$(git -C "${canonical_repo}" rev-parse HEAD)"
if OPENBURNBAR_SOURCE_COMMIT="${unpublished_live}" run_rollback "${canonical_repo}" v1.0.1 --dry-run >"${TMP_DIR}/live-unpublished.out" 2>"${TMP_DIR}/live-unpublished.err"; then
  echo "FAIL: rollback accepted a live source commit that no tag or remote branch contains" >&2
  exit 1
fi
if ! grep -Fq "is not contained in any tag or remote branch" "${TMP_DIR}/live-unpublished.err"; then
  echo "FAIL: unpublished live-source refusal did not name the hazard" >&2
  cat "${TMP_DIR}/live-unpublished.err" >&2
  exit 1
fi

OPENBURNBAR_SOURCE_COMMIT="${unpublished_live}" run_rollback "${canonical_repo}" v1.0.1 --force --dry-run >"${TMP_DIR}/force-unpublished.out"
if ! grep -Fq "Target: v1.0.1" "${TMP_DIR}/force-unpublished.out"; then
  echo "FAIL: --force did not override the unpublished live-source guard" >&2
  cat "${TMP_DIR}/force-unpublished.out" >&2
  exit 1
fi

missing_sentry_repo="$(build_fixture_repo missing-sentry)"
missing_sentry_head="$(git -C "${missing_sentry_repo}" rev-parse HEAD)"
if run_rollback "${missing_sentry_repo}" v1.0.1 --yes >"${TMP_DIR}/missing-sentry.out" 2>"${TMP_DIR}/missing-sentry.err"; then
  echo "FAIL: production rollback accepted a missing SENTRY_DSN" >&2
  exit 1
fi
if ! grep -Fq "SENTRY_DSN is required" "${TMP_DIR}/missing-sentry.err"; then
  echo "FAIL: missing-Sentry refusal did not explain the production requirement" >&2
  cat "${TMP_DIR}/missing-sentry.err" >&2
  exit 1
fi
if [[ "$(git -C "${missing_sentry_repo}" rev-parse HEAD)" != "${missing_sentry_head}" ]]; then
  echo "FAIL: missing-Sentry refusal mutated the fixture checkout" >&2
  exit 1
fi

invalid_sentry_repo="$(build_fixture_repo invalid-sentry)"
invalid_sentry_head="$(git -C "${invalid_sentry_repo}" rev-parse HEAD)"
if SENTRY_DSN="http://public@example.ingest.sentry.io/12345" \
  run_rollback "${invalid_sentry_repo}" v1.0.1 --yes >"${TMP_DIR}/invalid-sentry.out" 2>"${TMP_DIR}/invalid-sentry.err"; then
  echo "FAIL: production rollback accepted an invalid SENTRY_DSN" >&2
  exit 1
fi
if ! grep -Fq "SENTRY_DSN must use https" "${TMP_DIR}/invalid-sentry.err"; then
  echo "FAIL: invalid-Sentry refusal did not report the validation error" >&2
  cat "${TMP_DIR}/invalid-sentry.err" >&2
  exit 1
fi
if [[ "$(git -C "${invalid_sentry_repo}" rev-parse HEAD)" != "${invalid_sentry_head}" ]]; then
  echo "FAIL: invalid-Sentry refusal mutated the fixture checkout" >&2
  exit 1
fi

execution_repo="$(build_fixture_repo execution)"
execution_commit="$(git -C "${execution_repo}" rev-parse 'refs/tags/v1.0.1^{commit}')"
fake_bin="${TMP_DIR}/fake-bin"
mkdir -p "${fake_bin}"
cat >"${fake_bin}/npm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 0
SH
cat >"${fake_bin}/firebase" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *"deploy --only functions"* ]]
exit 0
SH
chmod +x "${fake_bin}/npm" "${fake_bin}/firebase"

valid_sentry_dsn="https://public@example.ingest.sentry.io/12345"
PATH="${fake_bin}:${PATH}" \
  SENTRY_DSN="${valid_sentry_dsn}" \
  run_rollback "${execution_repo}" v1.0.1 --yes >"${TMP_DIR}/execution.out"

rollback_env="${execution_repo}/functions/.env.burnbar"
for expected in \
  "FUNCTION_VERSION=v1.0.1" \
  "OPENBURNBAR_SOURCE_COMMIT=${execution_commit}" \
  "SENTRY_DSN=${valid_sentry_dsn}" \
  "SENTRY_ENVIRONMENT=production"; do
  if ! grep -Fqx "${expected}" "${rollback_env}"; then
    echo "FAIL: rollback runtime config is missing ${expected}" >&2
    cat "${rollback_env}" >&2
    exit 1
  fi
done
if [[ "$(git -C "${execution_repo}" rev-parse HEAD)" != "${execution_commit}" ]]; then
  echo "FAIL: rollback execution did not remain on the exact target-tag commit" >&2
  exit 1
fi

echo "rollback target selection test: all green"
