#!/usr/bin/env bash
#
# Self-test for scripts/ci/check-privacy-manifest-collected-data.sh.
#
# Builds throwaway .xcprivacy fixtures and asserts the gate's exit codes for
# each failure mode — positive controls that prove the gate actually catches a
# missing/empty/malformed NSPrivacyCollectedDataTypes declaration (not just
# passes vacuously). Also runs the gate against the real repo manifests to prove
# the shipped R-P2 declarations satisfy it. No network; self-cleaning.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="${here}/check-privacy-manifest-collected-data.sh"

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

new_dir() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/pmcd-test.XXXXXX")"
  tmp_roots+=("${dir}")
  printf '%s' "${dir}"
}

# write_manifest <path> — wraps stdin as the body of a plist <dict>.
write_manifest() {
  local path="$1"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    cat
    printf '</dict>\n</plist>\n'
  } >"${path}"
}

# A single well-formed collected-data entry.
well_formed_entry() {
  cat <<'XML'
  <key>NSPrivacyCollectedDataTypes</key>
  <array>
    <dict>
      <key>NSPrivacyCollectedDataType</key>
      <string>NSPrivacyCollectedDataTypeCrashData</string>
      <key>NSPrivacyCollectedDataTypeLinked</key>
      <false/>
      <key>NSPrivacyCollectedDataTypeTracking</key>
      <false/>
      <key>NSPrivacyCollectedDataTypePurposes</key>
      <array>
        <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
      </array>
    </dict>
  </array>
XML
}

# assert_exit <want> <message> -- <gate args...>
assert_exit() {
  local want="$1" msg="$2" got
  shift 2
  [[ "$1" == "--" ]] && shift
  set +e
  bash "${gate}" "$@" >/dev/null 2>&1
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

echo "check-privacy-manifest-collected-data self-test"

# ── Negative control: the real shipped manifests must pass ───────────────────
assert_exit 0 "shipped app manifests declare well-formed collected data" -- \
  "${here}/../../AgentLens/Resources/PrivacyInfo.xcprivacy" \
  "${here}/../../OpenBurnBarMobile/Resources/PrivacyInfo.xcprivacy"

# ── Positive control: a well-formed fixture passes ───────────────────────────
d="$(new_dir)"
well_formed_entry | write_manifest "${d}/ok.xcprivacy"
assert_exit 0 "well-formed fixture passes" -- "${d}/ok.xcprivacy"

# ── Missing NSPrivacyCollectedDataTypes entirely → fail ──────────────────────
d="$(new_dir)"
write_manifest "${d}/missing.xcprivacy" <<'XML'
  <key>NSPrivacyTracking</key>
  <false/>
XML
assert_exit 1 "manifest with no NSPrivacyCollectedDataTypes fails" -- "${d}/missing.xcprivacy"

# ── Empty NSPrivacyCollectedDataTypes array → fail ───────────────────────────
d="$(new_dir)"
write_manifest "${d}/empty.xcprivacy" <<'XML'
  <key>NSPrivacyCollectedDataTypes</key>
  <array/>
XML
assert_exit 1 "empty NSPrivacyCollectedDataTypes array fails" -- "${d}/empty.xcprivacy"

# ── Entry missing NSPrivacyCollectedDataTypePurposes → fail ──────────────────
d="$(new_dir)"
write_manifest "${d}/nopurpose.xcprivacy" <<'XML'
  <key>NSPrivacyCollectedDataTypes</key>
  <array>
    <dict>
      <key>NSPrivacyCollectedDataType</key>
      <string>NSPrivacyCollectedDataTypeProductInteraction</string>
      <key>NSPrivacyCollectedDataTypeLinked</key>
      <true/>
      <key>NSPrivacyCollectedDataTypeTracking</key>
      <false/>
    </dict>
  </array>
XML
assert_exit 1 "entry missing Purposes key fails" -- "${d}/nopurpose.xcprivacy"

# ── Entry with an EMPTY purposes array → fail ────────────────────────────────
d="$(new_dir)"
write_manifest "${d}/emptypurpose.xcprivacy" <<'XML'
  <key>NSPrivacyCollectedDataTypes</key>
  <array>
    <dict>
      <key>NSPrivacyCollectedDataType</key>
      <string>NSPrivacyCollectedDataTypeProductInteraction</string>
      <key>NSPrivacyCollectedDataTypeLinked</key>
      <true/>
      <key>NSPrivacyCollectedDataTypeTracking</key>
      <false/>
      <key>NSPrivacyCollectedDataTypePurposes</key>
      <array/>
    </dict>
  </array>
XML
assert_exit 1 "entry with empty Purposes array fails" -- "${d}/emptypurpose.xcprivacy"

# ── Entry missing the Linked boolean → fail ──────────────────────────────────
d="$(new_dir)"
write_manifest "${d}/nolinked.xcprivacy" <<'XML'
  <key>NSPrivacyCollectedDataTypes</key>
  <array>
    <dict>
      <key>NSPrivacyCollectedDataType</key>
      <string>NSPrivacyCollectedDataTypeCrashData</string>
      <key>NSPrivacyCollectedDataTypeTracking</key>
      <false/>
      <key>NSPrivacyCollectedDataTypePurposes</key>
      <array>
        <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
      </array>
    </dict>
  </array>
XML
assert_exit 1 "entry missing Linked boolean fails" -- "${d}/nolinked.xcprivacy"

# ── Malformed property list → fail (not misconfig) ───────────────────────────
d="$(new_dir)"
printf '<?xml version="1.0"?>\n<plist version="1.0"><dict>\n<key>oops\n' >"${d}/broken.xcprivacy"
assert_exit 1 "malformed plist fails plutil -lint" -- "${d}/broken.xcprivacy"

# ── Missing file path → misconfigured (exit 2) ───────────────────────────────
d="$(new_dir)"
assert_exit 2 "missing manifest path is misconfigured" -- "${d}/does-not-exist.xcprivacy"

# ── One bad manifest among several still fails ───────────────────────────────
d="$(new_dir)"
well_formed_entry | write_manifest "${d}/ok.xcprivacy"
write_manifest "${d}/bad.xcprivacy" <<'XML'
  <key>NSPrivacyCollectedDataTypes</key>
  <array/>
XML
assert_exit 1 "a single empty manifest fails a mixed batch" -- "${d}/ok.xcprivacy" "${d}/bad.xcprivacy"

echo
printf 'passed=%s failed=%s\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]] || exit 1
echo "check-privacy-manifest-collected-data self-test: all green"
