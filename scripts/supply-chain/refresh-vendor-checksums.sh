#!/usr/bin/env bash
# Rewrite Vendor/CHECKSUMS.sha256 canonically: one SHA-256 line per tracked
# Vendor binary, sorted by path, written in place. Run it after re-vendoring an
# AAR; the fast-feedback lane verifies the manifest on every PR.
#
# It is deliberately NOT called from the AAR build scripts: those scripts are
# part of each AAR's build-recipe fingerprint, so editing them forces a rebuild
# of every AAR, and a CI build lane that rewrote the manifest would dirty the
# candidate checkout that the domain-core promotion proof requires to be clean.
#
# Usage:
#   scripts/supply-chain/refresh-vendor-checksums.sh
#   scripts/supply-chain/refresh-vendor-checksums.sh --dir /path/to/Vendor --manifest /path/to/CHECKSUMS.sha256

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_DIR="${ROOT_DIR}/Vendor"
MANIFEST=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dir) [[ "$#" -ge 2 ]] || exit 64; BASE_DIR="$2"; shift 2 ;;
    --manifest) [[ "$#" -ge 2 ]] || exit 64; MANIFEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 64 ;;
  esac
done
[[ -n "${MANIFEST}" ]] || MANIFEST="${BASE_DIR}/CHECKSUMS.sha256"
[[ -d "${BASE_DIR}" ]] || { echo "FAIL: vendor directory is missing: ${BASE_DIR}" >&2; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "FAIL: shasum is required." >&2; exit 1; }

# shellcheck source=scripts/supply-chain/vendor-binaries.sh
source "${ROOT_DIR}/scripts/supply-chain/vendor-binaries.sh"

tmp="$(mktemp "${MANIFEST}.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
{
  echo "# SHA-256 checksums for tracked Vendor binary artifacts."
  echo "# Paths are relative to this Vendor directory. Regenerate with"
  echo "#   scripts/supply-chain/refresh-vendor-checksums.sh"
  echo "# after re-vendoring an AAR; scripts/supply-chain/verify-vendor-checksums.sh"
  echo "# fails on any binary without an entry, any entry without a binary, and any drift."
  while IFS= read -r relative_path; do
    [[ -n "${relative_path}" ]] || continue
    digest="$(shasum -a 256 "${BASE_DIR}/${relative_path}" | awk '{print $1}')"
    printf '%s  %s\n' "${digest}" "${relative_path}"
  done < <(list_vendor_binaries "${BASE_DIR}")
} > "${tmp}"

if [[ -f "${MANIFEST}" ]] && cmp -s "${tmp}" "${MANIFEST}"; then
  echo "unchanged: ${MANIFEST}"
else
  mv "${tmp}" "${MANIFEST}"
  trap - EXIT
  echo "wrote: ${MANIFEST}"
fi
