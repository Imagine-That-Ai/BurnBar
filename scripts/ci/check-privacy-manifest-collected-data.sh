#!/usr/bin/env bash
#
# Privacy manifest collected-data gate (R-P2).
#
# Fail-closed, dependency-free (plutil only) guard that the App Store privacy
# manifests for the shipping app targets declare a non-empty, well-formed
# NSPrivacyCollectedDataTypes array.
#
# The apps bundle analytics + crash + identity SDKs — Amplitude
# (product-interaction analytics + a per-install device id), Sentry (crash +
# diagnostic data), and Firebase Auth (an account user id) — that transmit data
# off-device. A manifest with no NSPrivacyCollectedDataTypes ships an inaccurate
# privacy "nutrition label" and is rejected during App Store processing. This
# gate locks the R-P2 remediation so an app manifest cannot silently regress to
# declaring "collects nothing" while those SDKs stay linked.
#
# Each checked manifest must:
#   1. be a valid property list (plutil -lint);
#   2. contain a non-empty NSPrivacyCollectedDataTypes array;
#   3. give every entry a non-empty NSPrivacyCollectedDataType, an explicit
#      NSPrivacyCollectedDataTypeLinked and NSPrivacyCollectedDataTypeTracking
#      value, and a non-empty NSPrivacyCollectedDataTypePurposes array.
#
# It intentionally does NOT assert a specific data-type taxonomy: the accurate
# set is decided in the manifest itself (grounded in each SDK's own bundled
# privacy manifest), and this gate only guarantees the class is present and
# structurally complete.
#
# Usage:  check-privacy-manifest-collected-data.sh [manifest.xcprivacy ...]
#         (no args → the shipping app-target manifests)
# Exit:   0 = every manifest declares accurate, well-formed collected data;
#         1 = a manifest is malformed, empty, or missing required entry keys;
#         2 = misconfigured (a listed manifest is missing, or plutil is absent).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"

# Shipping app targets whose PrivacyInfo.xcprivacy feed the App Store privacy
# report. Extending coverage is a one-line edit here.
DEFAULT_MANIFESTS=(
  "${repo_root}/AgentLens/Resources/PrivacyInfo.xcprivacy"
  "${repo_root}/OpenBurnBarMobile/Resources/PrivacyInfo.xcprivacy"
)

# Keys Apple requires on every NSPrivacyCollectedDataTypes entry.
REQUIRED_ENTRY_KEYS=(
  NSPrivacyCollectedDataType
  NSPrivacyCollectedDataTypeLinked
  NSPrivacyCollectedDataTypeTracking
  NSPrivacyCollectedDataTypePurposes
)

if ! command -v plutil >/dev/null 2>&1; then
  echo "MISCONFIGURED: plutil not found (macOS / Xcode command line tools required)." >&2
  exit 2
fi

if [[ "$#" -gt 0 ]]; then
  manifests=("$@")
else
  manifests=("${DEFAULT_MANIFESTS[@]}")
fi

violations=0
note_fail() {
  echo "  ✗ $1" >&2
  violations=$((violations + 1))
}
note_ok() { echo "  ✓ $1"; }

# raw-extract a key path; empty string + non-zero on a missing path.
extract() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
# true when the key path resolves to a value (used for presence checks).
has_path() { plutil -extract "$1" raw -o - "$2" >/dev/null 2>&1; }

echo "Privacy manifest collected-data gate (R-P2)"
echo

for manifest in "${manifests[@]}"; do
  rel="${manifest#"${repo_root}"/}"

  if [[ ! -f "${manifest}" ]]; then
    echo "MISCONFIGURED: manifest not found: ${manifest}" >&2
    exit 2
  fi

  if ! plutil -lint "${manifest}" >/dev/null 2>&1; then
    note_fail "${rel}: not a valid property list (plutil -lint failed)"
    continue
  fi

  # `plutil -extract <array> raw` prints the element count; a missing key or a
  # non-array value yields a non-numeric/empty result.
  count="$(extract NSPrivacyCollectedDataTypes "${manifest}" || true)"
  if ! [[ "${count}" =~ ^[0-9]+$ ]]; then
    note_fail "${rel}: NSPrivacyCollectedDataTypes is missing or not an array — the bundled Amplitude/Sentry/Firebase SDKs collect data off-device, so this class must be declared"
    continue
  fi
  if [[ "${count}" -eq 0 ]]; then
    note_fail "${rel}: NSPrivacyCollectedDataTypes is an empty array — declare the data types the bundled SDKs collect"
    continue
  fi

  entry_problem=0
  for ((i = 0; i < count; i++)); do
    for key in "${REQUIRED_ENTRY_KEYS[@]}"; do
      if ! has_path "NSPrivacyCollectedDataTypes.${i}.${key}" "${manifest}"; then
        note_fail "${rel}: entry #${i} is missing required key ${key}"
        entry_problem=1
      fi
    done

    dtype="$(extract "NSPrivacyCollectedDataTypes.${i}.NSPrivacyCollectedDataType" "${manifest}" || true)"
    if [[ -z "${dtype}" ]]; then
      note_fail "${rel}: entry #${i} has an empty NSPrivacyCollectedDataType string"
      entry_problem=1
    fi

    # Purposes must name at least one purpose (index 0 must resolve).
    if ! has_path "NSPrivacyCollectedDataTypes.${i}.NSPrivacyCollectedDataTypePurposes.0" "${manifest}"; then
      note_fail "${rel}: entry #${i} (${dtype:-unknown}) has an empty NSPrivacyCollectedDataTypePurposes array — every collected type needs at least one purpose"
      entry_problem=1
    fi
  done

  if [[ "${entry_problem}" -eq 0 ]]; then
    note_ok "${rel}: ${count} collected data type(s) declared, all well-formed"
  fi
done

echo
if [[ "${violations}" -gt 0 ]]; then
  echo "Privacy manifest collected-data gate FAILED (${violations} violation(s))." >&2
  echo "Populate NSPrivacyCollectedDataTypes to match the bundled SDKs (R-P2)." >&2
  exit 1
fi
echo "Privacy manifest collected-data gate PASSED."
exit 0
