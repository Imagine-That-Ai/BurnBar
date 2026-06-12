#!/usr/bin/env bash
# Extract per-file line coverage from SwiftPM package coverage artifacts.
#
# `swift test --enable-code-coverage` leaves two artifacts per package:
#   <pkg>/.build/{debug|<triple>/debug}/codecov/default.profdata
#   <pkg>/.build/{debug|<triple>/debug}/<Pkg>PackageTests.xctest
# This script pairs them and asks llvm-cov itself for per-line truth:
#
#   xcrun llvm-cov export -format=lcov <test-binary> -instr-profile=<profdata>
#
# then converts the LCOV `SF:`/`DA:` records into the same per-line map shape
# scripts/extract-coverage-lines.sh emits for xcresult bundles, so
# scripts/diff-coverage.sh can merge both evidence sources:
#
#   { "files": { "relative/path/File.swift": { "lines": { "42": true } } } }
#
# WHY LCOV AND NOT THE codecov/*.json EXPORT: the JSON carries raw coverage
# SEGMENTS, and turning segments into per-line counts requires reimplementing
# LLVM's LineCoverageStats heuristics (wrapped-segment precedence, gap
# regions, mid-line zero-count region entries). A previous hand-port of that
# algorithm silently under-reported hits on exactly the `guard … else` /
# `} catch {` shapes our security code is full of (its count selection
# predated current llvm-cov: it let a zero-count region opening mid-line
# override an executed wrapped region). `-format=lcov` is computed by
# llvm-cov's own LineCoverageIterator, so it cannot drift from
# `xcrun llvm-cov report` semantics. Do not "optimize" this back to a
# segment-walking port.
#
# Usage:
#   scripts/extract-package-coverage-lines.sh [input ...]
#
# Each input may be:
#   * a package directory (artifacts are discovered under .build/)
#   * a pre-generated .lcov file (self-test fixtures)
#
# With no arguments, looks for OpenBurnBarCore and OpenBurnBarDaemon
# artifacts. Multiple inputs are merged: a line is covered when any package's
# test run hit it (e.g. Core sources exercised by Daemon tests).
#
# Environment:
#   OPENBURNBAR_COVERAGE_REPO_ROOT  override repo root (self-tests only)

set -euo pipefail

scripts_dir="$(cd "$(dirname "$0")" && pwd)"
default_root="$(cd "$scripts_dir/.." && pwd)"
repo_root="${OPENBURNBAR_COVERAGE_REPO_ROOT:-$default_root}"

inputs=("$@")
if [[ ${#inputs[@]} -eq 0 ]]; then
  inputs=("$repo_root/OpenBurnBarCore" "$repo_root/OpenBurnBarDaemon")
fi

llvm_cov() {
  if command -v xcrun >/dev/null 2>&1; then
    xcrun llvm-cov "$@"
  else
    llvm-cov "$@"
  fi
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-package-coverage.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

# Resolve every input to one or more LCOV trace files.
lcov_paths=()
export_index=0
for input in "${inputs[@]}"; do
  if [[ -f "$input" && "$input" == *.lcov ]]; then
    lcov_paths+=("$input")
    continue
  fi
  if [[ ! -d "$input" ]]; then
    # Relative package dir given from elsewhere — try under the repo root.
    if [[ -d "$repo_root/$input" ]]; then
      input="$repo_root/$input"
    else
      echo "::warning::package coverage input not found: $input" >&2
      continue
    fi
  fi

  # `.build/debug` is usually a symlink to `.build/<triple>/debug`; resolve
  # real paths and dedupe so each artifact is exported exactly once.
  profdata=""
  for candidate in "$input"/.build/debug/codecov/default.profdata \
                   "$input"/.build/*/debug/codecov/default.profdata; do
    if [[ -f "$candidate" ]]; then
      profdata="$(cd "$(dirname "$candidate")" && pwd -P)/default.profdata"
      break
    fi
  done
  if [[ -z "$profdata" ]]; then
    echo "::warning::no merged profdata under $input/.build — run \`swift test --enable-code-coverage\` there first." >&2
    continue
  fi

  test_binaries=()
  for bundle in "$input"/.build/debug/*.xctest "$input"/.build/*/debug/*.xctest; do
    [[ -e "$bundle" ]] || continue
    real_bundle="$(cd "$bundle" && pwd -P)"
    mac_binary="$real_bundle/Contents/MacOS/$(basename "$real_bundle" .xctest)"
    if [[ -f "$mac_binary" ]]; then
      candidate_binary="$mac_binary"
    elif [[ -f "$real_bundle" ]]; then
      candidate_binary="$real_bundle"   # Linux: the .xctest IS the executable
    else
      continue
    fi
    duplicate=""
    for existing in "${test_binaries[@]:-}"; do
      [[ "$existing" == "$candidate_binary" ]] && duplicate=1
    done
    [[ -z "$duplicate" ]] && test_binaries+=("$candidate_binary")
  done
  if [[ ${#test_binaries[@]} -eq 0 ]]; then
    echo "::warning::no test bundle under $input/.build despite profdata — cannot export coverage." >&2
    continue
  fi

  for binary in "${test_binaries[@]}"; do
    out="$tmp_dir/export-$export_index.lcov"
    export_index=$((export_index + 1))
    if llvm_cov export -format=lcov "$binary" -instr-profile="$profdata" > "$out" 2> "$out.err"; then
      lcov_paths+=("$out")
    else
      echo "::error::llvm-cov export failed for $binary:" >&2
      cat "$out.err" >&2
      exit 1
    fi
  done
done

if [[ ${#lcov_paths[@]} -eq 0 ]]; then
  echo "::error::no package coverage artifacts found in any input." >&2
  exit 1
fi

python3 - "$repo_root" "${lcov_paths[@]}" <<'PY'
import json
import os
import sys

repo_root = sys.argv[1]
lcov_paths = sys.argv[2:]

# Both spellings of the checkout root: builds can record sources through a
# symlinked path (e.g. /tmp vs /private/tmp on macOS).
roots = {repo_root.rstrip("/"), os.path.realpath(repo_root).rstrip("/")}

skip_path_markers = (
    "/Tests/",
    "/.build/",
    "/checkouts/",
    "/Vendor/",
    "/.derived-data/",
)


def relativize(name):
    for root in roots:
        if name.startswith(root + "/"):
            return os.path.relpath(name, root)
    real_name = os.path.realpath(name)
    for root in roots:
        if real_name.startswith(root + "/"):
            return os.path.relpath(real_name, root)
    return None


files = {}
for lcov_path in lcov_paths:
    rel = None
    with open(lcov_path, encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line.startswith("SF:"):
                name = line[3:]
                if any(marker in name for marker in skip_path_markers):
                    rel = None
                    continue
                rel = relativize(name)
                if rel is not None and rel.startswith(".."):
                    rel = None
                continue
            if line == "end_of_record":
                rel = None
                continue
            if rel is None or not line.startswith("DA:"):
                continue
            # DA:<line>,<execution count>[,<checksum>]
            fields = line[3:].split(",")
            try:
                line_num = int(fields[0])
                count = int(fields[1])
            except (IndexError, ValueError):
                continue
            merged = files.setdefault(rel, {"lines": {}})["lines"]
            key = str(line_num)
            merged[key] = bool(merged.get(key)) or count > 0

if not files:
    print("package coverage export produced no per-line data", file=sys.stderr)
    sys.exit(2)

print(json.dumps({"files": files}, indent=2))
PY
