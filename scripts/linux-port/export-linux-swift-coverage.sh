#!/usr/bin/env bash
# Merge current-run LLVM profiles and export exact Swift package line evidence.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ "$#" -lt 4 ]]; then
  echo "usage: $0 <profile-dir> <lcov-output> <lines-output> <coverage-binary> [coverage-binary ...]" >&2
  exit 2
fi

profile_dir="$1"
lcov_output="$2"
lines_output="$3"
shift 3
coverage_binaries=("$@")

profiles=()
while IFS= read -r profile; do
  profiles+=("$profile")
done < <(find "$profile_dir" -type f -name '*.profraw' -size +0c -print | sort)
if [[ "${#profiles[@]}" -eq 0 ]]; then
  echo "FAIL: Linux coverage run produced no non-empty LLVM profiles in $profile_dir" >&2
  exit 1
fi

for index in "${!coverage_binaries[@]}"; do
  binary="${coverage_binaries[$index]}"
  if [[ ! -f "$binary" || ! -x "$binary" ]]; then
    echo "FAIL: coverage-owner XCTest binary is missing or not executable: $binary" >&2
    exit 1
  fi
  for ((previous = 0; previous < index; previous += 1)); do
    if [[ "${coverage_binaries[$previous]}" == "$binary" ]]; then
      echo "FAIL: duplicate coverage-owner XCTest binary: $binary" >&2
      exit 1
    fi
  done
done

mkdir -p "$(dirname "$lcov_output")" "$(dirname "$lines_output")"
rm -f "$lcov_output" "$lines_output"
merged_profile="$profile_dir/merged.profdata"
"${LLVM_PROFDATA_BIN:-llvm-profdata}" merge -sparse "${profiles[@]}" -o "$merged_profile"

primary_binary="${coverage_binaries[0]}"
coverage_objects=()
for binary in "${coverage_binaries[@]:1}"; do
  coverage_objects+=(-object "$binary")
done

lcov_tmp="${lcov_output}.tmp.$$.lcov"
lines_tmp="${lines_output}.tmp.$$"
cleanup() { rm -f "$lcov_tmp" "$lines_tmp"; }
trap cleanup EXIT

set +e
"${LLVM_COV_BIN:-llvm-cov}" export -format=lcov \
  "$primary_binary" "${coverage_objects[@]}" \
  -instr-profile="$merged_profile" > "$lcov_tmp"
llvm_cov_status=$?
set -e
if [[ "$llvm_cov_status" -ne 0 ]]; then
  echo "FAIL: llvm-cov export failed for current coverage-owner binaries" >&2
  exit 1
fi
if [[ ! -s "$lcov_tmp" ]]; then
  echo "FAIL: llvm-cov produced an empty Linux LCOV trace" >&2
  exit 1
fi

OPENBURNBAR_COVERAGE_REPO_ROOT="$ROOT" \
  "$ROOT/scripts/extract-package-coverage-lines.sh" "$lcov_tmp" > "$lines_tmp"
python3 - "$lines_tmp" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
if not isinstance(payload.get("files"), dict) or not payload["files"]:
    raise SystemExit("Linux LCOV conversion produced no per-line file evidence")
PY

mv "$lcov_tmp" "$lcov_output"
mv "$lines_tmp" "$lines_output"
trap - EXIT
