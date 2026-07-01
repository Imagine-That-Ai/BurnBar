#!/usr/bin/env bash
#
# Self-test for scripts/debt/check-baseline-monotonic.sh.
#
# Builds throwaway git repos and asserts the gate's exit codes for baseline
# raises vs. shrinks — positive controls that prove the meta-gate actually closes
# the "797 -> 800" bypass (raising a debt baseline in the same PR) and does not
# fire on the legitimate ratchet-down flow. Cases (j)-(l) cover the subtler
# evasions the numeric compare used to miss: seeding a NEW grandfathered entry
# into an existing baseline, stringifying a number so it drops out of the
# comparison, and a non-finite (NaN) budget that slips past every `>`/`<` check.
# Each repo commits a seed baseline on `main`, then mutates the WORKING TREE
# (exactly how the ratchets read budgets), and the gate compares against `main`.
# No network; self-cleaning.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="${here}/check-baseline-monotonic.sh"

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

# write_singleton <repo> <settingsRefs> <staticSingletons> <total> [note]
# A scalar debt baseline, one line of JSON so per-case bumps read cleanly.
write_singleton() {
  printf '{ "settingsAccountSharedReferences": %s, "staticSharedSingletons": %s, "total": %s, "note": "%s" }\n' \
    "$2" "$3" "$4" "${5:-seed}" >"$1/budgets/singleton-baseline.json"
}

# write_swift <repo> <total> <aLines>
# A swift-file-size-shaped baseline whose per-file counts live in a keyed array,
# so a per-entry bump must be caught even when the aggregate `total` is untouched.
write_swift() {
  printf '{ "target": 2000, "total": %s, "files": [ { "path": "AgentLens/A.swift", "lines": %s }, { "path": "AgentLens/B.swift", "lines": 2050 } ] }\n' \
    "$2" "$3" >"$1/budgets/swift-file-size-baseline.json"
}

# new_repo → prints the repo path. Seeds two debt baselines + a source file on `main`.
new_repo() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/cbm-test.XXXXXX")"
  tmp_roots+=("${dir}")
  mkdir -p "${dir}/scripts/debt" "${dir}/budgets" "${dir}/src"
  cp "${gate}" "${dir}/scripts/debt/check-baseline-monotonic.sh"
  chmod +x "${dir}/scripts/debt/check-baseline-monotonic.sh"
  write_singleton "${dir}" 1 56 57
  write_swift "${dir}" 2 2100
  printf 'let x = 1\n' >"${dir}/src/app.swift"
  ( cd "${dir}" \
      && git init -q -b main \
      && git config user.email t@t.t \
      && git config user.name t \
      && git add -A \
      && git commit -qm init )
  printf '%s' "${dir}"
}

# assert_exit <want> <repo> <message>
assert_exit() {
  local want="$1" repo="$2" msg="$3" got
  set +e
  ( cd "${repo}" && bash scripts/debt/check-baseline-monotonic.sh --base main >/dev/null 2>&1 )
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

echo "check-baseline-monotonic self-test"

# ── (control) unchanged tree passes ──────────────────────────────────────────
r="$(new_repo)"
assert_exit 0 "${r}" "clean tree (no baseline change) passes"

# ── (a) baseline RAISED, standalone → fail ───────────────────────────────────
r="$(new_repo)"
write_singleton "${r}" 1 57 58   # staticSharedSingletons 56->57, total 57->58
assert_exit 1 "${r}" "raised baseline (standalone) fails"

# ── (b) baseline DECREASED only → pass ───────────────────────────────────────
r="$(new_repo)"
write_singleton "${r}" 1 55 56   # staticSharedSingletons 56->55, total 57->56
assert_exit 0 "${r}" "decreased baseline only passes"

# ── (c) baseline RAISED + source edited → fail (not standalone) ───────────────
r="$(new_repo)"
write_singleton "${r}" 1 57 58
printf 'let x = 2\n' >"${r}/src/app.swift"
assert_exit 1 "${r}" "raised baseline + source edit fails"

# ── (d) brand-new baseline file (absent on base) → pass (allowed, logged) ─────
r="$(new_repo)"
printf '{ "total": 5 }\n' >"${r}/budgets/new-metric-baseline.json"
assert_exit 0 "${r}" "new baseline file (missing at base) is allowed"

# ── (e) source edited, no baseline change → pass (gate is a no-op) ────────────
r="$(new_repo)"
printf 'let x = 99\n' >"${r}/src/app.swift"
assert_exit 0 "${r}" "source-only change (no baseline touched) passes"

# ── (f) per-file array entry RAISED, aggregate total untouched → fail ─────────
r="$(new_repo)"
write_swift "${r}" 2 2300         # files[path=AgentLens/A.swift].lines 2100->2300, total stays 2
assert_exit 1 "${r}" "per-file array bump is caught even when total is unchanged"

# ── (g) baseline DECREASED + source edited → pass (ratchet-down is allowed) ───
r="$(new_repo)"
write_singleton "${r}" 1 55 56
printf 'let x = 2\n' >"${r}/src/app.swift"
assert_exit 0 "${r}" "decrease + source edit passes (normal ratchet-down)"

# ── (h) one field up, another down in the same file → fail (any raise fails) ──
r="$(new_repo)"
write_singleton "${r}" 0 57 57    # settingsRefs 1->0 (down), staticSingletons 56->57 (up)
assert_exit 1 "${r}" "mixed up/down fails on the raised field (not net)"

# ── (i) note-only baseline edit + source edit → pass (no numeric change) ──────
r="$(new_repo)"
write_singleton "${r}" 1 56 57 "reworded rationale"
printf 'let x = 2\n' >"${r}/src/app.swift"
assert_exit 0 "${r}" "note-only baseline edit + source edit passes"

# ── (j) NEW entry inserted into an EXISTING baseline file → fail ──────────────
# Grandfathered debt: adding AgentLens/C.swift=5000 to the existing swift-file
# baseline (aggregate total untouched) launders a new 5000-line budget in. Only
# a brand-new baseline FILE may introduce entries; seeding one into an existing
# baseline must be rejected.
r="$(new_repo)"
printf '{ "target": 2000, "total": 2, "files": [ { "path": "AgentLens/A.swift", "lines": 2100 }, { "path": "AgentLens/B.swift", "lines": 2050 }, { "path": "AgentLens/C.swift", "lines": 5000 } ] }\n' \
  >"${r}/budgets/swift-file-size-baseline.json"
assert_exit 1 "${r}" "new grandfathered entry in an existing baseline is rejected"

# ── (k) a numeric field replaced by a non-number (stringified "57") → fail ────
# `total` was the number 57 on base; turning it into the string "57" would drop
# it from the numeric comparison and hide the raise from downstream ratchets.
r="$(new_repo)"
printf '{ "settingsAccountSharedReferences": 1, "staticSharedSingletons": 56, "total": "57", "note": "seed" }\n' \
  >"${r}/budgets/singleton-baseline.json"
assert_exit 1 "${r}" "numeric baseline field turned into a string is rejected"

# ── (l) a non-finite baseline number (NaN) → fail ────────────────────────────
# json.loads accepts NaN, and `NaN > 57` / `NaN < 57` are both false, so a NaN
# budget slips past every monotonicity check unless rejected explicitly.
r="$(new_repo)"
printf '{ "settingsAccountSharedReferences": 1, "staticSharedSingletons": 56, "total": NaN, "note": "seed" }\n' \
  >"${r}/budgets/singleton-baseline.json"
assert_exit 1 "${r}" "non-finite (NaN) baseline number is rejected"

echo
printf 'passed=%s failed=%s\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
echo "check-baseline-monotonic self-test: all green"
