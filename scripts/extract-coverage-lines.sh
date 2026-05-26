#!/usr/bin/env bash
# Extract per-file line coverage from an xcresult bundle.
#
# Usage:
#   scripts/extract-coverage-lines.sh <xcresult-path> > coverage-lines.json
#
# Output JSON shape:
#   { "files": { "relative/path/File.swift": { "lines": { "42": true, "43": false } } } }

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

python3 - "$coverage_json" "$repo_root" <<'PY'
import json
import os
import sys

coverage_path = sys.argv[1]
repo_root = sys.argv[2]

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

files = {}

for target in data.get("targets", []):
    target_name = target.get("name", "")
    if any(marker in target_name for marker in skip_target_markers):
        continue

    for file_record in target.get("files", []):
        name = file_record.get("name") or file_record.get("path") or ""
        if not name or any(marker in name for marker in skip_path_markers):
            continue

        rel = name
        if name.startswith(repo_root):
            rel = os.path.relpath(name, repo_root)
        elif "/BurnBar/" in name:
            rel = name.split("/BurnBar/", 1)[1]

        line_map = {}
        for line_entry in file_record.get("lineCoverage", []) or []:
            line_num = line_entry.get("lineNumber")
            if line_num is None:
                continue
            executable = line_entry.get("isExecutable", True)
            if not executable:
                continue
            covered = line_entry.get("executionCount", 0) > 0
            line_map[str(int(line_num))] = covered

        if not line_map:
            executable = int(file_record.get("executableLines") or 0)
            covered = int(file_record.get("coveredLines") or 0)
            if executable <= 0:
                continue
            line_map = {"_aggregate": {"executable": executable, "covered": covered}}

        files[rel] = {"lines": line_map}

print(json.dumps({"files": files}, indent=2))
PY
