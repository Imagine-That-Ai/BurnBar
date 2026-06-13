#!/usr/bin/env bash
# Verify GitHub/Sigstore attestations for published OpenBurnBar release assets.
set -euo pipefail
cd "$(dirname "$0")/../.."

usage() {
  cat <<'EOF'
Usage: scripts/ci/verify-release-attestations.sh <tag> [asset-glob ...]

Examples:
  scripts/ci/verify-release-attestations.sh v0.1.3-beta.1
  scripts/ci/verify-release-attestations.sh v0.1.3-beta.1 '*macOS.dmg' '*macOS.zip'

Verifies each matching GitHub Release asset with gh attestation verify, pinned to:
  - repo: Imagine-That-Ai/BurnBar
  - signer workflow: .github/workflows/release.yml
  - source ref: refs/tags/<tag>
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
signer_workflow="${OPENBURNBAR_RELEASE_SIGNER_WORKFLOW:-github.com/${repo}/.github/workflows/release.yml}"
source_ref="${OPENBURNBAR_RELEASE_SOURCE_REF:-refs/tags/${tag}}"

if ! command -v gh >/dev/null 2>&1; then
  echo "FAIL: gh CLI is required." >&2
  exit 1
fi

patterns=("$@")
if [[ "${#patterns[@]}" -eq 0 ]]; then
  patterns=("*macOS.dmg" "*macOS.zip" "*checksums.txt" "*source*.tar.gz" "appcast.xml" "latest.json")
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-release-attest.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

downloaded=0
for pattern in "${patterns[@]}"; do
  before_count="$(find "$tmp_dir" -type f | wc -l | tr -d ' ')"
  gh release download "$tag" --repo "$repo" --pattern "$pattern" --dir "$tmp_dir" --clobber >/dev/null 2>&1 || true
  after_count="$(find "$tmp_dir" -type f | wc -l | tr -d ' ')"
  if [[ "$after_count" -eq "$before_count" ]]; then
    echo "WARN: no release assets matched pattern '$pattern' for $tag" >&2
  fi
done

while IFS= read -r -d '' asset; do
  downloaded=$((downloaded + 1))
  echo "==> verifying attestation: $(basename "$asset")"
  gh attestation verify "$asset" \
    --repo "$repo" \
    --signer-workflow "$signer_workflow" \
    --source-ref "$source_ref" \
    --deny-self-hosted-runners \
    --format json >/dev/null
done < <(find "$tmp_dir" -type f -print0)

if [[ "$downloaded" -eq 0 ]]; then
  echo "FAIL: no release assets downloaded for $tag." >&2
  exit 1
fi

echo "PASS: verified GitHub/Sigstore attestations for $downloaded release asset(s) from $tag"
