#!/usr/bin/env bash
# Verify Sigstore blob attestations for published OpenBurnBar release assets.
set -euo pipefail
cd "$(dirname "$0")/../.."

usage() {
  cat <<'EOF'
Usage: scripts/ci/verify-release-attestations.sh <tag> [asset-glob ...]

Examples:
  scripts/ci/verify-release-attestations.sh v1.0.5
  scripts/ci/verify-release-attestations.sh v1.0.5 '*macOS.dmg' '*macOS.zip'

Verifies each matching GitHub Release asset with cosign verify-blob-attestation,
pinned by default to:
  - repo: Imagine-That-Ai/BurnBar
  - signer identity: https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/release.yml@refs/tags/<tag>
  - OIDC issuer: https://token.actions.githubusercontent.com

Override identity/issuer/type with:
  OPENBURNBAR_RELEASE_CERTIFICATE_IDENTITY
  OPENBURNBAR_RELEASE_CERTIFICATE_OIDC_ISSUER
  OPENBURNBAR_RELEASE_PREDICATE_TYPE
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

tag="${1:-}"
if [[ -z "$tag" ]]; then
  usage >&2
  exit 2
fi
shift || true

repo="${OPENBURNBAR_GITHUB_REPO:-Imagine-That-Ai/BurnBar}"
version="${tag#v}"
predicate_type="${OPENBURNBAR_RELEASE_PREDICATE_TYPE:-https://openburnbar.dev/attestations/release-artifact/v1}"
certificate_identity="${OPENBURNBAR_RELEASE_CERTIFICATE_IDENTITY:-https://github.com/${repo}/.github/workflows/release.yml@refs/tags/${tag}}"
certificate_issuer="${OPENBURNBAR_RELEASE_CERTIFICATE_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"

if ! command -v gh >/dev/null 2>&1; then
  echo "FAIL: gh CLI is required." >&2
  exit 1
fi

if ! command -v cosign >/dev/null 2>&1; then
  echo "FAIL: cosign CLI is required." >&2
  exit 1
fi

patterns=("$@")
if [[ "${#patterns[@]}" -eq 0 ]]; then
  patterns=(
    "*macOS.dmg"
    "*macOS.zip"
    "checksums-v${version}.txt"
    "sbom-v${version}.spdx.json"
    "openburnbar-v${version}.vex.json"
    "OpenBurnBar-${version}-corresponding-source.tar.gz"
    "appcast.xml"
    "latest-macos.json"
  )
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-release-attest.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

downloaded=0
download_pattern() {
  local pattern="$1"
  before_count="$(find "$tmp_dir" -type f | wc -l | tr -d ' ')"
  gh release download "$tag" --repo "$repo" --pattern "$pattern" --dir "$tmp_dir" --clobber >/dev/null 2>&1 || true
  after_count="$(find "$tmp_dir" -type f | wc -l | tr -d ' ')"
  if [[ "$after_count" -eq "$before_count" ]]; then
    echo "WARN: no release assets matched pattern '$pattern' for $tag" >&2
  fi
}

for pattern in "${patterns[@]}"; do
  download_pattern "$pattern"
done

download_pattern "*.sigstore.json"
download_pattern "*.predicate.json"

while IFS= read -r -d '' asset; do
  case "$asset" in
    *.sigstore.json|*.predicate.json|*.asc|*.sha256)
      continue
      ;;
  esac

  downloaded=$((downloaded + 1))
  asset_name="$(basename "$asset")"
  safe_name="$(python3 - "$asset_name" <<'PY'
import re
import sys

print(re.sub(r"[^A-Za-z0-9._-]", "_", sys.argv[1]))
PY
)"
  bundle_path="$(find "$tmp_dir" -type f -name "${safe_name}.sigstore.json" -print -quit 2>/dev/null)"
  predicate_path="$(find "$tmp_dir" -type f -name "${safe_name}.predicate.json" -print -quit 2>/dev/null)"

  if [[ -z "$bundle_path" || ! -f "$bundle_path" ]]; then
    echo "FAIL: missing Sigstore bundle for $asset_name (${safe_name}.sigstore.json)." >&2
    exit 1
  fi
  if [[ -z "$predicate_path" || ! -f "$predicate_path" ]]; then
    echo "FAIL: missing release predicate for $asset_name (${safe_name}.predicate.json)." >&2
    exit 1
  fi

  echo "==> verifying Sigstore blob attestation: $asset_name"
  cosign verify-blob-attestation \
    --bundle "$bundle_path" \
    --type "$predicate_type" \
    --certificate-identity "$certificate_identity" \
    --certificate-oidc-issuer "$certificate_issuer" \
    "$asset" >/dev/null

  python3 - "$asset" "$predicate_path" "$tag" "$version" "$repo" "$predicate_type" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

asset = Path(sys.argv[1])
predicate = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
tag = sys.argv[3]
version = sys.argv[4]
repo = sys.argv[5]
predicate_type = sys.argv[6]
actual_sha256 = hashlib.sha256(asset.read_bytes()).hexdigest()

expected = {
    "predicateType": predicate_type,
    "artifact.fileName": asset.name,
    "artifact.sha256": actual_sha256,
    "artifact.sizeBytes": asset.stat().st_size,
    "release.version": version,
    "release.repository": repo,
    "release.ref": f"refs/tags/{tag}",
}

checks = {
    "predicateType": predicate.get("predicateType"),
    "artifact.fileName": predicate.get("artifact", {}).get("fileName"),
    "artifact.sha256": predicate.get("artifact", {}).get("sha256"),
    "artifact.sizeBytes": predicate.get("artifact", {}).get("sizeBytes"),
    "release.version": predicate.get("release", {}).get("version"),
    "release.repository": predicate.get("release", {}).get("repository"),
    "release.ref": predicate.get("release", {}).get("ref"),
}

for key, want in expected.items():
    got = checks.get(key)
    if got != want:
        raise SystemExit(f"{asset.name}: predicate {key} mismatch: got {got!r}, want {want!r}")
PY
done < <(find "$tmp_dir" -type f -print0)

if [[ "$downloaded" -eq 0 ]]; then
  echo "FAIL: no release assets downloaded for $tag." >&2
  exit 1
fi

echo "PASS: verified Sigstore blob attestations for $downloaded release asset(s) from $tag"
