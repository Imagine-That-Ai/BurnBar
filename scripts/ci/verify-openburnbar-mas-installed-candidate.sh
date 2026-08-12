#!/usr/bin/env bash

# Verify one installed Mac App Store candidate and record its opaque receipt
# file's presence/hash beside exact App Store Connect processed-build evidence.
# This does not cryptographically validate the receipt or certify store origin.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
artifact_verifier="${OPENBURNBAR_MAS_INSTALLED_ARTIFACT_VERIFIER:-$repo_root/scripts/ci/verify-openburnbar-mas-artifact.sh}"
receipt_verifier="${OPENBURNBAR_MAS_INSTALLED_RECEIPT_VERIFIER:-$repo_root/scripts/ci/verify-openburnbar-mas-installed-receipt.py}"

if [[ $# -ne 4 ]]; then
  echo "usage: $0 INSTALLED_APP EXPECTED_TEAM_ID ASC_PROCESSING_RECEIPT OUTPUT_JSON" >&2
  exit 64
fi

installed_app="$1"
expected_team_id="$2"
processing_receipt="$3"
output_json="$4"

if [[ ! "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ERROR: Expected Apple team ID must be exactly 10 uppercase letters/digits." >&2
  exit 64
fi
if [[ ! -d "$installed_app" || -L "$installed_app" ]]; then
  echo "ERROR: Installed Mac App Store app must be a real bundle: $installed_app" >&2
  exit 66
fi
if [[ ! -f "$processing_receipt" || -L "$processing_receipt" ]]; then
  echo "ERROR: App Store Connect processing receipt must be a real file: $processing_receipt" >&2
  exit 66
fi
if [[ "$output_json" != /* ]]; then
  echo "ERROR: Installed-candidate evidence output must be an absolute path." >&2
  exit 64
fi
if [[ -e "$output_json" || -L "$output_json" ]]; then
  echo "ERROR: Installed-candidate evidence output must not already exist: $output_json" >&2
  exit 66
fi
output_parent="$(dirname "$output_json")"
if [[ ! -d "$output_parent" || -L "$output_parent" ]]; then
  echo "ERROR: Installed-candidate evidence parent must be a real existing directory: $output_parent" >&2
  exit 66
fi
for required_file in "$artifact_verifier" "$receipt_verifier"; do
  if [[ ! -f "$required_file" || -L "$required_file" ]]; then
    echo "ERROR: Installed-candidate verifier dependency must be a real file: $required_file" >&2
    exit 66
  fi
done

bash "$artifact_verifier" "$installed_app" "$expected_team_id"
python3 "$receipt_verifier" \
  --app "$installed_app" \
  --processing-receipt "$processing_receipt" \
  --output "$output_json"

if [[ ! -f "$output_json" || -L "$output_json" ]]; then
  echo "ERROR: Installed-candidate verifier did not create real evidence: $output_json" >&2
  exit 1
fi
if [[ "$(stat -f %Lp "$output_json")" != "600" ]]; then
  echo "ERROR: Installed-candidate evidence must be owner-only mode 0600." >&2
  exit 1
fi

echo "PASS: installed Mac App Store OpenBurnBar is signature/profile checked and bound to exact processed-build plus opaque receipt-file presence/hash evidence."
echo "HOLD: cryptographic/store receipt certification remains unavailable until a repository-native verifier validates the receipt."
echo "Evidence: $output_json"
