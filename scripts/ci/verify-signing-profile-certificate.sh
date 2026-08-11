#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ $# -ne 2 && $# -ne 4 ]]; then
  echo "usage: $0 SIGNED_BUNDLE PROVISIONING_PROFILE [ARTIFACT_SHA256 RELEASE_VERSION]" >&2
  exit 2
fi

signed_bundle="$1"
profile="$2"
artifact_sha256="${3:-}"
release_version="${4:-}"
if [[ ! -e "$signed_bundle" ]]; then
  echo "ERROR: Signed bundle does not exist: $signed_bundle" >&2
  exit 1
fi
if [[ ! -f "$profile" ]]; then
  echo "ERROR: Provisioning profile does not exist: $profile" >&2
  exit 1
fi

signed_bundle="$(cd "$(dirname "$signed_bundle")" && pwd)/$(basename "$signed_bundle")"
profile="$(cd "$(dirname "$profile")" && pwd)/$(basename "$profile")"
tmp_root="${TMPDIR:-/tmp}"
if ! work_dir="$(mktemp -d "$tmp_root/openburnbar-signing-profile.XXXXXX" 2>/dev/null)"; then
  work_dir="$(mktemp -d "/tmp/openburnbar-signing-profile.XXXXXX")"
fi
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

security cms -D -i "$profile" > "$work_dir/profile.plist"
(
  cd "$work_dir"
  codesign -d --extract-certificates "$signed_bundle" >/dev/null 2>&1
)
if [[ ! -f "$work_dir/codesign0" ]]; then
  echo "ERROR: codesign did not expose the bundle's leaf signing certificate." >&2
  exit 1
fi

verifier_args=(
  "$work_dir/profile.plist"
  "$work_dir/codesign0"
)
if [[ $# -eq 4 ]]; then
  verifier_args+=(
    --artifact-sha256 "$artifact_sha256"
    --release-version "$release_version"
  )
fi

python3 "$repo_root/scripts/ci/verify-signing-profile-certificate.py" "${verifier_args[@]}"
