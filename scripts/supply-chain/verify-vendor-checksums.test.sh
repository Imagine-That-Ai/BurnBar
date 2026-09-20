#!/usr/bin/env bash
# Negative and idempotence controls for the Vendor checksum manifest tooling.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

VERIFY=scripts/supply-chain/verify-vendor-checksums.sh
REFRESH=scripts/supply-chain/refresh-vendor-checksums.sh
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-vendor-checksums.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. The checked-in tree passes.
bash "${VERIFY}" >/dev/null || fail "checked-in Vendor manifest did not verify"

# 2. Fixture: two binaries with a fresh manifest verify, and refresh is idempotent.
fixture="${TMP_DIR}/Vendor"
mkdir -p "${fixture}/nested"
printf 'aar-one' >"${fixture}/one.aar"
printf 'jar-two' >"${fixture}/nested/two.jar"
bash "${REFRESH}" --dir "${fixture}" >/dev/null
bash "${VERIFY}" --dir "${fixture}" --manifest "${fixture}/CHECKSUMS.sha256" >/dev/null || fail "fresh fixture manifest did not verify"
before="$(cat "${fixture}/CHECKSUMS.sha256")"
bash "${REFRESH}" --dir "${fixture}" | grep -q '^unchanged:' || fail "refresh rewrote an already-canonical manifest"
[[ "$(cat "${fixture}/CHECKSUMS.sha256")" == "${before}" ]] || fail "refresh was not idempotent"
grep -q '^[0-9a-f]\{64\}  nested/two.jar$' "${fixture}/CHECKSUMS.sha256" || fail "nested binary missing from manifest"

# 3. A tampered digest fails.
sed 's/^\([0-9a-f]\{63\}\)[0-9a-f]  one.aar$/\10  one.aar/' "${fixture}/CHECKSUMS.sha256" | sed 's/^0\([0-9a-f]\{63\}\)  one.aar$/1\1  one.aar/' >"${TMP_DIR}/tampered.sha256"
if bash "${VERIFY}" --dir "${fixture}" --manifest "${TMP_DIR}/tampered.sha256" >/dev/null 2>"${TMP_DIR}/tampered.err"; then
  fail "tampered digest was accepted"
fi
grep -q 'checksum mismatch' "${TMP_DIR}/tampered.err" || fail "tampered digest refusal did not name the mismatch"

# 4. A binary without an entry fails (coverage).
printf 'aar-three' >"${fixture}/three.aar"
if bash "${VERIFY}" --dir "${fixture}" --manifest "${fixture}/CHECKSUMS.sha256" >/dev/null 2>"${TMP_DIR}/uncovered.err"; then
  fail "binary without a checksum entry was accepted"
fi
grep -q 'without a checksum entry: three.aar' "${TMP_DIR}/uncovered.err" || fail "coverage refusal did not name the binary"
rm "${fixture}/three.aar"

# 5. An entry without a binary fails.
printf '%s  ghost.aar\n' "$(printf 'x' | shasum -a 256 | awk '{print $1}')" >>"${fixture}/CHECKSUMS.sha256"
if bash "${VERIFY}" --dir "${fixture}" --manifest "${fixture}/CHECKSUMS.sha256" >/dev/null 2>"${TMP_DIR}/ghost.err"; then
  fail "entry without a binary was accepted"
fi
grep -q 'checksum target is missing: ghost.aar' "${TMP_DIR}/ghost.err" || fail "ghost entry refusal did not name the entry"

echo "PASS: vendor checksum manifest controls"
