#!/usr/bin/env bash
#
# Self-test for scripts/debt/check-raw-firestore-budget.sh.
#
# Builds throwaway repo trees, copies the gate in, and asserts its exit codes so
# the shrink-only ratchet is proven to actually catch new raw Firestore access —
# not pass vacuously. Covers the three contract cases from R-GH6:
#   * a raw call OUTSIDE the allowlist increments and (over baseline) fails,
#   * a raw call INSIDE an allowlisted gateway does NOT count,
#   * a decrease below baseline passes.
# Plus positive controls for Android singletons, multi-call lines, comment
# exclusion, a missing baseline, and the emitted count/offenders. No network;
# self-cleaning.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="${here}/check-raw-firestore-budget.sh"

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

# new_repo → prints the repo path on stdout. Seeds the three sanctioned gateway
# files, each already holding a raw handle that must NEVER be counted.
new_repo() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/rawfs-test.XXXXXX")"
  tmp_roots+=("${dir}")
  mkdir -p \
    "${dir}/scripts/debt" \
    "${dir}/budgets" \
    "${dir}/AgentLens/Services/CloudSync" \
    "${dir}/AgentLens/Views/Settings" \
    "${dir}/OpenBurnBarMobile/Services" \
    "${dir}/android/app/src/main/java/com/openburnbar/data" \
    "${dir}/android/app/src/main/java/com/openburnbar/data/firebase"
  cp "${gate}" "${dir}/scripts/debt/check-raw-firestore-budget.sh"
  printf 'func make() { let db = Firestore.firestore(); _ = db }\n' \
    >"${dir}/AgentLens/Services/CloudSync/CloudSyncFirestoreGateway.swift"
  printf 'var db: Firestore { Firestore.firestore() }\n' \
    >"${dir}/OpenBurnBarMobile/Services/FirestoreRepository.swift"
  printf 'val db = Firebase.firestore\n' \
    >"${dir}/android/app/src/main/java/com/openburnbar/data/firebase/FirestoreRepository.kt"
  printf '%s' "${dir}"
}

# write_baseline <repo> <swift> <android> <total>
write_baseline() {
  printf '{ "swiftFirestoreFirestore": %s, "androidFirestoreSingletons": %s, "total": %s }\n' \
    "$2" "$3" "$4" >"$1/budgets/raw-firestore-baseline.json"
}

# assert_exit <want> <repo> <message>
assert_exit() {
  local want="$1" repo="$2" msg="$3" got
  set +e
  ( cd "${repo}" && bash scripts/debt/check-raw-firestore-budget.sh >/dev/null 2>&1 )
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
  out="$( cd "${repo}" && bash scripts/debt/check-raw-firestore-budget.sh "${arg}" 2>/dev/null )"
  set -e
  if printf '%s' "${out}" | grep -qF "${needle}"; then
    pass=$((pass + 1))
    printf '  ok   (emits) %s\n' "${msg}"
  else
    fail=$((fail + 1))
    printf '  FAIL (missing %q) %s\n' "${needle}" "${msg}"
  fi
}

echo "check-raw-firestore-budget self-test"

# ── Control: exact match passes; gateway raw handles are exempt ───────────────
r="$(new_repo)"
printf 'let db = Firestore.firestore()\n' >"${r}/AgentLens/Services/Foo.swift"
printf 'val db = FirebaseFirestore.getInstance()\n' \
  >"${r}/android/app/src/main/java/com/openburnbar/data/Bar.kt"
write_baseline "${r}" 1 1 2
assert_exit 0 "${r}" "exact-match baseline passes (allowlisted gateway calls not counted)"
assert_stdout_contains "${r}" "Raw Firestore budget:" "emits the count line"
assert_stdout_contains "${r}" "Top offending files:" "emits top offending files"

# ── A raw call INSIDE an allowlisted gateway does NOT count ───────────────────
r="$(new_repo)"
printf 'let db = Firestore.firestore()\n' >"${r}/AgentLens/Services/Foo.swift"
printf 'val db = FirebaseFirestore.getInstance()\n' \
  >"${r}/android/app/src/main/java/com/openburnbar/data/Bar.kt"
# Pile extra handles into the gateways (incl. three on one line) — still exempt.
printf 'let a = Firestore.firestore(); let b = Firestore.firestore(); let c = Firestore.firestore()\n' \
  >"${r}/AgentLens/Services/CloudSync/CloudSyncFirestoreGateway.swift"
printf 'val a = Firebase.firestore\nval b = FirebaseFirestore.getInstance()\n' \
  >"${r}/android/app/src/main/java/com/openburnbar/data/firebase/FirestoreRepository.kt"
write_baseline "${r}" 1 1 2
assert_exit 0 "${r}" "raw handles inside allowlisted gateway/repository files are exempt"

# ── A raw Swift call OUTSIDE the allowlist increments and (over baseline) fails ─
r="$(new_repo)"
printf 'let db = Firestore.firestore()\n' >"${r}/AgentLens/Services/Foo.swift"
printf 'val db = FirebaseFirestore.getInstance()\n' \
  >"${r}/android/app/src/main/java/com/openburnbar/data/Bar.kt"
printf 'let db = Firestore.firestore()\n' >"${r}/AgentLens/Views/Settings/Leak.swift"
write_baseline "${r}" 1 1 2
assert_exit 1 "${r}" "new raw Firestore.firestore() outside the allowlist exceeds baseline and fails"

# ── A raw Android singleton OUTSIDE the allowlist fails (both token forms) ─────
r="$(new_repo)"
printf 'let db = Firestore.firestore()\n' >"${r}/AgentLens/Services/Foo.swift"
printf 'val a = FirebaseFirestore.getInstance()\nval b = Firebase.firestore\n' \
  >"${r}/android/app/src/main/java/com/openburnbar/data/Bar.kt"
write_baseline "${r}" 1 1 2
assert_exit 1 "${r}" "new raw Android Firestore singleton outside the allowlist exceeds baseline and fails"

# ── Two raw calls on one non-allowlisted line count as two ────────────────────
r="$(new_repo)"
printf 'let a = Firestore.firestore(); let b = Firestore.firestore()\n' \
  >"${r}/AgentLens/Services/Foo.swift"
write_baseline "${r}" 1 0 1
assert_exit 1 "${r}" "two raw calls on one line count as two (over baseline)"

# ── Commented-out raw calls are not counted ──────────────────────────────────
r="$(new_repo)"
printf '// let db = Firestore.firestore()\n/// see Firestore.firestore()\n' \
  >"${r}/AgentLens/Services/Foo.swift"
printf 'val db = FirebaseFirestore.getInstance()\n' \
  >"${r}/android/app/src/main/java/com/openburnbar/data/Bar.kt"
write_baseline "${r}" 0 1 1
assert_exit 0 "${r}" "commented-out raw calls are not counted"

# ── A decrease below baseline passes and reports the drop ─────────────────────
r="$(new_repo)"
# Only the exempt gateways hold raw handles → live is 0/0, under baseline 1/1/2.
write_baseline "${r}" 1 1 2
assert_exit 0 "${r}" "a decrease below baseline passes (shrink-only)"
assert_stdout_contains "${r}" "dropped" "reports the drop as a notice"

# ── Missing baseline fails closed ─────────────────────────────────────────────
r="$(new_repo)"
printf 'let db = Firestore.firestore()\n' >"${r}/AgentLens/Services/Foo.swift"
assert_exit 1 "${r}" "missing baseline fails closed"

# ── --print-live emits a machine-readable snapshot ───────────────────────────
r="$(new_repo)"
printf 'let db = Firestore.firestore()\n' >"${r}/AgentLens/Services/Foo.swift"
assert_stdout_contains "${r}" '"total": 1' "--print-live emits the live total" "--print-live"

echo
printf 'passed=%s failed=%s\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
echo "check-raw-firestore-budget self-test: all green"
