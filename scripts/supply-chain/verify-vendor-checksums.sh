#!/usr/bin/env bash
# Verify the checksum manifest for tracked Vendor binary artifacts.
#
# Usage:
#   scripts/supply-chain/verify-vendor-checksums.sh
#   scripts/supply-chain/verify-vendor-checksums.sh \
#     --manifest /path/to/CHECKSUMS.sha256 --dir /path/to/Vendor
#
# The optional manifest/dir pair keeps the exact verification path testable
# against a tampered temporary copy without changing the checked-in Vendor tree.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${ROOT_DIR}/Vendor/CHECKSUMS.sha256"
BASE_DIR="${ROOT_DIR}/Vendor"

usage() {
  cat <<'EOF'
Usage: scripts/supply-chain/verify-vendor-checksums.sh [--manifest PATH] [--dir PATH]

Verify every SHA-256 entry in the Vendor checksum manifest, and that every
Vendor binary has an entry.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --manifest)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 64; }
      MANIFEST="$2"
      shift 2
      ;;
    --dir)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 64; }
      BASE_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

[[ -f "${MANIFEST}" ]] || {
  echo "FAIL: checksum manifest is missing: ${MANIFEST}" >&2
  exit 1
}
[[ -d "${BASE_DIR}" ]] || {
  echo "FAIL: checksum base directory is missing: ${BASE_DIR}" >&2
  exit 1
}
command -v shasum >/dev/null 2>&1 || {
  echo "FAIL: shasum is required to verify Vendor checksums." >&2
  exit 1
}

# shellcheck source=scripts/supply-chain/vendor-binaries.sh
source "${ROOT_DIR}/scripts/supply-chain/vendor-binaries.sh"

seen_paths=()
expected_digests=()
entry_count=0
while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ -z "${line//[[:space:]]/}" ]] && continue
  [[ "${line}" == \#* ]] && continue

  if [[ ! "${line}" =~ ^[0-9A-Fa-f]{64}[[:space:]]{2}(\*?)([^[:space:]]+)$ ]]; then
    echo "FAIL: malformed checksum manifest line: ${line}" >&2
    exit 1
  fi
  relative_path="${BASH_REMATCH[2]}"
  case "${relative_path}" in
    /*|.|./*|../*|*/../*|*/..)
      echo "FAIL: checksum path escapes its base directory: ${relative_path}" >&2
      exit 1
      ;;
  esac
  digest="${BASH_REMATCH[0]%%[[:space:]]*}"
  if ((${#seen_paths[@]} > 0)); then
    for seen_path in "${seen_paths[@]}"; do
      if [[ "${seen_path}" == "${relative_path}" ]]; then
        echo "FAIL: duplicate checksum entry: ${relative_path}" >&2
        exit 1
      fi
    done
  fi
  seen_paths+=("${relative_path}")
  expected_digests+=("${digest}")
  entry_count=$((entry_count + 1))
done < "${MANIFEST}"

if [[ "${entry_count}" -eq 0 ]]; then
  echo "FAIL: checksum manifest has no entries: ${MANIFEST}" >&2
  exit 1
fi

# Coverage: every binary under the Vendor directory must have an entry. Entries
# without a binary are rejected below as missing targets, so the manifest and
# the tree can drift in neither direction.
uncovered=()
while IFS= read -r tracked_path; do
  [[ -n "${tracked_path}" ]] || continue
  covered=false
  for seen_path in "${seen_paths[@]}"; do
    if [[ "${seen_path}" == "${tracked_path}" || "${seen_path}" == "Vendor/${tracked_path}" ]]; then
      covered=true
      break
    fi
  done
  if [[ "${covered}" != "true" ]]; then
    uncovered+=("${tracked_path}")
  fi
done < <(list_vendor_binaries "${BASE_DIR}")
if ((${#uncovered[@]} > 0)); then
  echo "FAIL: Vendor binaries without a checksum entry: ${uncovered[*]}" >&2
  echo "      Regenerate with scripts/supply-chain/refresh-vendor-checksums.sh" >&2
  exit 1
fi

verified=0
for index in "${!expected_digests[@]}"; do
  relative_path="${seen_paths[${index}]}"
  candidate="${BASE_DIR}/${relative_path}"
  if [[ ! -f "${candidate}" && "${relative_path}" == Vendor/* ]]; then
    candidate="${BASE_DIR}/${relative_path#Vendor/}"
  fi
  if [[ ! -f "${candidate}" ]]; then
    echo "FAIL: checksum target is missing: ${relative_path}" >&2
    exit 1
  fi

  expected="${expected_digests[${index}]}"
  actual="$(shasum -a 256 "${candidate}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL: checksum mismatch: ${relative_path}" >&2
    echo "      expected ${expected}" >&2
    echo "      actual   ${actual}" >&2
    exit 1
  fi
  echo "${actual}  ${relative_path}"
  verified=$((verified + 1))
done

echo "PASS: verified ${verified} Vendor checksum entries"
