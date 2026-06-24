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
  mkdir -p "${repo}/scripts" "${repo}/functions"
  cp scripts/rollback.sh "${repo}/scripts/rollback.sh"
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
  mkdir -p "${repo}/scripts" "${repo}/functions"
  cp scripts/rollback.sh "${repo}/scripts/rollback.sh"
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

echo "rollback target selection test: all green"
