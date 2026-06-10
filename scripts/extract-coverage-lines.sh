#!/usr/bin/env bash
# Extract per-file line coverage from an xcresult bundle.
#
# Usage:
#   scripts/extract-coverage-lines.sh <xcresult-path> > coverage-lines.json
#
# Output JSON shape:
#   { "files": { "relative/path/File.swift": { "lines": { "42": true, "43": false } } } }
#
# Implementation note: `xccov view --report --json` carries only per-file
# AGGREGATES (`lineCoverage` is a hit fraction, not a per-line array), so the
# per-line truth comes from the coverage ARCHIVE (`xccov view --archive`),
# which prints every executable line with its execution count. The report
# JSON still drives target filtering (test bundles are skipped) and provides
# the `_aggregate` fallback for files the archive does not list.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
xcresult_path="${1:-$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-coverage-lines.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ ! -d "$xcresult_path" ]]; then
    echo "xcresult bundle not found: $xcresult_path" >&2
    exit 1
fi

coverage_json="$tmp_dir/coverage.json"
xcrun xccov view --report --json "$xcresult_path" > "$coverage_json"

# The archive dump is the per-line source of truth. Failures here are fatal:
# callers treat a non-zero exit as "no per-line data" and fall back to
# file aggregates, so we never want to emit a half-parsed map.
archive_txt="$tmp_dir/archive.txt"
xcrun xccov view --archive "$xcresult_path" > "$archive_txt"

python3 - "$coverage_json" "$archive_txt" "$repo_root" <<'PY'
import json
import os
import re
import sys

coverage_path = sys.argv[1]
archive_path = sys.argv[2]
repo_root = sys.argv[3]

with open(coverage_path, encoding="utf-8") as handle:
    data = json.load(handle)

skip_target_markers = ("Tests", "TestHost", "UITests")
skip_path_markers = (
    "/AgentLensTests/",
    "/OpenBurnBarMobileTests/",
    "/OpenBurnBarDaemon/Tests/",
    "/Tests/",
    ".build/",
    ".derived-data/",
)


# Both spellings of the checkout root: xcodebuild can record sources through
# a symlinked path (e.g. /tmp vs /private/tmp on macOS), so resolve the real
# root once and accept either prefix.
roots = {repo_root.rstrip("/"), os.path.realpath(repo_root).rstrip("/")}


def relativize(name):
    for root in roots:
        if name.startswith(root + "/"):
            return os.path.relpath(name, root)
    real_name = os.path.realpath(name)
    for root in roots:
        if real_name.startswith(root + "/"):
            return os.path.relpath(real_name, root)
    if "/BurnBar/" in name:
        return name.split("/BurnBar/", 1)[1]
    return name


# Production-target file inventory from the report JSON: drives both the
# test-bundle filtering and the aggregate fallback for files the archive
# does not cover.
aggregates = {}
allowed_paths = set()
for target in data.get("targets", []):
    target_name = target.get("name", "")
    if any(marker in target_name for marker in skip_target_markers):
        continue
    for file_record in target.get("files", []):
        name = file_record.get("path") or file_record.get("name") or ""
        if not name or any(marker in name for marker in skip_path_markers):
            continue
        allowed_paths.add(name)
        executable = int(file_record.get("executableLines") or 0)
        covered = int(file_record.get("coveredLines") or 0)
        if executable > 0:
            aggregates[relativize(name)] = {
                "_aggregate": {"executable": executable, "covered": covered}
            }

# Archive text format:
#   /abs/path/File.swift:
#       1: *
#       2: 0
#       3: 5
#      12: 3 [ ... optional subrange detail ... ]
# `*` marks a non-executable line; a count marks an executable line.
files = {}
header_re = re.compile(r"^(/.+):\s*$")
line_re = re.compile(r"^\s*(\d+):\s*(\*|\d+)")

current_map = None
for raw_line in open(archive_path, encoding="utf-8", errors="replace"):
    header = header_re.match(raw_line)
    if header:
        path = header.group(1)
        if path in allowed_paths and not any(marker in path for marker in skip_path_markers):
            current_map = files.setdefault(relativize(path), {"lines": {}})["lines"]
        else:
            current_map = None
        continue
    if current_map is None:
        continue
    entry = line_re.match(raw_line)
    if not entry:
        continue
    line_num, count = entry.groups()
    if count == "*":
        continue  # non-executable line
    current_map[str(int(line_num))] = int(count) > 0

# Drop archive entries that produced no executable lines, then add the
# aggregate fallback for report files the archive did not enumerate.
files = {rel: payload for rel, payload in files.items() if payload["lines"]}
for rel, aggregate in aggregates.items():
    if rel not in files:
        files[rel] = {"lines": aggregate}

if not files:
    print("coverage archive produced no per-line data", file=sys.stderr)
    sys.exit(2)

print(json.dumps({"files": files}, indent=2))
PY
